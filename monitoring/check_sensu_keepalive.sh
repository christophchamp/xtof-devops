#!/bin/bash

################################################################################
# Sensu plugin to check if Sensu keepalive is responding                       #
################################################################################

# DESCRIPTION: This script checks if Sensu keepalive checks return any CRITICAL
#+ alerts (i.e., exit code "2"). This normally happens when the sensu-client
#+ service on a given host is no longer running.

ALERT_NAME="CheckSensuKeepalive"
PROGNAME=$(`which basename` $0)
VERSION="Version 1.0"
AUTHOR="Christoph Champ <christoph.champ@gmail.com>"

# Verbosity level
verbosity=0

# Exit codes
STATE_OK=0
STATE_WARNING=1
STATE_CRITICAL=2
STATE_UNKNOWN=3
STATE_DEPENDENT=4

# Global variables
DC=$(hostname|cut -d'-' -f3)
SSH_PARAMS="-q -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null \
    -i /etc/sensu/plugins/sensu-key"
ENDPOINT=sensu:sensu@${DC}-sensu.example.com:4567 # Sensu API endpoint

# Jenkins-related global variables
JENKINS_DASHBOARD="http://jenkins.example.com:8080/view/Openstack-dashboard/"
JENKINS_ENDPOINT="http://jenkins.example.com:8080/buildByToken/buildWithParameters"
JENKINS_JOB="${DC}-sensu-receiver"
JENKINS_TOKEN="<REDACTED>"
#JENKINS_ISSUE_TYPE="check-sensu-keepalive"
JENKINS_ISSUE_TYPE=$(echo ${ALERT_NAME} | sed -e 's/\([A-Z]\)/-\L\1/g' -e 's/^-//')
JENKINS_ALERT_FILE=/etc/sensu/plugins/.jenkins_alerts

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

usage ()
{
    echo "Usage: ${PROGNAME} [OPTIONS]"
    echo " -h         Get help"
    echo " -H <host>  fqdn of fuel host"
    echo " -j <0|1>   Run Jenkins? 0=no; 1=yes"
    echo " -V         Print version information"
    echo " -v         Verbose output"
    echo -e "\nExample:"
    echo "./${PROGNAME} -H fuel-sea.example.com"
}

# Parse command line options
Hflag=false
while getopts 'h:H:Vv' OPTION
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
        H)
            export FUEL_HOST=$OPTARG
            Hflag=true
            ;;
        *)
            echo "$PROGNAME: Invalid option '$1'"
            usage
            exit 1
            ;;
    esac
done

shift $(($OPTIND - 1))

if ! $Hflag; then
    echo "Missing \"-H\" option. Required for fuel hostname." >&2
    exit $STATE_UNKNOWN
fi

# Start of actual check =======================================================

# We are performing this for-loop in order to convert hostnames from:
# "us-sea1-c12-n-node1" to "node-25". We are doing this so our Jenkins
# job can ssh into each node and attempt to self-heal (restart the
# sensu-client, in this case).
declare -A host_array
raw=$(ssh ${SSH_PARAMS} root@${FUEL_HOST} fuel node)
OLDIFS=$IFS; IFS=$'\n' read -d '' -r -a lines <<< "${raw}"; IFS=$OLDIFS
print_val "DEBUG: fuel nodes:"
for line in "${lines[@]}"; do
    if [[ ${line} =~ ^[0-9]* ]]; then
        host=$(awk -F'|' '{gsub(" |\t","");print $3}' <<< "${line}")
        node_num=$(awk -F'|' '{gsub(" |\t","");print $1}' <<< "${line}")
        online=$(awk -F'|' '{gsub(" |\t","");print $9}' <<< "${line}")
        print_val "DEBUG: ${node_num} ${host} ${online}"
        host=${host//-/_}
        node="node-${node_num}"
        host_array[${host}]+="${node}:${online}"
    fi
done

in_array() {
    for key in ${!host_array[@]}; do
        [[ "${key}" == "$1" ]] && return 0
    done
    return 1
}

# This for-loop sends a Sensu API call to get a list of keepalive checks and
# their status/exit codes (e.g., 2 => CRITICAL). The for-loop also matches
# long-form hostnames to node names (e.g., "use-ash1-c12-n-node1" => "node-25")
node_str=""
print_val "DEBUG: -----------"
print_val "DEBUG: Sensu API GET keepalive response:"
for client in $(curl -sH "Content-type:application/json" "${ENDPOINT}/clients" |\
                jq -crM '[.[]|.name]' | tr -d '[]"' | tr ',' '\n'); do
    result=$(curl -sH "Content-type:application/json" \
             "${ENDPOINT}/results/${client}/keepalive" |\
             jq -crM '[.client,.check.status]' | tr -d '[]"')
    print_val "DEBUG: ${result}"
    host=${result%%,*}
    host=${host//-/_}
    status_code=${result#*,}
    online="${host_array[$host]#*:}"
    node="${host_array[$host]%%:*}"
    if in_array ${host} && [[ ${status_code} -gt 0 ]] && \
        [[ "${online}" == "True" ]]; then
        #node_str+="${host_array[$host]%%:*} "
        node_str+="${node} "
    elif ! in_array ${host} && [[ ${status_code} -gt 0 ]]; then
        node_str+="${host//_/-} "
    fi
done

# Alert message
if [ -n "${node_str}" ]; then
    node_str=$(tr ' ' '\n' <<< "${node_str}" | sort | tr '\n' ' ')
    node_str=${node_str# }
    json_str="{\"payload\":[{\"dc\":\"${DC}\",\"id\":\"${DC}-$(date +%s)\","
    json_str+="\"node\":\"${node_str% }\"}]}"

    data=$(python -c 'import sys; import simplejson as json; \
                      data=json.dumps(json.loads(sys.stdin.read()),
                      sort_keys=True,indent=4);\
                      print data' <<< "${json_str}")

    # Submit JSON payload to Jenkins in order to attempt self-heal
    # (i.e., attempt to resolve the issue)
    payload=$(echo ${data} | base64 -w0)
    curl_opts="${JENKINS_ENDPOINT}"
    curl_opts+="?job=${JENKINS_JOB}"
    curl_opts+="&token=${JENKINS_TOKEN}"
    curl_opts+="&issue_type=${JENKINS_ISSUE_TYPE}"
    curl_opts+="&payload=${payload}"
    print_val "curl -s \"${curl_opts}\""
    curl -s ${curl_opts}

    msg="${ALERT_NAME} CRITICAL: The sensu-client service is not running on "
    msg+="the following nodes: ${data}"
    echo "${msg}"

    exit $STATE_CRITICAL
fi

echo "${ALERT_NAME} OK: All sensu-client services are running"
