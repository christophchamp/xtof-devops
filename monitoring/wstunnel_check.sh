#!/bin/bash

ALERT_NAME="CheckVscaleWStunnel"

# Exit codes
STATE_OK=0
STATE_WARNING=1
STATE_CRITICAL=2
STATE_UNKNOWN=3
STATE_DEPENDENT=4

usage() { echo "Usage: $0 [-t <token>]" 1>&2; exit 1; }

while getopts ":t:" opt; do
  case ${opt} in
    t)
      TOKEN=${OPTARG}
      ;;
    \?)
      echo "Invalid option: -${OPTARG}" >&2
      ;;
  esac
done

if [ -z $TOKEN ]; then
  usage
fi

if [ ! -f /usr/local/bin/wstunnel ]; then
  echo "${ALERT_NAME} OK: No wstunnel on this controller"
  exit $STATE_OK
fi

RETURN_CODE=$(curl -m 2 -fs -w "%{http_code}" https://wstunnel.example.com/_token/${TOKEN}/)

if [ "${RETURN_CODE}" != "401" ]; then
  echo "${ALERT_NAME} CRITICAL: Received HTTP return code ${RETURN_CODE}, not 401 as expected."
  exit $STATE_CRITICAL
fi

echo "${ALERT_NAME} OK: Received expected HTTP return code: ${RETURN_CODE}"
exit $STATE_OK
