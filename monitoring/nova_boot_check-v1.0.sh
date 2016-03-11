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
VERSION="Version 1.0"
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

function ping_ip {
    local ip="$1"
    if [[ ${ip} =~ ^10\.[0-9]{,3}\.[0-9]{,3}\.[0-9]{,3} ]]; then 
        echo $(${PING} -c 3 -W 2 -q ${ip} | ${GREP} -oP '\d+(?=% packet loss)')
    else
        echo "ERROR"
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
    local result=""

    # Capture "node-XX" part
    local node=$(sed -e 's/.*\(node-[0-9]\+\)/\1/g' <<< "${instance_name}")

: <<'END'
END
    # Start building instance
    nova --os-tenant-name ${OS_TENANT_NAME} boot --flavor ${NOVA_FLAVOR} \
         --image ${NOVA_IMAGE} --security-groups ${NOVA_SECGROUP} \
         --nic net-id=${EXT_NET_ID} --key-name ${NOVA_KEYNAME} \
         --availability-zone ${az}:${compute_node} \
         ${instance_name} > /dev/null 2>&1

    sleep 2

    # Get initial state of build
    VM_INFO=$(nova --os-tenant-name ${OS_TENANT_NAME} list | \
        awk -v regex="${instance_name}" '$4 ~ regex {printf "%s;%s;%s",$2,$6,$10}')
    VM_UUID=$(echo ${VM_INFO}|awk -F';' '{print $1}')
    VM_STATUS=$(echo ${VM_INFO}|awk -F';' '{print tolower($2)}')
    VM_POWER_STATE=$(echo ${VM_INFO}|awk -F';' '{print tolower($3)}')

    # If the process immediately errors out, no need to continue
    if [[ ${VM_STATUS} == "error" ]]; then
        echo "${ALERT_NAME} CRITICAL: nova boot process on ${az}:${compute_node} failed"
        delete_instance ${VM_UUID} ${instance_name}
        exit $STATE_CRITICAL
    fi

    # Keep checking state until success or failure
    TIME_START=$(date +%s)
    until [[ ${VM_STATUS} == "active" && ${VM_POWER_STATE} == "running" ]]; do
        VM_INFO=$(nova --os-tenant-name ${OS_TENANT_NAME} list | \
            awk -v regex="${instance_name}" '$4 ~ regex {printf "%s;%s;%s",$2,$6,$10}')
        VM_STATUS=$(echo ${VM_INFO}|awk -F';' '{print tolower($2)}')
        VM_POWER_STATE=$(echo ${VM_INFO}|awk -F';' '{print tolower($3)}')

        sleep 5

        TIME_END=$(date +%s)
        TIME_DELTA=$((TIME_END-TIME_START))
        if [[ ${TIME_DELTA} -gt ${NOVA_BUILD_TIMEOUT} ]]; then
            echo "${ALERT_NAME} CRITICAL: nova boot process on ${az}:${compute_node} took longer than ${NOVA_BUILD_TIMEOUT} seconds"
            delete_instance ${VM_UUID} ${instance_name}
            exit $STATE_CRITICAL
        fi
        if [[ ${VM_STATUS} == "error" ]]; then
            echo "${ALERT_NAME} CRITICAL: nova boot process on ${az}:${compute_node} failed after ${NOVA_BUILD_TIMEOUT} seconds"
            delete_instance ${VM_UUID} ${instance_name}
            exit $STATE_CRITICAL
        fi
    done

    # Instance should now be ACTIVE, so return results
    echo "OK:${VM_UUID}"
}

function get_public_ip() {
    # Returns the instances external net IP. Should be a 10. address
    local vm_uuid="$1"
    echo $(nova --os-tenant-name ${OS_TENANT_NAME} show ${VM_UUID} | \
           awk -v regex="${EXT_NET_NAME}" '$2 ~ regex {print $5}')
}

function ping_check() {
    # See if we can ping instance's public IP
    local ip="$1"
    local instance_name="$2"
    local node=$(sed -e 's/.*\(node-[0-9]\+\)/\1/g' <<< "${instance_name}")

    PING_RESULT=$(ping_ip ${ip})
    if [[ ${PING_RESULT} != "ERROR" ]]; then
        if [[ ${PING_RESULT} < ${PACKET_LOSS} ]]; then
            print_val "DEBUG: pinging ${instance_name} with ${PING_RESULT}% packet loss"
            alert_array["ping"]+="${node}:${STATE_OK};"
        else
            print_val "DEBUG: WARNING: pinging ${instance_name} with ${PING_RESULT}% packet loss"
            alert_array["ping"]+="${node}:${STATE_WARNING};"
            #exit $STATE_WARNING
        fi
    else
        echo "${ALERT_NAME} WARNING: [PING_RESULT: ${instance_name} unknown result];"
        exit $STATE_WARNING
    fi
}

