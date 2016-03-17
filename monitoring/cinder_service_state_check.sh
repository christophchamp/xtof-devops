#!/bin/bash

################################################################################
# Sensu plugin to monitor Cinder service states                                #
################################################################################

ALERT_NAME="CheckCinderServices"
VERSION="Version 1.2"
AUTHOR="Christoph Champ <christoph.champ@gmail.com>"

PROGNAME=$(`which basename` $0)

source /etc/sensu/plugins/openrc

# Exit codes
STATE_OK=0
STATE_WARNING=1
STATE_CRITICAL=2
STATE_UNKNOWN=3
STATE_DEPENDENT=4

# ANSI escape characters
GREEN='\033[1;32m'
NC='\033[0m' # No Colour

CINDER=/usr/bin/cinder

# Which cinder services to ignore
IGNORE_SERVICES=( 'cinder-backup' )

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
    echo -e "${AUTHOR}\n\nAlert name: ${ALERT_NAME}\n"
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
        echo -e "${GREEN}[DEBUG]${NC} $1"
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

function contains() {
    # Checks if array contains the given element.
    # Returns True if it does; False otherwise.
    local n=$#
    local value=${!n}
    for ((i=1;i< $#;i++)) {
        if [ "${!i}" == "${value}" ]; then
            return 0
        fi
    }
    return 1
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

#== Main block: Check if any cinder services are down =========================
set -o pipefail
raw=($(${CINDER} service-list 2>/dev/null |\
       awk '$12 ~ /[0-9]/{
            gsub(/\.(example.com|example.local)/,"");
            printf "%s;%s;%s\n",$4,$2,$10}'))
if [[ ${PIPESTATUS[0]} -gt 0 ]]; then
    echo "${ALERT_NAME} UKNOWN: Unable to run cinder service-list"
    exit $STATE_UNKNOWN
fi
service_array=($(tr ' ' '\n' <<< "${raw[@]}" | sort | tr '\n' ' '))

if [[ ${#service_array[@]} -eq 0 ]]; then
    echo "${ALERT_NAME} CRITICAL: Unable to communicate with cinder!"
    exit $STATE_CRITICAL
fi

# Create JSON payload with results of alive/dead agents
critical=0
alive="\"alive\":["
dead="\"dead\":["
DC=$(which_dc) # Get the 3-letter data centre value (e.g., "sea")
n=0
for service_data in ${service_array[@]}; do
    node=$(echo ${service_data} | cut -d';' -f1)
    service=$(echo ${service_data} | cut -d';' -f2)
    state=$(echo ${service_data} | cut -d';' -f3)
    id="${DC}-$(($(date +%s) + ((n++))))"
    if ! $(contains "${IGNORE_SERVICES[@]}" "${service}") && \
       [ ${state} != "up" ]; then
        print_val "CRTICIAL;${service_data}"
        critical=1
        dead+="{\"dc\":\"${DC}\",\"id\":\"${id}\",\"node\":\"${node}\",\"service\":\"${service}\"},"
    else
        print_val "OK;${service_data}"
        alive+="{\"dc\":\"${DC}\",\"id\":\"${id}\",\"node\":\"${node}\",\"service\":\"${service}\"},"
    fi
done
payload=$(echo "{\"payload\":[{${alive%,}],${dead%,}]}]}" | python -mjson.tool)

# Exit status with message
if [[ ${critical} -gt 0 ]]; then
    echo "${ALERT_NAME} CRITICAL: The following Cinder services are down: ${payload}"
    exit $STATE_CRITICAL
else
    print_val "PAYLOAD:\n${payload}"
    echo "${ALERT_NAME} OK: All Cinder services are up"
    exit $STATE_OK
fi
