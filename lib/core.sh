########################################
# Default values for the script options
########################################
: ${BANNER:=false}
: ${ROOT_CHECK:=true}
: ${TIMING:=4}
: ${TOP_PORTS:=20}
: ${OPEN:=false}
: ${DO_PING:=true}

########################################
# Determine values in prep for scanning
########################################

# Find max processes the user can instantiate, 
# and set a cap for use in parallel execution;
# `ulimit` should be a bash built-in, so hopefully
# no need to check that it exist or use alternatives 
max_num_processes=$(ulimit -u)
limiting_factor=4 # this is somewhat arbitrary, but seems to work fine
num_processes=$((max_num_processes/limiting_factor))

# Validate the supplied timing option
valid_timing $TIMING

# If there is remaining input not handled by a flag,
# this *should* be either a:
# 		* Hostname
#		* Single IP
# 		* IP Range
# 		* IP + CIDR
# Check validity and populate target list
if [[ -n "$@" ]]; then
	TARGET=$@
	populate_targets $TARGET "add"
fi

# If an input file was specified, pass that list
# into populate_targets function. Here, we want to 
# append to any host(s) provided as inputs on the 
# command line; later, we can add an exclusion flag
# to use either the cli input or the file input to
# remove targets from the list, rather than adding

# Input format: this should gracefully accept:
# * hosts on separate lines
# * comma-delimited or space-delimited list of hosts
# * mixed types of input (single host, lists, ranges, CIDR)
if [[ -n "$i_file" ]]; then
	# Since target file could potentially contain several
	# thousand IPs, just use the file name as the target
	# for reporting 
	TARGET+=" + $i_file"
	OIFS=$IFS
	IFS=$'\n'
	read -d '' -r -a file_targets < $i_file
	IFS=$OIFS
	for file_target in ${file_targets[@]}; do
		if valid_ip "$file_target"; then
			TARGETS+=($file_target)
		else
			populate_targets $file_target "add"
		fi
	done
fi

# After we've added valid targets to our array, 
# check to see if we have any exclusions specified.
# Remove any matching exclusions from the target list.
# We don't *need* to validate the exclusions as IPs, 
# since any that fail to match a host in our target 
# list simply get no further processing. However, 
# passing the exclusions through populate_targets 
# allows us to consistently expand ranges, CIDRs, etc.
# the same way we do for adding targets. 
if [[ -n "$exclude" ]]; then
	populate_targets $exclude "exclude"
fi

# In addition to exclusion via direct input on cli,
# we can accept a list of hosts in file input for 
# exclusion.
if [[ -n "$x_file" ]]; then
	OIFS=$IFS
	IFS=$'\n'
	read -d '' -r -a exclusion_targets < $x_file
	IFS=$OIFS
	for exclusion_target in ${exclusion_targets[@]}; do
		if valid_ip "$exclusion_target"; then
			EXCLUSIONS+=($exclusion_target)
		else
			populate_targets $exclusion_targets "exclude"
		fi
	done
fi

# After exclusions from cli and file inputs are 
# processed, modify the TARGETS array, removing
# any matches
for exclusion in ${EXCLUSIONS[@]}; do
	TARGETS=( ${TARGETS[@]/$exclusion} )
done

# determine default network interface
if test $(which route); then
	#Output of `route` should consistently show interface name as last field
	default_interface=$(route | grep '^default' | grep -o '[^ ]*$')
elif test $(which ip); then
	#FIXME: confirm that `ip route` field output is consistent across systems or use a different method
	default_interface=$(ip route show default | cut -d" " -f5) 
else 
	# fallback to reading interface name from /proc
	default_interface=$(cat /proc/net/dev | grep -v lo | cut -d$'\n' -f3 | cut -d":" -f1)
fi

# determine local IP and CIDR for default interface
if test $(which ip); then
	localaddr=$(ip -o -4 addr show $default_interface | tr -s " " | cut -d" " -f4)
	IFS=/ read localip netCIDR <<< $localaddr
	network=$(cidr2network $localip $netCIDR)
elif test $(which ifconfig); then
    localaddr=$(ifconfig $default_interface | grep -Eo '(addr:)?([0-9]*\.){3}[0-9]*')
    localip=$(cut -d$'\n' -f1 <<< $localaddr)
    netmask=$(cut -d$'\n' -f2 <<< $localaddr)
    # ifconfig doesn't output CIDR, but we can calculate it from the netmask bits
    c=0 x=0$( printf '%o' "${netmask//./ }" )
    while [ $x -gt 0 ]; do
      	let c+=$((x%2)) 'x>>=1'
    done
    netCIDR=$c
    network=$(cidr2network $localip $netCIDR)
