#!/bin/bash

################################################################################
# Sensu plugin to monitor ability of build Nova instances                      #
################################################################################

# DESCRIPTION: This script attempts to build a Nova instance (i.e., nova boot)
#+ from a randomly selected controller/conductor node (from nova service-list),
#+ ping the instance's public IP, ssh into the instance, and then delete it.
#+ It will run the process on each compute node for all availability zones.
#+ If, at any step along the process, something fails, it will alert which
#+ process(es) failed on which compute node and from which conductor node.

ALERT_NAME="CheckNovaBoot"
PROGNAME=$(`which basename` $0)
VERSION="Version 1.2"
AUTHOR="Christoph Champ <christoph.champ@gmail.com>"

# Exit codes
STATE_OK=0
STATE_WARNING=1
STATE_CRITICAL=2
STATE_UNKNOWN=3
STATE_DEPENDENT=4

source /etc/sensu/plugins/openrc
export OS_TENANT_NAME='admin' # override openrc

if [[ "$(hostname)" == "node-12.example.local" ]]; then
    echo "${ALERT_NAME} OK: Skipping check on fuel-lab"
    exit $STATE_OK
fi

PING=$(which ping)
GREP=$(which grep)
SSH=$(which ssh)
NOVA=$(which nova)
NEUTRON=$(which neutron)
SENSU_SSH_KEY=/etc/sensu/plugins/sensu-key
PACKET_LOSS=20 # ping packet loss threshold to trigger alert

NOVA_FLAVOR=m1.small
NOVA_IMAGE=TestVM
NOVA_SECGROUP=default
NOVA_KEYNAME=sensu
INSTANCE_NAME_PREFIX=sensu-nova-boot-check
NOVA_BUILD_TIMEOUT=300 # Exit with status "CRITICAL" if build takes longer than this

function print_val {
  if [[ $verbosity -ge 1 ]]; then
    echo $1
  fi
}

# Main #########################################################################

# Verbosity level
verbosity=0

declare -A alert_array

function nova_boot() {
    local az="$1"
    local compute_node="$2"
    local instance_name="$3"
    local msg=""
    local result="X:xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

    # Capture "node-XX" part
    local node=$(sed -e 's/.*\(node-[0-9]\+\)/\1/g' <<< "${instance_name}")

    # Start building instance
    ${NOVA} --os-tenant-name ${OS_TENANT_NAME} boot --flavor ${NOVA_FLAVOR} \
            --image ${NOVA_IMAGE} --security-groups ${NOVA_SECGROUP} \
            --nic net-id=${EXT_NET_ID} --key-name ${NOVA_KEYNAME} \
            --availability-zone ${az}:${compute_node} \
            ${instance_name} > /dev/null 2>&1

    sleep 2

    # Get initial state of build
    VM_INFO=$(${NOVA} --os-tenant-name ${OS_TENANT_NAME} list | \
        awk -v regex="${instance_name}" '$4 ~ regex {printf "%s;%s;%s",$2,$6,$10}')
    VM_UUID=$(echo ${VM_INFO}|awk -F';' '{print $1}')
    VM_STATUS=$(echo ${VM_INFO}|awk -F';' '{print tolower($2)}')
    VM_POWER_STATE=$(echo ${VM_INFO}|awk -F';' '{print tolower($3)}')

    result="WAIT:${VM_UUID}"

    # Keep checking state until success or failure
    TIME_START=$(date +%s)
    until [[ ${VM_STATUS} == "active" && ${VM_POWER_STATE} == "running" ]]; do
        VM_INFO=$(${NOVA} --os-tenant-name ${OS_TENANT_NAME} list | \
            awk -v regex="${instance_name}" '$4 ~ regex {printf "%s;%s;%s",$2,$6,$10}')
        VM_STATUS=$(echo ${VM_INFO}|awk -F';' '{print tolower($2)}')
        VM_POWER_STATE=$(echo ${VM_INFO}|awk -F';' '{print tolower($3)}')

        sleep 5

        TIME_END=$(date +%s)
        TIME_DELTA=$((TIME_END-TIME_START))
        if [[ ${TIME_DELTA} -gt ${NOVA_BUILD_TIMEOUT} ]]; then
            #msg="${ALERT_NAME} CRITICAL: nova boot process on "
            #msg+="${az}:${compute_node} took longer than "
            #msg+="${NOVA_BUILD_TIMEOUT} seconds"
            #delete_instance ${VM_UUID} ${instance_name}
            #exit $STATE_CRITICAL
            result="CRITICAL:${VM_UUID}"
            break
        fi
        if [[ ${VM_STATUS} == "error" ]]; then
            #msg="${ALERT_NAME} CRITICAL: nova boot process on "
            #msg+="${az}:${compute_node} failed after ${NOVA_BUILD_TIMEOUT} "
            #msg+=seconds"
            #delete_instance ${VM_UUID} ${instance_name}
            #exit $STATE_CRITICAL
            result="CRITICAL:${VM_UUID}"
            break
        fi
    done

    # Instance should now be ACTIVE, so return results
    result="OK:${VM_UUID}"
    echo ${result}
}

