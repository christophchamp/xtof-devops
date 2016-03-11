#!/bin/bash

################################################################################
# Sensu plugin to monitor Nova service states                                  #
################################################################################

ALERT_NAME="CheckNovaServicesState"
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

NOVA=/usr/bin/nova

# Which nova services/hosts to ignore
IGNORE_SERVICES=( 'nova-network' 'nova-console' )
IGNORE_HOSTS=( 'nova-compute;node-14.example.local' ) # service;host

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

#== Main block: Check if any nova services are down ===========================
raw=($(${NOVA} service-list 2>/dev/null |\
       awk '$2 ~ /[0-9]/{gsub(/\.(example.com|example.local)/, "");
            printf "%s;%s;%s\n",$4,$6,$12}'))
service_array=($(tr ' ' '\n' <<< "${raw[@]}" | sort | tr '\n' ' '))

if [[ ${#service_array[@]} -eq 0 ]]; then
    echo "${ALERT_NAME} CRITICAL: Unable to communicate with nova!"
    exit $STATE_CRITICAL
fi

declare -A alert_array
for service_data in ${service_array[@]}; do
    service=$(echo ${service_data} | cut -d';' -f1)
    node=$(echo ${service_data} | cut -d';' -f2)
    state=$(echo ${service_data} | cut -d';' -f3)
    if ! $(contains "${IGNORE_SERVICES[@]}" "${service}") && \
       [[ ${IGNORE_HOSTS[@]%%;*} != ${service} && \
          ${IGNORE_HOSTS[@]#*;} != ${host} ]] && \
       [ ${state} != "up" ]; then
        print_val "CRTICIAL;${service_data}"
        alert_array["critical"]+="${service}::${node}; "
    else
        print_val "OK;${service_data}"
        alert_array["ok"]+="${service}::${node}; "
    fi
done

print_val "-----"

# Exit status with message
if [[ ${#alert_array["critical"]} -gt 0 ]]; then
    echo "${ALERT_NAME} CRITICAL: The following Nova services are down: {${alert_array["critical"]}}"
    exit $STATE_CRITICAL
else
    #echo "${ALERT_NAME} OK: All Nova services are up: {${alert_array["ok"]}}"
    echo "${ALERT_NAME} OK: All Nova services are up"
    exit $STATE_OK
fi
