########################################
# Default values for the script options
########################################
: ${BANNER:=false}
: ${ROOT_CHECK:=true}
: ${TIMING:=4}
: ${TOP_PORTS:=20}
: ${OPEN:=false}

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

# If a single IP or range of IPs are supplied,
# check that addresses are valid and assign to 
# TARGET/TARGETS for later use
if [[ -n "$@" ]]; then
	TARGET=$@
	# If the input doesn't validate as an IP, 
	# check to see if a range was specified
	if	! valid_ip "$TARGET"; then
		# If there is a "-" in input, treat as IP range
		# FIXME: currently only handles 4th octet;
		#        add support for ranges in all 4 octets
		if [[ -n "$(grep -i - <<< $TARGET)" ]]; then
			IFS='-' read start_ip end_oct4 <<< $TARGET
			network=$(echo $start_ip | cut -d"." -f1,2,3)
			end_ip=$network.$end_oct4
			start_oct4=$(echo $start_ip | cut -d"." -f4)
			# If the beginning and ending IPs specified are 
			# valid, assign all addresses in range to TARGETS array
			if valid_ip "$start_ip" && valid_ip "$end_ip"; then	
				if [[ "$start_oct4" -lt "$end_oct4" ]]; then
					for oct4 in $(seq $start_oct4 $end_oct4); do
						TARGETS+=("$network.$oct4")
					done
				else
					usage
				fi
			else
				usage
			fi
		# If there is a "/" in the input, treat as CIDR
		elif [[ -n "$(grep -i / <<< $TARGET)" ]]; then
			# Sanity check base IP specified is valid
			if ! valid_ip "${TARGET%/*}"; then
				usage
			else
				TARGETS=("$(cidr_to_ip $TARGET)")
			fi
		else
			# Is this a valid hostname?
			check_hostname=$(resolve_host $TARGET)
			if valid_ip $check_hostname; then
				TARGET="$check_hostname"
			# If all checks above fail, treat as invalid input
			else
				usage
			fi
		fi
	fi
fi

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
else
    localip=$(hostname -I | cut -d" " -f1)
    # FIXME: in an edge case where neither ifconfig nor iproute2 utils are available
    #        need to get CIDR some other way
fi

## FIXME: these values for network and iprange are only valid for /24 CIDRs.
#         need to update the method if/when custom CIDRs are allowed
network=$(echo $localip | cut -d"." -f1,2,3)
iprange=$(echo $network".0/"$netCIDR)

# Determine external IP
# Try /dev/tcp method first
httpextip="icanhazip.com"
conn="'GET / HTTP/1.1\r\nhost: ' $httpextip '\r\n\r\n'"
response=$(timeout 0.5s bash -c "exec 3<>/dev/tcp/$httpextip/80; echo -e $conn>&3; cat<&3" | tail -1)

# If the above method fails, then fallback to builtin utils for this
if ! valid_ip response; then
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
