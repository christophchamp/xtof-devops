#!/bin/bash

################################################################################
# Sensu plugin to check if all Neutron agents are up                           #
################################################################################

set -e
ALERT_NAME="NeutronAgentCheck"
PROGNAME=$(`which basename` $0)
VERSION="Version 1.0"
AUTHOR="Christoph Champ <christoph.champ@gmail.com>"

source /etc/sensu/plugins/openrc

# Exit codes
STATE_OK=0
STATE_WARNING=1
STATE_CRITICAL=2
STATE_UNKNOWN=3
STATE_DEPENDENT=4

# Get status of all neutron agents
raw=($(neutron agent-list|\
       awk -F'|' '/neutron/{
         gsub(":-)","UP");
         gsub(/\.(example.com|example.local)/,"");
         gsub(" ","");
         printf "%s;%s;%s;%s\n",$7,$4,$5,$6}'))
agents_status=($(tr ' ' '\n' <<< "${raw[@]}" | sort | tr '\n' ' '))

# Populate array with results
declare -A alert_array
for agent in ${agents_status[@]}; do
    agent_status=$(echo ${agent}|\
                   awk -F';' '{gsub(";True","");gsub(";","::");print $0}')
    alive=$(echo ${agent} | awk -F';' '{print $3}')
    admin_state_up=$(echo ${agent} | awk -F';' '{print $4}')
    if [[ "${alive}" == "UP" && "${admin_state_up}" == "True" ]]; then
        alert_array["ok"]+="${agent_status}; "
    else
        alert_array["critical"]+="${agent_status}; "
    fi
done

# Exit status with message
msg=""
if [[ ${#alert_array["critical"]} -gt 0 ]]; then
    msg="${ALERT_NAME} CRITICAL: The following Neutron agents are down: "
    msg+="{${alert_array["critical"]}}"
    exit $STATE_CRITICAL
else
    echo "${ALERT_NAME} OK: All Neutron agents are up: {${alert_array["ok"]}}"
    exit $STATE_OK
fi
