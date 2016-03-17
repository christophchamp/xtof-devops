#!/bin/bash

################################################################################
# Sensu plugin to check if all Neutron agents are up                           #
################################################################################

ALERT_NAME="CheckNeutronAgents"
PROGNAME=$(`which basename` $0)
VERSION="Version 1.2"
AUTHOR="Christoph Champ <christoph.champ@gmail.com>"

source /etc/sensu/plugins/openrc

# Exit codes
STATE_OK=0
STATE_WARNING=1
STATE_CRITICAL=2
STATE_UNKNOWN=3
STATE_DEPENDENT=4

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

# Get status of all neutron agents
set -o pipefail
raw=($(neutron agent-list 2>/dev/null|\
       awk -F'|' '/neutron/{
         gsub(":-)","UP");
         gsub(/\.(example.com|example.local)/,"");
         gsub(" ","");
         printf "%s;%s;%s;%s\n",$4,$7,$5,$6}'))
if [[ ${PIPESTATUS[0]} -gt 0 ]]; then
    echo "${ALERT_NAME} UKNOWN: Unable to run neutron agent-list"
    exit $STATE_UNKNOWN
fi
agents_status=($(tr ' ' '\n' <<< "${raw[@]}" | sort | tr '\n' ' '))

if [[ ${#agents_status[@]} -eq 0 ]]; then
    echo "${ALERT_NAME} CRITICAL: Unable to communicate with neutron!"
    exit $STATE_CRITICAL
fi

# Create JSON payload with results of alive/dead agents
critical=0
alive="\"alive\":["
dead="\"dead\":["
DC=$(which_dc) # Get the 3-letter data centre value (e.g., "sea")
n=0
for agent in ${agents_status[@]}; do
    node=$(echo ${agent} | cut -d';' -f1)
    agent_name=$(echo ${agent} | cut -d';' -f2)
    is_alive=$(echo ${agent} | awk -F';' '{print $3}')
    admin_state_up=$(echo ${agent} | awk -F';' '{print $4}')
    id=$(($(date +%s) + ((n++))))
    if [[ "${is_alive}" == "UP" && "${admin_state_up}" == "True" ]]; then
        alive+="{\"dc\":\"${DC}\",\"id\":\"${DC}-${id}\",\"node\":\"${node}\",\"agent\":\"${agent_name}\"},"
    else
        critical=1
        dead+="{\"dc\":\"${DC}\",\"id\":\"${DC}-${id}\",\"node\":\"${node}\",\"agent\":\"${agent_name}\"},"
    fi
done
payload=$(echo "{\"payload\":[{${alive%,}],${dead%,}]}]}" | python -mjson.tool)

# Exit status with message
if [[ ${critical} -gt 0 ]]; then
    echo "${ALERT_NAME} CRITICAL: The following Neutron agents are down: ${payload}"
    exit $STATE_CRITICAL
else
    echo "${ALERT_NAME} OK: All Neutron agents are up"
    exit $STATE_OK
fi