function ssh_check() {
    # See if we can SSH into newly created instance
    local ip="$1"
    local instance_name="$2"
    local node=$(sed -e 's/.*\(node-[0-9]\+\)/\1/g' <<< "${instance_name}")
    UPTIME_RESULT=$(${SSH} -q -i ${SENSU_SSH_KEY} \
                    -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null \
                    cirros@${ip} uptime 2>/dev/null | \
                    awk '$0 ~ /load/ {print $7}')
    #if [[ ! -z ${UPTIME_RESULT} ]]; then
    if [[ ${UPTIME_RESULT} == "load" ]]; then
        print_val "DEBUG: Able to SSH into ${instance_name}"
        alert_array["ssh"]+="${node}:${STATE_OK};"
    else
        print_val "DEBUG: WARNING: Not able to SSH into ${instance_name}"
        alert_array["ssh"]+="${node}:${STATE_WARNING};"
        #exit $STATE_WARNING
    fi
}

function delete_instance() {
    local vm_uuid="$1"
    local instance_name="$2"
    local node=$(sed -e 's/.*\(node-[0-9]\+\)/\1/g' <<< "${instance_name}")
    DELETE_REQUEST=$(nova --os-tenant-name ${OS_TENANT_NAME} delete ${vm_uuid} 2>/dev/null | \
                     awk '/accepted/{print "SUCCESS"}')
    sleep 10 # Give delete process time to complete
    IS_DELETED_A=$(nova --os-tenant-name ${OS_TENANT_NAME} show ${vm_uuid} 2>&1 | \
                   awk '/No server with/{print "YES"}')
    sleep 5 # Make sure instance has really been deleted
    IS_DELETED_B=$(nova --os-tenant-name ${OS_TENANT_NAME} delete ${vm_uuid} 2>&1 | \
                   awk '/No server with/{print "YES"}')
    if [[ ${DELETE_REQUEST} == "SUCCESS" && \
          ${IS_DELETED_A} == "YES" && ${IS_DELETED_B} == "YES" ]]; then
        print_val "DEBUG: Successfully deleted ${instance_name}"
        alert_array["delete"]+="${node}:${STATE_OK};"
    else
        print_val "DEBUG: WARNING: ${instance_name} might not have deleted successfully"
        alert_array["delete"]+="${node}:${STATE_WARNING};"
        #exit $STATE_WARNING
    fi
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

#== Begin the Nova boot check process =========================================

print_val "DEBUG: Retrieving external-network name..."
#EXT_NET_NAME=$(neutron net-external-list |\
#               awk -W posix -F'|' '$2 ~ /[[:alnum:]-]{36}/{gsub(" ","");print $3}')
EXT_NET_NAME=$(nova floating-ip-list|awk '$2 ~ /^10\./{print $8}'|head -1)
if [[ -z ${EXT_NET_NAME} ]]; then
    echo "${ALERT_NAME} CRITICAL: Could not retrieve external-network name"
    exit $STATE_CRITICAL
fi

# Needs to be able to handle names like "ext_net05-10.211.128.0/18"
print_val "DEBUG: Retrieving external-network UUID..."
#EXT_NET_ID=$(neutron net-list -- --name ${EXT_NET_NAME} --fields id)
EXT_NET_ID=$(neutron net-list | awk -v regex="${EXT_NET_NAME}" '$4 ~ regex {print $2}')
if [[ -z ${EXT_NET_ID} ]]; then
    echo "${ALERT_NAME} CRITICAL: Could not retrieve external-network UUID"
    exit $STATE_CRITICAL
fi

# Create an array of compute nodes for "az1"/"az2" availability zones
print_val "DEBUG: Getting a list of availability zones and associated compute nodes..."
ZONE_NAMES=( 'az1' 'az2' )
AZ_NODES=$(nova --os-tenant-name ${OS_TENANT_NAME} availability-zone-list)
AZ1_NODES=($(awk '/az1/,/^+/{if ($3 ~ /node/){print $3}}' <<< "${AZ_NODES}"))
AZ2_NODES=($(awk '/az2/,/az1/{if ($3 ~ /node/){print $3}}' <<< "${AZ_NODES}"))

# This is the main section where each function is run
# FIXME: Collapse into a for loop
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
    if [[ ${RESULT%%:*} == "OK" ]]; then
        VM_UUID=${RESULT#*:}
        alert_array["boot"]+="${node}:${STATE_OK};"
    else
        echo "ERROR: Could not obtain VM_UUID"
        exit $STATE_CRITICAL
    fi

    print_val "DEBUG: Retrieving instance's public IP..."
    VM_EXT_NET_IP=$(get_public_ip ${VM_UUID})
    print_val "DEBUG: Found VM_EXT_NET_IP=${VM_EXT_NET_IP}"

    sleep 5 # Give NIC time to come up

    print_val "DEBUG: Attempting to ping instance ${instance_name} IP: ${VM_EXT_NET_IP} ..."
    ping_check ${VM_EXT_NET_IP} ${instance_name}

    print_val "DEBUG: Attempting to SSH into instance: ${instance_name} ..."
    ssh_check ${VM_EXT_NET_IP} ${instance_name}

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
    if [[ ${RESULT%%:*} == "OK" ]]; then
        VM_UUID=${RESULT#*:}
        alert_array["boot"]+="${node}:${STATE_OK};"
    else
        echo "ERROR: Could not obtain VM_UUID"
        exit $STATE_CRITICAL
    fi

    print_val "DEBUG: Retrieving instance's public IP..."
    VM_EXT_NET_IP=$(get_public_ip ${VM_UUID})
    print_val "DEBUG: Found VM_EXT_NET_IP=${VM_EXT_NET_IP}"

    sleep 5 # Give NIC time to come up

    print_val "DEBUG: Attempting to ping instance ${instance_name} IP: ${VM_EXT_NET_IP} ..."
    ping_check ${VM_EXT_NET_IP} ${instance_name}

    print_val "DEBUG: Attempting to SSH into instance: ${instance_name} ..."
    ssh_check ${VM_EXT_NET_IP} ${instance_name}

    print_val "DEBUG: Attempting to delete instance [UUID: ${VM_UUID}]..."
    delete_instance ${VM_UUID} ${instance_name}
done

# FIXME: The following should really be in a function
: <<'END'
#declare -A boot_arr=( ["ok"]="" ["warning"]="" ["critical"]="" )
function parse_alert_array() {
    local arr="$1"
    local which_arr="$2"
    OLDIFS=$IFS; IFS=';' read -r -a vals <<< "${arr}"; IFS=$OLDIFS
    for i in "${vals[@]}"; do
        if [[ "${i#*:}" -eq "1" ]]; then
            which_arr["warning"]+="${i%%:*},"
            is_warning=1
        elif [[ "${i#*:}" -eq "2" ]]; then
            which_arr["critical"]+="${i%%:*},"
            is_critical=1
        else
            which_arr["ok"]+="${i%%:*},"
        fi
    done
}

declare -A boot_arr ping_arr ssh_arr delete_arr
parse_alert_array ${alert_array['boot']} $boot_arr
parse_alert_array ${alert_array['ping']} $ping_arr
parse_alert_array ${alert_array['ssh']} $ssh_arr
parse_alert_array ${alert_array['delete']} $delete_arr
END

declare -A boot_arr ping_arr ssh_arr delete_arr
is_critical=0
is_warning=0

# Parse boot alerts
OLDIFS=$IFS; IFS=';' read -r -a bootvals <<< "${alert_array['boot']}"; IFS=$OLDIFS
for i in "${bootvals[@]}"; do
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

# Parse ping alerts
OLDIFS=$IFS; IFS=';' read -r -a pingvals <<< "${alert_array['ping']}"; IFS=$OLDIFS
for i in "${pingvals[@]}"; do
    if [[ "${i#*:}" -eq "1" ]]; then
        ping_arr["warning"]+="${i%%:*},"
        is_warning=1
    elif [[ "${i#*:}" -eq "2" ]]; then
        ping_arr["critical"]+="${i%%:*},"
        is_critical=1
    else
        ping_arr["ok"]+="${i%%:*},"
    fi
done

# Parse ssh alerts
OLDIFS=$IFS; IFS=';' read -r -a sshvals <<< "${alert_array['ssh']}"; IFS=$OLDIFS
for i in "${sshvals[@]}"; do
    if [[ "${i#*:}" -eq "1" ]]; then
        ssh_arr["warning"]+="${i%%:*},"
        is_warning=1
    elif [[ "${i#*:}" -eq "2" ]]; then
        ssh_arr["critical"]+="${i%%:*},"
        is_critical=1
    else
        ssh_arr["ok"]+="${i%%:*},"
    fi
done

# Parse delete alerts
OLDIFS=$IFS; IFS=';' read -r -a deletevals <<< "${alert_array['delete']}"; IFS=$OLDIFS
for i in "${deletevals[@]}"; do
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
OK: {"boot": "${boot_arr['ok']%,}", "ping": "${ping_arr['ok']%,}", "ssh": "${ssh_arr['ok']%,}", "delete": "${delete_arr['ok']%,}"}
WARNING: {"boot": "${boot_arr['warning']%,}", "ping": "${ping_arr['warning']%,}", "ssh": "${ssh_arr['warning']%,}", "delete": "${delete_arr['warning']%,}"}
CRITICAL: {"boot": "${boot_arr['critical']%,}", "ping": "${ping_arr['critical']%,}", "ssh": "${ssh_arr['critical']%,}", "delete": "${delete_arr['critical']%,}"}
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
