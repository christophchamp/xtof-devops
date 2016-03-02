#!/bin/bash

################################################################################
# Sensu plugin to check if all instances are pingable                          #
################################################################################

ALERT_NAME="CheckNovaPing"
PROGNAME=$(`which basename` $0)
VERSION="Version 1.7"
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

# Percent packet loss allowed before we trigger alerts
WARNING_PACKET_LOSS=0
CRITICAL_PACKET_LOSS=0.99

SSH=$(which ssh)
PING=$(which ping)
FPING=$(which fping)
GREP=$(which grep)
NOVA=$(which nova)
DC=$(hostname|cut -d'-' -f3)

# Jenkins-related global variables
JENKINS_DASHBOARD="http://jenkins.example.com:8080/view/Openstack-dashboard/"
JENKINS_ENDPOINT="http://jenkins.example.com:8080/buildByToken/buildWithParameters"
JENKINS_JOB="${DC}-sensu-receiver"
JENKINS_TOKEN="<REDACED>"
JENKINS_ISSUE_TYPE="check-nova-ping-instances"
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
    echo " -n <node>  short node name (e.g., node-7)"
    echo " -j <0|1>   Run Jenkins? 0=no; 1=yes"
    echo " -V         Print version information"
    echo " -v         Verbose output"
    echo -e "\nExample:"
    echo "./${PROGNAME} -H fuel-ashburn.example.com -n node-7 -j 1"
}

# Parse command line options
while getopts 'h:H:n:j:Vv' OPTION
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
        j)
            export RUN_JENKINS=$OPTARG
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
    # This function returns an array of all Nova instances whose values are
    # defined by $fields and who meet the following criteria:
    #   - Any tenant;
    #   - Has a floating IP associated;
    #   - Is ACTIVE and running on a compute node; and
    #   - Has the "default" secgroup associated.
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
    vm_name=$(echo ${instance_data} | cut -d';' -f2)
    ip=$(echo ${instance_data} | cut -d';' -f4)
    ip_array[$node]+="${vm_name}:${ip} "
done

declare -A result
critical_loss=0
critical_nodes=0
warning=0
for node in ${!ip_array[@]}; do
    print_val "Pinging IPs in node: ${node}"
    rnode=${node/-/_}
    ip_list=$(echo ${ip_array[$node]} | sed -e 's/[a-z0-9-]\+://g')
    vm_name_list=$(echo ${ip_array[$node]} |\
        sed 's/:\([0-9]\{1,3\}\.\)\{3\}[0-9]\{1,3\}//g')
    #raw=$(${FPING} -C10 -q ${ip_array[$node]} 2>&1 | grep -v "Host Unreachable")
    print_val "REFID: ${DC}-$(date +%s)"
    print_val "VM_NAMES: ${vm_name_list[@]}"
    print_val "FPING: ${FPING} -c10 -qs ${ip_list} 2>&1 | grep -v 'Host Unreachable'"
    raw=$(${FPING} -C10 -q ${ip_list} 2>&1 | grep -v "Host Unreachable")
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
        # E.g., "node-13: 10.193.35.228 100%"
        print_val "${node}: ${ping_result%%;*} ${ping_result#*;}%"
    done
done

