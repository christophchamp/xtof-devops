#!/bin/bash

################################################################################
# Sensu plugin to check if all instances are pingable                          #
################################################################################

ALERT_NAME="CheckNovaPing"
PROGNAME=$(`which basename` $0)
VERSION="Version 1.6"
AUTHOR="Christoph Champ <christoph.champ@gmail.com>"

source /etc/sensu/plugins/openrc

# Verbosity level
verbosity=0

# Exit codes
STATE_OK=0
STATE_WARNING=1
STATE_CRITICAL=2
STATE_UNKNOWN=3
STATE_DEPENDENT=4

# percent packet loss allowed before we trigger alerts
WARNING_PACKET_LOSS=0
CRITICAL_PACKET_LOSS=0.99

SSH=$(which ssh)
PING=$(which ping)
FPING=$(which fping)
GREP=$(which grep)
NOVA=$(which nova)

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
    echo " -H <host>  fgdn of fuel host"
    echo " -n <node>  Username to use to get an auth token"
    echo " -V         Print version information"
    echo " -v         Verbose output"
    echo -e "\nExample:"
    echo "./${PROGNAME} -H fuel-ashburn.example.com -n node-7"
}

# Parse command line options
while getopts 'h:H:n:Vv' OPTION
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
            ;;
        n)
            export CONTROLLER_NODE=$OPTARG
            ;;
        *)
            echo "$PROGNAME: Invalid option '$1'"
            usage
            exit 1
            ;;
    esac
done

SSH_PARAMS="-q -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null \
      -i /etc/sensu/plugins/sensu-key root@${FUEL_HOST} ssh ${CONTROLLER_NODE}"

# Main #########################################################################

function parse_fping_output() {
    local input_str="$1"
    local parsed=$(python -c 'import sys,re;line=sys.stdin.read();\
                   found=[m.start() for m in re.finditer("-",line)];\
                   print "%s;%d" % (line.split(" ")[0].strip(),\
                   float(len(found)/10.)*100)' <<< "${input_str}")
    echo "${parsed}"
}

function get_instance_array() {
    fields="name,OS-EXT-SRV-ATTR:hypervisor_hostname,OS-EXT-STS:vm_state,"
    fields+="status,networks,security_groups"
    raw=$(${SSH} ${SSH_PARAMS} "nova list --all-tenants --fields ${fields}" 2>/dev/null)
    instance_array=($(awk -W posix -F'|' '$2 ~ /[[:alnum:]-]{36}/{
          nets=match($7, /, 10\.*/);tendot=substr($7,nets+2);
          secgrp=match($8,/default/);gsub(" |\t","");
          gsub(/(.example.com|.example.local)/,"",$4);
          if(tendot ~ /10\./ && secgrp>0 && \
          tolower($5)=="active" && tolower($6)=="active"){
          printf "%s;%s;%s;%s\n", $2,$3,$4,tendot}}' <<< "${raw}"))

    echo ${instance_array[@]}
}

#== Start of actual check =====================================================
instance_array=($(get_instance_array))

if [[ ${#instance_array[@]} -eq 0 ]]; then
    echo "${ALERT_NAME} CRITICAL: Unable to communicate with nova!"
    exit 2
fi

declare -A ip_array
for instance_data in ${instance_array[@]}; do
    node=$(echo ${instance_data} | cut -d';' -f3)
    ip=$(echo ${instance_data} | cut -d';' -f4)
    ip_array[$node]+="${ip} "
done

declare -A result
critical_loss=0
critical_nodes=0
warning=0
for node in ${!ip_array[@]}; do
    print_val "Pinging IPs in node: ${node}"
    rnode=${node/-/_}
    raw=$(fping -C10 -q ${ip_array[$node]} 2>&1)
    OLDIFS=$IFS; IFS=$'\n' read -d '' -r -a lines <<< "${raw}"; IFS=$OLDIFS
    for line in "${lines[@]}"; do
        ping_result=$(parse_fping_output "${line}")
        if [[ $((${ping_result#*;} >= 100)) -gt 0 ]]; then
            critical_loss=1
        fi
        if [[ $((${ping_result#*;} > 0)) -gt 0 ]]; then
            result[$rnode]+="${ping_result%%;*}:${ping_result#*;}% "
            warning=1
        fi
        print_val "${node}: ${ping_result%%;*} ${ping_result#*;}%"
    done
done

alert_output=""
if [[ ${#result[@]} -gt 0 ]]; then
    print_val "DEBUG: Number of alerts = ${#result[@]}"
    alert_output="{\"packet_loss\":["
    for node in ${!result[@]}; do
        key=${node/_/-}
        ratio=$(echo "$(wc -w <<< ${result[$node]})/$(wc -w <<< ${ip_array[$key]})")
        if [[ $(echo "scale=2;${ratio}>${CRITICAL_PACKET_LOSS}"|bc) > 0 ]]; then
            critical_nodes=1
        fi
        alert_ips=${result[$node]// /,}
        alert_output+="{\"${key}\":\"${ratio}\",\"ips\":\"${alert_ips%,}\"},"
    done
    alert_output="${alert_output%,}]}"
fi
read -r vals <<< "${alert_output}"

# Exit status with message
if [[ ${critical_loss} -gt 0 && ${critical_nodes} -gt 0 ]]; then
    python -c 'import sys; import simplejson as json; \
               data=json.dumps(json.loads(sys.stdin.read()),sort_keys=True,indent=4);\
               print "'${ALERT_NAME}' CRITICAL NODES: %s" % (data)' <<< "${vals}"
    exit $STATE_CRITICAL
elif [[ ${critical_loss} -gt 0 && ${critical_nodes} -eq 0 ]]; then
    python -c 'import sys; import simplejson as json; \
               data=json.dumps(json.loads(sys.stdin.read()),sort_keys=True,indent=4);\
               print "'${ALERT_NAME}' CRITICAL INSTANCES: %s" % (data)' <<< "${vals}"
    exit $STATE_CRITICAL
elif [[ ${critical} -eq 0 && ${warning} -gt 0 ]]; then
    python -c 'import sys; import simplejson as json; \
               data=json.dumps(json.loads(sys.stdin.read()),sort_keys=True,indent=4);\
               print "'${ALERT_NAME}' WARNING: %s" % (data)' <<< "${vals}"
    exit $STATE_WARNING
else
    msg="${ALERT_NAME} OK: Able to ping all ${#instance_array[@]} instances "
    msg+="with 0% packet loss"
    echo $msg
    exit $STATE_OK
fi