else
    localip=$(hostname -I | cut -d" " -f1)
    # FIXME: in an edge case where neither ifconfig nor iproute2 utils are available
    #        need to get CIDR/netmask some other way
fi

iprange=$(printf %s/%s $network $netCIDR)

# Determine external IP
# Try /dev/tcp method first
httpextip="icanhazip.com"
conn="'GET / HTTP/1.1\r\nhost: ' $httpextip '\r\n\r\n'"
response=$(timeout 0.5s bash -c "exec 3<>/dev/tcp/$httpextip/80; echo -e $conn>&3; cat<&3" | tail -1)

# If the above method fails, then fallback to builtin utils for this
if valid_ip response; then
	getip=$reponse
else
	if test $(which curl); then
		getip=$(curl -s $httpextip) # whatismyip.akamai.com may be a consistently faster option
	elif test $(which wget); then
		getip=$(wget -O- -q $httpextip)
	elif test $(which dig); then
		getip=$(dig +short myip.opendns.com @resolver1.opendns.com)
	elif test $(which telnet); then
		getip=$(telnet telnetmyip.com 2>/dev/null | grep ^\"ip | cut -d"\"" -f4)
	elif test $(which ssh); then
		# Not usually a great idea to disable StrictHostKeyChecking, but
		# in this case, we aren't doing anything sensitive in the connection.
		# Leaving it enabled will prompt for confirming key on first connection,
		# rather than simply returning the output we want
		getip=$(ssh -o StrictHostKeyChecking=no sshmyip.com 2>/dev/null |  grep ^\"ip | cut -d"\"" -f4)
	else
		#We probably have enough methods above to make failure relatively unlikely.
		#So, if we reach this point, there may be no WAN connectivity.
		getip="Failed to determine. Host may not have external connectivity."
	fi
fi

# Port list
# Default: Subset of tcp_ports (list from nmap), as specified in $TOP_PORTS
# Custom:  User input from "-p | --ports" flags, either as a comma-separated list or a range
if [ -z "$ports" ]; then
	# TCP ports from the nmap database ordered by frequency of use, stored in nmap-services:
	# `cat /usr/share/nmap/nmap-services | grep "tcp" | sort -r -k3 | column -t | tr -s " "`
	tcp_ports=($(cat lib/nmap-services | cut -d" " -f2 | cut -d"/" -f1 | tr $'\n' " "))
	ports=(${tcp_ports[@]:0:$TOP_PORTS})
elif [[ -n "$(grep -i , <<< $ports)" ]]; then # is this a comma-separated list of ports? 
	IFS=',' read -r -a ports <<< $ports # split comma-separated list into array for processing
	for port in ${ports[@]}; do
		valid_port $port
	done
elif [[ -n "$(grep -i - <<< $ports)" ]]; then # is this a range of ports?
	# Treat "-p-" case as a request for all ports
	if [[ "$ports" == "-" ]]; then
		ports=( $(seq 0 65535) )
	else
		IFS='-' read start_port end_port <<< $ports
		# If all ports in specified range are valid, 
		# populate ports array with the full list
		valid_port $start_port && valid_port $end_port
		ports=( $(seq $start_port $end_port ))
	fi
else
	valid_port $ports
fi

num_ports=${#ports[@]}

# Determine which pingsweep method(s) will be used
if test $(which arping); then
	if [ "$ROOT_CHECK" = true ] && [ "$EUID" != 0 ]; then
		arp_warning=true
		SWEEP_METHOD="ICMP"
	else
		SWEEP_METHOD="ICMP/ARP"
	fi
else
	SWEEP_METHOD="ICMP"
fi

# Timing options (initially based on nmap Maximum TCP scan delay settings)
# nmap values are in milliseconds - converted here for bash sleep in seconds
case $TIMING in
	0 )	DELAY=300    ;;
	1 )	DELAY=15     ;;
	2 )	DELAY=1      ;;
	3 )	DELAY=.1     ;;
	4 )	DELAY=.010   ;;
	5 )	DELAY=.005   ;;
	6 )	DELAY=0      ;;
esac

main
