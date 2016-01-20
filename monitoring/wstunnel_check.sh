#!/bin/bash

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
  echo 'OK: No wstunnel on this controller'
  exit 0
fi

RETURN_CODE=$(curl -m 2 -fs -w "%{http_code}" https://wstunnel10-1.rightscale.com/_token/${TOKEN}/)

if [ "${RETURN_CODE}" != "401" ]; then
  echo "Failed: Got HTTP return code ${RETURN_CODE}, not 401 as expected."
  exit 2
fi
exit 0
