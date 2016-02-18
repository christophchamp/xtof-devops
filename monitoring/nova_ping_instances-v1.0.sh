#!/bin/bash

################################################################################
# Nagios plugin to monitor Midonet cluster operation                           #
################################################################################

ALERT_NAME="Midonet"
VERSION="Version 1.0"
AUTHOR="Christoph Champ <christoph.champ@gmail.com>"

PROGNAME=$(`which basename` $0)

source /etc/sensu/plugins/openrc

# Exit codes
STATE_OK=0
STATE_WARNING=1
STATE_CRITICAL=2
STATE_UNKNOWN=3
STATE_DEPENDENT=4

PING=$(which ping)
GREP=$(which grep)
NOVA=$(which nova)

# Helper functions #############################################################

function print_revision {
   # Print the revision number
   echo "$PROGNAME - $VERSION"
}

function print_usage {
   # Print a short usage statement
   echo "Usage: $PROGNAME [-v] [-V]"
}

function print_help {
   # Print detailed help information
   print_revision
   echo -e "$AUTHOR\n\nCheck ${ALERT_NAME} cluster operation\n"
   print_usage

   /bin/cat <<__EOT

Options:
-h
   Print detailed help screen
-V
   Print version information
-v
   Verbose output
__EOT
}

function print_val {
  if [[ $verbosity -ge 1 ]]; then
    echo $1
  fi
}

function parse_nova_show {
    # TODO: Return array instead of string
    while read -r line
    do
        IFS="|" read -r x key value x <<< "$line"
        local key="$(echo -e "${key}" | tr -d '[[:space:]]')"
        local value="$(echo -e "${value}" | tr -d '[[:space:]]')"
        if [[ $key =~ ^name$ ]]; then
            local instance_name=$value
        elif [[ $key =~ ^app_dev_internalnetwork$ ]]; then
            IFS="," read var1 var2 <<< "$value"
            local floating_ip=$var2
        elif [[ $key =~ ^OS-EXT-STS:vm_state$ ]]; then
            local vm_state=$value
        elif [[ $key =~ ^status$ ]]; then
            local instance_status=$value
        elif [[ $key =~ ^security_groups$ ]]; then
            local security_groups=$value
        fi
    done <<< "$1"
    #results=( $instance_name $vm_state $instance_status $floating_ip )
    __results="$instance_name;$vm_state;$instance_status;$floating_ip;$security_groups"
    echo $__results
    IFS=""
}

function ping_floating_ip {
    local floating_ip="$1"
    local vm_state="$2"
    local instance_status="$3"
    local security_groups=$(echo $4|grep -c "default")
    if [[ ${floating_ip} =~ ^10\.[0-9]{,3}\.[0-9]{,3}\.[0-9]{,3} ]] && 
       [[ ${vm_state} == "active" ]] && 
       [[ ${instance_status} == "ACTIVE" ]] && 
       [[ ${security_groups} == "1" ]]; then
        echo $(${PING} -c 3 -W 2 -q ${floating_ip} | ${GREP} -oP '\d+(?=% packet loss)')
    fi
}

# Main #########################################################################

# Verbosity level
verbosity=0

# Parse command line options
while [ "$1" ]; do
   case "$1" in
       -h | --help)
           print_help
           exit $STATE_OK
           ;;
       -V | --version)
           print_revision
           exit $STATE_OK
           ;;
       -v | --verbose)
           : $(( verbosity++ ))
           shift
           ;;
       -?)
           print_usage
           exit $STATE_OK
           ;;
       *)
           echo "$PROGNAME: Invalid option '$1'"
           print_usage
           exit $STATE_UNKNOWN
           ;;
   esac
done

# Simple test to see if we can communicate with Nova
raw=$(${NOVA} flavor-list 2>&1 > /dev/null)
if [[ $? -ne 0 || -n ${raw} ]]; then
    echo "CRITICAL: ${raw}"
    exit $STATE_CRITICAL
fi

#------------------------------------------------------------------------------
#fields="name,OS-EXT-SRV-ATTR:hypervisor_hostname,networks,security_groups"
#raw=$(${NOVA} list --all-tenants --fields ${fields} | awk -W posix -F'|' '
#      $2 ~ /[[:alnum:]-]{36}/{
#        nets=match($5, /, 10\.*/);tendot=substr($5,nets+2);
#        gsub(", ",";",$6);secgrp=match($6,/default/);
#        if(tendot ~ /10\./ && secgrp>0){
#          gsub(" ","",$2);gsub(" ","",$3);gsub(" ","",$4);gsub(" ","",tendot);
#          gsub(" ","",$6);printf "%s,%s,%s,%s,%s\n", $2,$3,$4,tendot,$6}}')

declare -a critical_instances=()
critical=0
for hypervisor in $(${NOVA} hypervisor-list | awk '$2 ~ /[0-9]/{print $4}'); do
    for instance in $(${NOVA} hypervisor-servers ${hypervisor} | awk '$2 ~ /[a-z0-9]/{print $2}'); do
        # Get only the values we need from `nova show`
        results=$(parse_nova_show "$(nova show ${instance})")

        # FIXME: This mess will go away when we switch to arrays
        instance_name=$(echo $results | awk -F';' '{print $1}')
        vm_state=$(echo $results | awk -F';' '{print $2}')
        instance_status=$(echo $results | awk -F';' '{print $3}')
        floating_ip=$(echo $results | awk -F';' '{print $4}')
        security_groups=$(echo $results | awk -F';' '{print $5}')

        packet_loss=$(ping_floating_ip ${floating_ip} ${vm_state} ${instance_status})

        if [[ $packet_loss -ne 0 ]]; then
            print_val "CRITICAL;${hypervisor};${instance};${instance_name};${vm_state};${instance_status};${floating_ip};${packet_loss}"
            critical_instances[critical]="CRITICAL;${hypervisor};${instance};${instance_name};${vm_state};${instance_status};${floating_ip};${packet_loss}"
            critical=$((critical+1))
        else
            print_val "OK;${hypervisor};${instance};${instance_name};${vm_state};${instance_status};${floating_ip};${packet_loss}"
        fi
    done
done

if [[ ${#critical_instances[@]} -gt 0 ]]; then
    for critical_data in ${critical_instances[@]}; do
        echo "${critical_data}"
    done
    exit $STATE_CRITICAL
fi

echo "${ALERT_NAME} cluster OK"
exit $STATE_OK
