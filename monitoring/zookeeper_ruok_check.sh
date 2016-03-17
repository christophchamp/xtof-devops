#!/bin/bash

################################################################################
# Sensu plugin to check if ZooKeeper is running in a non-error state           #
################################################################################

# DESCRIPTION: This script will check if ZooKeeper is responding to "echo ruok"
#+ requests (with "imok"). If it does respond with "imok", exit with STATE_OK.
#+ If it does not respond at all, it will exit with STATE_CRITICAL.
# NOTE: This script assumes ZooKeeper in listening on ZOOKEEPER_PORT.

ALERT_NAME="CheckZooKeeperRuok"
PROGNAME=$(`which basename` $0)
VERSION="Version 1.2"
AUTHOR="Christoph Champ <christoph.champ@gmail.com>"

# Exit codes
STATE_OK=0
STATE_WARNING=1
STATE_CRITICAL=2
STATE_UNKNOWN=3
STATE_DEPENDENT=4

NC=$(which nc)
ZOOKEEPER_PORT=2181

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

raw=($(netstat -plant|awk -F':' '/:'${ZOOKEEPER_PORT}' /{print $8}'))

if [[ $(echo ${#raw[@]}) -eq 0 ]]; then
    echo "${ALERT_NAME} CRITICAL: Could not find any ZooKeeper hosts"
    exit $STATE_CRITICAL
fi

# Get a sorted and unique set of ZooKeeper IPs
zk_hosts=($(tr ' ' '\n' <<< "${raw[@]}" |\
    sort -t . -k 3,3n -k 4,4n -u | tr '\n' ' '))

# Create a JSON output/payload string
critical=0
json_str="{\"payload\":["
DC=$(which_dc) # Get the 3-letter data centre value (e.g., "sea")
n=0
for zk in ${zk_hosts[@]}; do
    id="${DC}-$(($(date +%s) + ((n++))))"
    node=$(getent hosts $zk | awk '{print $3}')
    if [[ $(echo ruok | ${NC} -n -w 2 $zk ${ZOOKEEPER_PORT}) == "imok" ]]; then
        json_str+="{\"dc\":\"${DC}\",\"id\":\"${id}\","
        json_str+="\"node\":\"${node}\",\"ip\":\"${zk}\",\"status\":\"imok\"},"
    else
        critical=1
        json_str+="{\"dc\":\"${DC}\",\"id\":\"${id}\","
        json_str+="\"node\":\"${node}\",\"ip\":\"${zk}\",\"status\":\"dead\"},"
    fi
done
json_str="${json_str%,}]}"
payload=$(echo "${json_str}" | python -mjson.tool)

# Exit status with message
if [[ ${critical} -gt 0 ]]; then
    msg="${ALERT_NAME} CRITICAL: ZooKeeper is not responding on midonet-gw "
    msg+="nodes: ${payload}"
    echo "${msg}"
    exit $STATE_CRITICAL
else
    msg="${ALERT_NAME} OK: ZooKeeper is responding on midonet-gw nodes:"
    echo "${msg} ${payload}"
    exit $STATE_OK
fi
