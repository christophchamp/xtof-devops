#!/bin/bash
#
# AUTHOR: Christoph Champ
# DESCRIPTION: This script checks which node (compute or midonet-gw) HAproxy
#+ is running on. It then gets a list of LB VIPs associated with the running
#+ haproxy process on that node.

SSH_PARAMS="-q -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null"

controller=$(fuel node|awk '/controller/{print $1;exit}')
raw=$(ssh ${SSH_PARAMS} node-${controller} "neutron lb-vip-list -F id -F name -F address")
OLDIFS=$IFS; IFS=$'\n' read -d '' -r -a raw_array <<< "${raw}"; IFS=$OLDIFS
complete_vip_array=($(for vip in "${raw_array[@]}"; do \
    echo $vip|awk -W posix -F'|' '$2 ~ /[[:alnum:]-]{36}/{
    gsub(" |\t","");printf "%s;%s;%s\n",$3,$4,$2}'; done))

for node in $(fuel nodes | awk '/(compute|midonet)/{print $1}'); do

    raw=$(ssh ${SSH_PARAMS} node-${node} "ps -o cmd -e | grep [h]aproxy | grep midolman | cut -d' ' -f3")

    if [[ ${#raw} -gt 0 ]]; then
        echo "HAproxy running on node-${node}"
        OLDIFS=$IFS; IFS=$'\n' read -d '' -r -a confs <<< "${raw}"; IFS=$OLDIFS
        for conf in "${confs[@]}"; do
            vip_id=$(ssh ${SSH_PARAMS} node-${node} "awk '/^frontend/{print $2}' $conf" | cut -d' ' -f2)
            for vip_match in "${complete_vip_array[@]}"; do
                vip_name=$(echo ${vip_match} | cut -d';' -f1)
                vip_address=$(echo ${vip_match} | cut -d';' -f2)
                vip_uuid=$(echo ${vip_match} | cut -d';' -f3)
                if [[ ${vip_id} == ${vip_uuid} ]]; then
                    matches+=($(echo -e "node-${node} ${vip_name} ${vip_address} ${vip_uuid};"))
                fi
            done
        done
    fi
done

echo "--------------------------"
(printf "NODE LB-VIP ADDRESS UUID\n"; echo "${matches[@]}"|tr ';' '\n'|sort) | column -t
