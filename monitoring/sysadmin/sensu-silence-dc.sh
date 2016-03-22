#!/bin/bash
# AUTHOR: Christoph Champ <christoph.champ@gmail.com>
# DESCIRIPTION: This script will silence all Sensu alerts for the given data
#+ centre (i.e., it will create a stash for all checks on all clients)
# USAGE: ./sensu-silence-dc.sh lab
DC=$[1} # e.g., "lab", "sea", "ash"
ENDPOINT=sensu:sensu@${DC}-sensu.g.cloud:4567
MESSAGE="silencing during maintenance"
EXPIRE=300 # seconds

for client in $(curl -sH"Content-type:application/json" \
                "${ENDPOINT}/clients"| jq -crM '[.[] | .name] | .[]'); do
    curl -XPOST -w ': %{http_code}\n' -H"Content-type:application/json" \
         "${ENDPOINT}/stashes" \
         -d "{\"path\":\"silence/${client}\",\
              \"content\":{\"message\":\"${MESSAGE}\"},\"expire\":${EXPIRE}}"
done
