#!/bin/bash

################################################################################
# Sensu plugin to check if ZooKeeper is running in a non-error state           #
################################################################################

# DESCRIPTION: This script will check if ZooKeeper is responding to "echo ruok"
#+ requests (with "imok"). If it does respond with "imok", exit with STATE_OK.
#+ If it does not respond at all, it will exit with STATE_CRITICAL.
# NOTE: This script assumes ZooKeeper in listening on ZOOKEEPER_PORT.

set -e
ALERT_NAME="CheckZooKeeperRuok"
PROGNAME=$(`which basename` $0)
VERSION="Version 1.0"
AUTHOR="Christoph Champ <christoph.champ@gmail.com>"

# Exit codes
STATE_OK=0
STATE_WARNING=1
STATE_CRITICAL=2
STATE_UNKNOWN=3
STATE_DEPENDENT=4

NC=$(which nc)
ZOOKEEPER_PORT=2181

raw=($(netstat -plant|awk -F':' '/:'${ZOOKEEPER_PORT}' /{print $8}'))

if [[ $(echo ${#raw[@]}) -eq 0 ]]; then
    echo "${ALERT_NAME} CRITICAL: Could not find any ZooKeeper hosts"
    exit $STATE_CRITICAL
fi

# Get a unique set of ZooKeeper IPs
zk_hosts=($(tr ' ' '\n' <<< "${raw[@]}" | sort -t . -k 3,3n -k 4,4n -u | tr '\n' ' '))

# Populate array with results
declare -A alert_array
for zk in ${zk_hosts[@]}; do
    node=$(getent hosts $zk|awk '{print $3}');
    if [[ $(echo ruok | ${NC} -n -w 2 $zk ${ZOOKEEPER_PORT}) == "imok" ]]; then
        alert_array["ok"]+="${node} (${zk});"
    else
        alert_array["critical"]+="${node} (${zk});"
        echo "CRITICAL: $zk";
    fi;
done

# Exit status with message
if [[ ${#alert_array["critical"]} -gt 0 ]]; then
    echo "${ALERT_NAME} CRITICAL: ZooKeeper is not responding on midonet-gw nodes: {${alert_array["critical"]}}"
    exit $STATE_CRITICAL
else
    echo "${ALERT_NAME} OK: ZooKeeper is responding on midonet-gw nodes: {${alert_array["ok"]}}"
    exit $STATE_OK
fi
