#!/bin/bash
# AUTHOR: Christoph Champ <christoph.champ@gmail.com>
# DESCRIPTION: Gets a list of OpenStack availability zones
# Requires jq 1.5+
JQ=$(which jq)

OS_AUTH_URL=http://1.2.3.4:5000/v2.0/
OS_TENANT_NAME=admin
OS_USERNAME=admin
OS_PASSWORD=admin

INFO=$(curl -sXPOST "${OS_AUTH_URL}/tokens" \
        -H "Content-Type: application/json" \
        -d "{\"auth\":{\"tenantName\":\"$OS_TENANT_NAME\",\"passwordCredentials\":\
        {\"username\":\"$OS_USERNAME\",\"password\":\"$OS_PASSWORD\"}}}" | \
        ${JQ} -crM '[.access.token.id + "," + (.access.serviceCatalog[] | select(.name == "nova") | .endpoints[].publicURL)] | .[]')

TOKEN=${INFO%%,*}
NOVA_ENDPOINT=${INFO#*,}

IGNORE_ZONES="internal|nova"

raw=$(curl -s -H "X-Auth-Token: ${TOKEN}" "${NOVA_ENDPOINT}/os-availability-zone/detail" | \
    ${JQ} -crM '[.availabilityZoneInfo[].zoneName] | .[]' | \
    grep -vE "(${IGNORE_ZONES})" | tr '\n' ',')

IFS=',' read -r -a zones <<< "${raw%,}"

for zone in "${zones[@]}"; do
    raw=($(curl -s -H "X-Auth-Token: ${TOKEN}" "${NOVA_ENDPOINT}/os-availability-zone/detail" | \
        ${JQ} --arg zone "$zone" '[.availabilityZoneInfo[] | select(.zoneName==$zone) | .hosts|keys] | .[]' | \
        tr -d '[]",' | sed '/^$/d' | tr '\n' ',' | tr -d ' '))

    IFS=',' read -r -a nodes <<< "${raw%,}"
    for node in "${nodes[@]}"; do
        echo "node: $zone $node"
    done
done