function delete_instance() {
    local vm_uuid="$1"
    local instance_name="$2"
    local node=$(sed -e 's/.*\(node-[0-9]\+\)/\1/g' <<< "${instance_name}")
    DELETE_REQUEST=$(${NOVA} --os-tenant-name ${OS_TENANT_NAME} delete ${vm_uuid} 2>/dev/null | \
                     awk '/accepted/{print "SUCCESS"}')
    sleep 10 # Give delete process time to complete
    IS_DELETED_A=$(${NOVA} --os-tenant-name ${OS_TENANT_NAME} show ${vm_uuid} 2>&1 | \
                   awk '/No server with/{print "YES"}')
    sleep 5 # Make sure instance has really been deleted
    IS_DELETED_B=$(${NOVA} --os-tenant-name ${OS_TENANT_NAME} delete ${vm_uuid} 2>&1 | \
                   awk '/No server with/{print "YES"}')
    if [[ ${DELETE_REQUEST} == "SUCCESS" && \
          ${IS_DELETED_A} == "YES" && ${IS_DELETED_B} == "YES" ]]; then
        print_val "DEBUG: Successfully deleted ${instance_name}"
        alert_array["delete"]+="${node}:${STATE_OK};"
    else
        print_val "DEBUG: WARNING: ${instance_name} might not have deleted successfully"
        alert_array["delete"]+="${node}:${STATE_WARNING};"
    fi
}

