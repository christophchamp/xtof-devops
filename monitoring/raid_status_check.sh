#!/bin/bash

################################################################################
# Nagios plugin to monitor iDRAC RAID states                                   #
################################################################################

ALERT_NAME="iDRAC RAID"
VERSION="Version 1.0"
AUTHOR="Christoph Champ <christoph.champ@gmail.com>"

PROGNAME=$(`which basename` $0)

# Exit codes
STATE_OK=0
STATE_WARNING=1
STATE_CRITICAL=2
STATE_UNKNOWN=3
STATE_DEPENDENT=4

SSHPASS=$(which sshpass)
FUEL=$(which fuel)
#FUEL_HOST=$(getent hosts $(ifconfig eth2 | awk '/inet addr/{print substr($2,6)}'))
FUEL_HOST=$(cut -d'-' -f2 /etc/motd)

#DISK_TYPES=(pdisks vdisks)
DISK_TYPES=(vdisks)

# Make sure `sshpass` is installed
rc=0
${SSHPASS} -V > /dev/null 2>&1 || rc="$?"
if [[ "$rc" -ne 0 ]]; then
    echo "UNKNOWN: sshpass is either not installed or not in the PATH"
    exit $STATE_UNKNOWN
fi

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

function get_user_passwd() {
    if [[ ${FUEL_HOST} == "lab" ]]; then
        local user=<REDACTED>
        local passwd=<REDACTED>
        printf "%s;%s" ${user} ${passwd}
    elif [[ ${FUEL_HOST} == "ash" ]]; then
        local user=<REDACTED>
        local passwd=<REDACTED>
        printf "%s;%s" ${user} ${passwd}
    elif [[ ${FUEL_HOST} == "sea" ]]; then
        local user=<REDACTED>
        local passwd=<REDACTED>
        printf "%s;%s" ${user} ${passwd}
    fi
}

declare -a critical_services=()
critical=0
function get_state() {
    local host="$1"
    local disk_type="$2"
    local check_domain=$(getent hosts ${host} || echo "")
    local domain=$(echo ${check_domain}|awk '{print (length($2)>0) ? $2 : "unknown-domain"}')
    local user_passwd=$(get_user_passwd)
    local rc=0
    local OUTPUT=$(${SSHPASS} -p${user_passwd[@]#*;} \
                   ssh -o StrictHostKeyChecking=no \
                   -o PreferredAuthentications=password \
                   -o PubkeyAuthentication=no ${user_passwd[@]%%;*}@${host} \
                   racadm raid get ${disk_type} -o -p State 2>/dev/null) || rc="$?"
    if [[ "$rc" -ne 0 ]]; then
        echo "UNKNOWN: sshpass can not log into iDrac on ${host}"
        exit $STATE_UNKNOWN
    fi
    # NOTE: The following is a hack, since we are using an old version of Bash.
    IFS=';' read -ra DISKS <<< "$(echo ${OUTPUT}|sed ':a;N;$!ba;s/\n/ /g'|\
                                  sed -e 's/[ ]\{2,\}/ /g' -e 's/ Disk/;Disk/g')"
    for disk in "${DISKS[@]}"; do
        local state=$(echo ${disk} | awk '{print $4}')
        local bay=$(echo ${disk} | awk '{print $1}')
        if [[ ${state} != "Online" ]]; then
            critical_msg="CRITICAL;${host};${domain};${disk_type};${bay};${state}"
            print_val ${critical_msg}
            critical_services[critical]=${critical_msg}
            ((critical++))
        else
            print_val "OK;${host};${domain};${disk_type};${bay};${state}"
        fi
    done
}

function get_compute_idrac_ips() {
    if [[ ${FUEL_HOST} == "lab" ]]; then
        local compute_idrac_ips=(10.1.1.10 10.1.1.11 10.1.1.12)
    elif [[ ${FUEL_HOST} == "ash" ]]; then
        local compute_nodes_domains=($(${FUEL} node list|awk '/compute/{printf "r-%s ",$5}'))
        local compute_idrac_ips=($(for i in ${compute_nodes_domains[@]}; do host $i|awk '{print $4}'; done))
    elif [[ ${FUEL_HOST} == "sea" ]]; then
        local compute_nodes_domains=($(${FUEL} node list|awk '/compute/{printf "r-%s ",$5}'))
        local compute_idrac_ips=($(for i in ${compute_nodes_domains[@]}; do host $i|awk '{print $4}'; done))
    fi
    echo ${compute_idrac_ips[@]}
}

function query_idracs() {
    local compute_idrac_ips=$(get_compute_idrac_ips)
    for host in ${compute_idrac_ips[@]}; do
        for disk_type in "${DISK_TYPES[@]}"; do
            get_state ${host} ${disk_type}
        done
    done
}

query_idracs

print_val "-----"
# If any iDRAC RAID returned anything other than "Online", we have a
#+ "CRITICAL" alert.
if [[ ${#critical_services[@]} -gt 0 ]]; then
    for critical_data in ${critical_services[@]}; do
        echo "${critical_data}"
    done
    exit $STATE_CRITICAL
fi

echo "${ALERT_NAME} status OK"
exit $STATE_OK