# We now construct a JSON string from the results of our ping check
alert_output=""
if [[ ${#result[@]} -gt 0 ]]; then
    print_val "DEBUG: Number of alerts = ${#result[@]}"
    alert_output="{\"payload\":["
    for node in ${!result[@]}; do
        node_name=${node/_/-}
        ratio=$(echo "$(wc -w <<< ${result[$node]})/$(wc -w <<< ${ip_array[$node_name]})")
        if [[ $(echo "scale=2;${ratio}>${CRITICAL_PACKET_LOSS}"|bc) > 0 ]]; then
            critical_nodes=1
        fi
        alert_ips=${result[$node]// /,}
        json="{\"id\":\"${DC}-$(date +%s)\",\"dc\":\"${DC}\","
        json+="\"node\":\"${node_name}\",\"ratio\":\"${ratio}\","
        json+="\"ips\":\"${alert_ips%,}\"},"
        alert_output+=${json}
    done
    alert_output="${alert_output%,}]}"
fi
read -r json_str <<< "${alert_output}"

function create_jenkins_payload() {
    # This function strips out unneeded JSON key/values and then converts the
    # payload into base64 as a return string
    payload="$1"
    payloads=$(
    python - <<EOF
import sys
import os
import re
import base64
import simplejson as json
for key, value in json.loads(os.environ["data"]).iteritems():
    if type(value) == type(['']):
        for sub_value in value:
            sub_value["ips"]=re.sub(r":100%,?", r" ", sub_value["ips"]).strip()
            result=json.dumps(json.loads('{"%s":[%s]}' % (key, json.dumps(sub_value))))
            print base64.b64encode(result)
EOF
    )
    echo "${payloads}"
}

# Exit status with message
if [[ ${critical_loss} -gt 0 && ${critical_nodes} -gt 0 && ${RUN_JENKINS} -eq 0 ]]; then
    # We arrive here if there are node(s) where 100% of the instances on the
    # give node(s) have 100% packet loss _and_ our Jenkins "self-heal"
    # process failed after two attempts.
    msg="${ALERT_NAME} CRITICAL NODES"
    export data=$(python -c 'import sys; import simplejson as json; \
               data=json.dumps(json.loads(sys.stdin.read()),sort_keys=True,indent=4);\
               print data' <<< "${json_str}")
    if [[ $(awk -F'=' -vjenkins=${JENKINS_ISSUE_TYPE} \
            '$0 ~ jenkins{print $2}' ${JENKINS_ALERT_FILE}) -gt 1 ]]; then
        echo "${msg} [<a href=\"${JENKINS_DASHBOARD}\">click here</a>]: ${data}"
        exit $STATE_CRITICAL
    fi
elif [[ ${critical_loss} -gt 0 && ${critical_nodes} -gt 0 && ${RUN_JENKINS} -eq 1 ]]; then
    # We arrive here if there are node(s) where 100% of the instances on the
    # give node(s) have 100% packet loss and we are going to submit a job to
    # Jenkins to have it attempt to "self-heal" the issue.
    msg="${ALERT_NAME} CRITICAL NODES"
    export data=$(python -c 'import sys; import simplejson as json; \
               data=json.dumps(json.loads(sys.stdin.read()),sort_keys=True,indent=4);\
               print data' <<< "${json_str}")
    echo "${msg}: ${data}"
    #payload=$(echo ${data} | base64 -w0)

    # Increment the integer value associated with the key in the dotfile, where
    # "key" is the alert name/issue type (e.g., "check-nova-ping-instances").
    # Note: We have to `sudo sed`, since in-line file editing creates a tmp file
    # with permission issues.
    sudo sed -i'' -r 's/('"${JENKINS_ISSUE_TYPE}"')=(.*)/echo \1=$((\2+1))/ge' ${JENKINS_ALERT_FILE}

    # If the integer value associated with the key in the dotfile is less than
    # "2", we have not hit our Jenkins threshold yet (i.e., we will not
    # send a critical alert to enterprise_monitoring (aka NOC Team).
    if [[ $(awk -F'=' -vjenkins=${JENKINS_ISSUE_TYPE} \
            '$0 ~ jenkins{print $2}' ${JENKINS_ALERT_FILE}) -lt 2 ]]; then
        payloads=($(create_jenkins_payload ${data}))
        for payload in "${payloads[@]}"; do
            curl_opts="${JENKINS_ENDPOINT}"
            curl_opts+="?job=${JENKINS_JOB}"
            curl_opts+="&token=${JENKINS_TOKEN}"
            curl_opts+="&issue_type=${JENKINS_ISSUE_TYPE}"
            curl_opts+="&payload=${payload}"
            print_val "curl -s \"${curl_opts}\""
            curl -s ${curl_opts}
        done
    fi
    exit $STATE_CRITICAL
elif [[ ${critical_loss} -gt 0 && ${critical_nodes} -eq 0 ]]; then
    # We arrive here if one or more instances (but less than 100% of the
    # instances on a given node(s)) have 100% packet loss.
    python -c 'import sys; import simplejson as json; \
               data=json.dumps(json.loads(sys.stdin.read()),sort_keys=True,indent=4);\
               print "'${ALERT_NAME}' CRITICAL INSTANCES: %s" % (data)' <<< "${json_str}"
    exit $STATE_CRITICAL
elif [[ ${critical} -eq 0 && ${warning} -gt 0 ]]; then
    # We arrive here if one or more instances on any node have packet loss
    # greater than 0% but less than 100%.
    python -c 'import sys; import simplejson as json; \
               data=json.dumps(json.loads(sys.stdin.read()),sort_keys=True,indent=4);\
               print "'${ALERT_NAME}' WARNING: %s" % (data)' <<< "${json_str}"
    exit $STATE_WARNING
else
    # SUCCESS! We arrive here if no instance on any node has any packet loss.
    msg="${ALERT_NAME} OK: Able to ping all ${#instance_array[@]} instances "
    msg+="with 0% packet loss"
    echo $msg

    # Reset the integer value associated with the key in the dotfile back to 0
    # E.g., "check-nova-ping-instances=0"
    sudo sed -i'' -r 's/('"${JENKINS_ISSUE_TYPE}"')=(.*)/echo \1=0/ge' ${JENKINS_ALERT_FILE}

    exit $STATE_OK
fi
