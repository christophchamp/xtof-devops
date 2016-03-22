#!/bin/bash

################################################################################
# Sensu plugin to monitor iDRAC RAID states                                    #
################################################################################

ALERT_NAME="RaidStatusCheck"
VERSION="Version 1.2"
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

function print_val {
  if [[ $verbosity -ge 1 ]]; then
    echo $1
  fi
}

function which_dc () {
    # This ugly workaround is just to figure out which DC we are in, since the
    # DNS records are either missing or inconsistent
    DC=$(getent hosts $(awk '/nameserver/{print $2;exit}' /etc/resolv.conf) | \
        awk '{print substr($2,1,3)}')
    if [[ "${DC}" == "fue" ]]; then
        DC="lab"
    fi
    echo ${DC}
}

# Verbosity level
verbosity=0

usage ()
{
    echo -e "\n${ALERT_NAME} - ${VERSION}\n${AUTHOR}\n\n"
    echo "Usage: ${PROGNAME} [OPTIONS]"
    echo " -h             Get help"
    echo " -u <username>  iDrac admin username"
    echo " -p <password>  iDrac admin password"
    echo " -V             Print version information"
    echo " -v             Verbose output"
    echo -e "\nExample:"
    echo "./${PROGNAME} -u root -p password"
}

# Parse command line options
while getopts 'hu:p:Vv' OPTION
do
    case $OPTION in
        h)
            usage
            exit $STATE_OK
            ;;
        V)
            print_revision
            exit $STATE_OK
            ;;
        v)
            : $(( verbosity++ ))
            shift
            ;;
        u)
            export USERNAME=$OPTARG
            ;;
        p)
            export PASSWORD=$OPTARG
            ;;
        *)
            echo "$PROGNAME: Invalid option '$1'"
            usage
            exit $STATE_UNKNOWN
            ;;
    esac
done

# Main #########################################################################
DC=$(which_dc)

declare -a critical_services=()
critical=0
function get_state() {
    local host="$1"
    local disk_type="$2"
    local check_domain=$(getent hosts ${host} || echo "")
    local domain=$(echo ${check_domain} | \
        awk '{print (length($2)>0) ? $2 : "unknown-domain"}')
    local rc=0
    local OUTPUT=$(${SSHPASS} -p ${PASSWORD} \
                   ssh -o StrictHostKeyChecking=no \
                   -o PreferredAuthentications=password \
                   -o PubkeyAuthentication=no ${USERNAME}@${host} \
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
        local compute_idrac_ips=(10.192.168.101 10.192.168.102 10.192.168.103)
    elif [[ ${DC} == "ash" || ${DC} == "sea" ]]; then
        local compute_nodes_domains=($(${FUEL} node list | \
            awk '/compute/{printf "r-%s ",$5}'))
        local compute_idrac_ips=($(for i in ${compute_nodes_domains[@]}; \
            do host $i | awk '{print $4}'; done))
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

echo "${ALERT_NAME} OK"
exit $STATE_OK
