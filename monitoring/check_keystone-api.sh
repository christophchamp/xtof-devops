#!/bin/bash
#
# Keystone API monitoring script for Sensu
#
# Copyright © 2013 eNovance <licensing@enovance.com>
#
# Author: Emilien Macchi <emilien.macchi@enovance.com>
# Modified by: Christoph Champ <christoph.champ@gmail.com>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
# Requirement: curl
#

# #RED

ALERT_NAME="CheckKeystoneAPI"

STATE_OK=0
STATE_WARNING=1
STATE_CRITICAL=2
STATE_UNKNOWN=3
STATE_DEPENDENT=4

usage ()
{
    echo "Usage: $0 [OPTIONS]"
    echo " -h             Get help"
    echo " -H <Auth URL>  URL for obtaining an auth token"
    echo " -U <username>  Username to use to get an auth token"
    echo " -P <password>  Password to use to get an auth token"
    echo " -T <seconds>   Time, in seconds, to wait for a reply (integer value only)"
}

while getopts 'h:H:U:P:T:' OPTION
do
    case $OPTION in
        h)
            usage
            exit 0
            ;;
        H)
            export OS_AUTH_URL=$OPTARG
            ;;
        U)
            export OS_USERNAME=$OPTARG
            ;;
        P)
            export OS_PASSWORD=$OPTARG
            ;;
        T)
            export MAX_TIME=$OPTARG
            ;;
        *)
            usage
            exit 1
            ;;
    esac
done

if ! which curl >/dev/null 2>&1; then
    echo "${ALERT_NAME} UNKNOWN: curl is not installed."
    exit $STATE_UNKNOWN
fi

if [ ! -z "${MAX_TIME//[0-9]}" ]; then
    echo "${ALERT_NAME} UNKNOWN: '-T <seconds>' option value is not an integer"
    exit $STATE_UNKNOWN
fi

START=$(date +%s)
TOKEN=$(curl -d '{"auth":{"passwordCredentials":{"username":"'$OS_USERNAME'","password":"'$OS_PASSWORD'"}}}' \
             -H "Content-type: application/json" \
             ${OS_AUTH_URL}:5000/v2.0/tokens/ 2>&1 | \
             \grep token|awk '{print $8}'| \grep -o '".*"' | \
             sed -n 's/.*"\([^"]*\)".*/\1/p')
END=$(date +%s)

TIME=$((END-START))

if [ -z "$TOKEN" ]; then
    echo "${ALERT_NAME} CRITICAL: Unable to get a token"
    exit $STATE_CRITICAL
else
    if [ $TIME -gt $MAX_TIME ]; then
        echo "${ALERT_NAME} WARNING: It took too long to retrieve a token. Time taken: ${TIME} seconds."
        exit $STATE_WARNING
    else
        echo "${ALERT_NAME} OK: Retrieved a token. Keystone API is working."
        exit $STATE_OK
    fi
fi