function cleanup_failed_deleted_instances() {
    # This function checks if there are any sensu-nova-boot-check instances
    # that failed to delete in the previous run of the check. If it finds
    # any instances that match the check and are over 1 hour old, it will
    # try to delete them.
    fields="name,created"
    instance_array=($(${NOVA} --os-tenant-name ${OS_TENANT_NAME} list --fields ${fields} | \
        awk -W posix -F'|' '$2 ~ /[[:alnum:]-]{36}/{
        gsub(" |\t","");printf "%s;%s;%s\n",$2,$3,$4}'))

    for instance_data in ${instance_array[@]}; do
        uuid=$(echo ${instance_data} | cut -d';' -f1)
        vm_name=$(echo ${instance_data} | cut -d';' -f2)
        created=$(echo ${instance_data} | cut -d';' -f3 | \
            awk '{gsub("T"," ");gsub("Z","");print $0}')
        let DELTA=($(date -u '+%s')-$(date -d "${created}" '+%s'))
        match=$(awk -vsensu=${INSTANCE_NAME_PREFIX} \
            '/sensu/{print substr($0,0,21)}' <<< "${vm_name}")
        if [[ "${match}" == "${INSTANCE_NAME_PREFIX}" ]] && \
           [[ ${DELTA} -gt 3600 ]]; then
            delete_instance ${uuid} ${vm_name}
        fi
    done
}

# We generate an array of controller hostnames, pick a random one from the list
#+ and if the random hostname matches the hostname of the node this script is
#+ on, continue with the check process. Exit otherwise. This is to prevent the
#+ script being run on all of the controller nodes at the same time.
CONTROLLERS=($(nova service-list|awk -F'|' '/nova-conductor/{gsub(" ","",$0);print $4}'))
RANDOM_CONTROLLER=$(echo ${CONTROLLERS[$RANDOM % ${#CONTROLLERS[@]}]})
if [[ "$(hostname)" == "${RANDOM_CONTROLLER}" ]]; then
    CONTROLLER=$(echo ${RANDOM_CONTROLLER} | sed -e 's/^\(node-[0-9]\+\).*/\1/g')
else
    echo "${ALERT_NAME} OK: Check running on other controller node (${RANDOM_CONTROLLER})"
    exit $STATE_OK
fi

cleanup_failed_deleted_instances

#== Begin the Nova boot check process =========================================

print_val "DEBUG: Retrieving external-network name..."
#EXT_NET_NAME=$(neutron net-external-list |\
#               awk -W posix -F'|' '$2 ~ /[[:alnum:]-]{36}/{gsub(" ","");print $3}')
EXT_NET_NAME=$(${NOVA} floating-ip-list|awk '$2 ~ /^10\./{print $8;exit}')
if [[ -z ${EXT_NET_NAME} ]]; then
    echo "${ALERT_NAME} CRITICAL: Could not retrieve external-network name"
    exit $STATE_CRITICAL
fi

# Needs to be able to handle names like "ext_net05-10.211.128.0/18"
print_val "DEBUG: Retrieving external-network UUID..."
#EXT_NET_ID=$(neutron net-list -- --name ${EXT_NET_NAME} --fields id)
EXT_NET_ID=$(${NEUTRON} net-list |\
    awk -v regex="${EXT_NET_NAME}" '$4 ~ regex {print $2}')
if [[ -z ${EXT_NET_ID} ]]; then
    echo "${ALERT_NAME} CRITICAL: Could not retrieve external-network UUID"
    exit $STATE_CRITICAL
fi

# Create an array of compute nodes for "az1"/"az2" availability zones
print_val "DEBUG: Getting a list of availability zones and associated compute nodes..."
ZONE_NAMES=( 'az1' 'az2' )
AZ_NODES=$(${NOVA} --os-tenant-name ${OS_TENANT_NAME} availability-zone-list)
AZ1_NODES=($(awk '/az1/,/^+/{if ($3 ~ /node/){print $3}}' <<< "${AZ_NODES}"))
AZ2_NODES=($(awk '/az2/,/az1/{if ($3 ~ /node/){print $3}}' <<< "${AZ_NODES}"))

# This is the main section where each function is run
# TODO: Collapse into a for-loop
#for zone in ${ZONE_NAMES[@]}; do
# Run through whole process in availability zone "az1"
zone="az1"
for compute_node in ${AZ1_NODES[@]}; do
    #compute_node="node-11.example.com"
    #node="node-11"
    node=$(echo ${compute_node} | sed -e 's/\(node-[0-9]\+\).*/\1/g')
    instance_name=${INSTANCE_NAME_PREFIX}-${CONTROLLER}-${node}

    print_val "DEBUG: Running nova boot from ${CONTROLLER} on ${zone}:${node} (${compute_node})"
    RESULT=$(nova_boot ${zone} ${compute_node} ${instance_name})
    VM_UUID=${RESULT#*:}
    if [[ ${RESULT%%:*} == "OK" ]]; then
        alert_array["boot"]+="${node}:${STATE_OK};"
    else
        alert_array["boot"]+="${node}:${STATE_CRITICAL};"
    fi

    print_val "DEBUG: Attempting to delete instance [UUID: ${VM_UUID}]..."
    delete_instance ${VM_UUID} ${instance_name}
done

# Run through whole process in availability zone "az2"
zone="az2"
for compute_node in ${AZ2_NODES[@]}; do
    node=$(echo ${compute_node} | sed -e 's/\(node-[0-9]\+\).*/\1/g')
    instance_name=${INSTANCE_NAME_PREFIX}-${CONTROLLER}-${node}

    print_val "DEBUG: Running nova boot from ${CONTROLLER} on ${zone}:${node} (${compute_node})"
    RESULT=$(nova_boot ${zone} ${compute_node} ${instance_name})
    VM_UUID=${RESULT#*:}
    if [[ ${RESULT%%:*} == "OK" ]]; then
        alert_array["boot"]+="${node}:${STATE_OK};"
    else
        alert_array["boot"]+="${node}:${STATE_CRITICAL};"
    fi

    print_val "DEBUG: Attempting to delete instance [UUID: ${VM_UUID}]..."
    delete_instance ${VM_UUID} ${instance_name}
done

# TODO: The following should really be in a function
declare -A boot_arr ping_arr ssh_arr delete_arr
is_critical=0
is_warning=0
re='^[0-9]$'

# Parse boot alerts
OLDIFS=$IFS; IFS=';' read -r -a bootvals <<< "${alert_array['boot']}"; IFS=$OLDIFS
for i in "${bootvals[@]}"; do
    if ! [[ ${i#*:} =~ $re ]]; then
        echo "${ALERT_NAME} UNKNOWN: Expecting integer value. Got \"${i}\" instead."
        exit ${STATE_UNKNOWN}
    fi
    if [[ "${i#*:}" -eq "1" ]]; then
        boot_arr["warning"]+="${i%%:*},"
        is_warning=1
    elif [[ "${i#*:}" -eq "2" ]]; then
        boot_arr["critical"]+="${i%%:*},"
        is_critical=1
    else
        boot_arr["ok"]+="${i%%:*},"
    fi
done

# Parse delete alerts
OLDIFS=$IFS; IFS=';' read -r -a deletevals <<< "${alert_array['delete']}"; IFS=$OLDIFS
for i in "${deletevals[@]}"; do
    if ! [[ ${i#*:} =~ $re ]]; then
        echo "${ALERT_NAME} UNKNOWN: Expecting integer value. Got \"${i}\" instead."
        exit ${STATE_UNKNOWN}
    fi
    if [[ "${i#*:}" -eq "1" ]]; then
        delete_arr["warning"]+="${i%%:*},"
        is_warning=1
    elif [[ "${i#*:}" -eq "2" ]]; then
        delete_arr["critical"]+="${i%%:*},"
        is_critical=1
    else
        delete_arr["ok"]+="${i%%:*},"
    fi
done

# using "! read" to override "set -e" (bit of a hack)
! read -r -d '' ALERT_MSG <<- EOM
OK: {"boot": "${boot_arr['ok']%,}", "delete": "${delete_arr['ok']%,}"}
WARNING: {"boot": "${boot_arr['warning']%,}", "delete": "${delete_arr['warning']%,}"}
CRITICAL: {"boot": "${boot_arr['critical']%,}", "delete": "${delete_arr['critical']%,}"}
EOM

if [[ ${is_critical} -eq 1 ]]; then
    echo -e "${ALERT_NAME} CRITICAL: [${CONTROLLER}]\n${ALERT_MSG}"
    exit ${STATE_CRITICAL}
elif [[ ${is_warning} -eq 1 ]]; then
    echo -e "${ALERT_NAME} WARNING: [${CONTROLLER}]\n${ALERT_MSG}"
    exit ${STATE_WARNING}
else
    echo -e "${ALERT_NAME} OK: [${CONTROLLER}]\n${ALERT_MSG}"
    exit ${STATE_OK}
fi
