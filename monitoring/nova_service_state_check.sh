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
IGNORE_HOSTS=( 'node-24.example.local' ) # service;host

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
       awk -F'|' '$2 ~ /[0-9]/{gsub(/ |\t/,"");
       printf "%s;%s;%s;%s\n",$4,$3,$6,$7}'))
service_array=($(tr ' ' '\n' <<< "${raw[@]}" | sort | tr '\n' ' '))

if [[ ${#service_array[@]} -eq 0 ]]; then
    echo "${ALERT_NAME} CRITICAL: Unable to communicate with nova!"
    exit $STATE_CRITICAL
fi

declare -A result
for service_data in ${service_array[@]}; do
    host=$(echo ${service_data} | cut -d';' -f1)
    node=$(echo ${service_data} | awk -F';' '{
        gsub(/\.(example.com|example.local)/,"");print $1}')
    node_name=${node/-/_} # since bash array keys can not contain hyphens
    service=$(echo ${service_data} | cut -d';' -f2)
    enabled=$(echo ${service_data} | cut -d';' -f3)
    state=$(echo ${service_data} | cut -d';' -f4)
    if ! $(contains "${IGNORE_SERVICES[@]}" "${service}") && \
       ! $(contains "${IGNORE_HOSTS}" != "${host}") && \
       [[ "${enabled}" == "enabled" && "${state}" != "up" ]]; then
        print_val "CRTICIAL;${service_data}"
        result[$node_name]+="${service} "
    else
        print_val "OK;${service_data}"
    fi
done

# We now construct a JSON string from the results of our check
alert_output=""
DC=$(which_dc) # Get the 3-letter data centre value (e.g., "sea")
if [[ ${#result[@]} -gt 0 ]]; then
    print_val "DEBUG: Services found = ${#result[@]}"
    alert_output="{\"payload\":["
    for node in ${!result[@]}; do
        node_name=${node/_/-} # restore hyphens to node name (e.g., "node-1")
        json="{\"id\":\"${DC}-$(date +%s)\",\"dc\":\"${DC}\","
        json+="\"node\":\"${node_name}\",\"service\":\"${result[$node]%% }\","
        json+="\"state\":\"down\"},"
        alert_output+=${json}
    done
    alert_output="${alert_output%,}]}"
fi
read -r json_str <<< "${alert_output}"

# Exit status with message
if [[ ${#result[@]} -gt 0 ]]; then
    payload=$(python -c 'import sys; import simplejson as json; \
        data=json.dumps(json.loads(sys.stdin.read()),sort_keys=True,indent=4);\
        print data' <<< "${json_str}")
    msg="${ALERT_NAME} CRITICAL: The following ${#result[@]} services are "
    msg+="down: ${payload}"
    echo "${msg}"
    exit $STATE_CRITICAL
else
    echo "${ALERT_NAME} OK: All Nova services are up"
    exit $STATE_OK
fi
