#!/bin/bash

################################################################################
# Sensu plugin to check Pacemaker cluster health                               #
################################################################################

ALERT_NAME="CheckPacemakerClusterHealth"
PROGNAME=$(`which basename` $0)
VERSION="Version 1.0"
AUTHOR="Christoph Champ <christoph.champ@gmail.com>"

# Verbosity level
verbosity=0

# Exit codes
STATE_OK=0
STATE_WARNING=1
STATE_CRITICAL=2
STATE_UNKNOWN=3
STATE_DEPENDENT=4

CRM_MON=$(which crm_mon)

# Helper functions #############################################################

function print_revision {
   # Print the revision number
   echo "$PROGNAME - $VERSION"
}

function print_val {
  if [[ $verbosity -ge 1 ]]; then
    echo "$1"
  fi
}

usage ()
{
    echo "Usage: ${PROGNAME} [OPTIONS]"
    echo " -h         Get help"
    echo " -V         Print version information"
    echo " -v         Verbose output"
}

# Parse command line options
while getopts 'hVv' OPTION
do
    case $OPTION in
        h)
            usage
            exit $STATE_OK
            ;;
        V)
            print_revision
            exit $STATE_OK
            ;;
        v)
            : $(( verbosity++ ))
            shift
            ;;
        *)
            echo "$PROGNAME: Invalid option '$1'"
            usage
            exit 1
            ;;
    esac
done

raw=$(${CRM_MON} -1n|awk '/^Node/,/^$/{if($1=="Node"){
    gsub("(.example.com:|.example.local:)","",$2);printf "%s:%s\n",$2,$3}}')

OLDIFS=$IFS; IFS=$'\n' read -d '' -r -a nodes <<< "${raw}"; IFS=$OLDIFS
alert_json="{\"failed_nodes\":["
failed_nodes=0
n=0
for node in "${nodes[@]}"; do
    if [[ ${node#*:} != "online" ]]; then
        failed_nodes=1
        alert_json+="\"${node%%:*}\","
        ((n++))
    fi
done
alert_json="${alert_json%,}],"
alert_msg="${n}/${#nodes[@]} nodes offline; "

raw=$(${CRM_MON} -1n|awk '/^Node/,/^$/{if($1!="Node" && $1 ~ /[a-z_-]/){
    printf "%s:%s\n",$1,$3}}')
OLDIFS=$IFS; IFS=$'\n' read -d '' -r -a resources <<< "${raw}"; IFS=$OLDIFS
regex="(Started|Master)"
alert_json+="\"failed_resources\":["
failed_resources=0
n=0
for resource in "${resources[@]}"; do
    if [[ ! ${resource#*:} =~ ${regex} ]]; then
        failed_resources=1
        alert_json+="\"${resource%%:*}\","
        ((n++))
    fi
done
alert_json="${alert_json%,}]}"
alert_msg+="${n}/${#resources[@]} resources failed"

read -r vals <<< "${alert_json}"
json=$(python -c 'import sys; import simplejson as json; \
    data=json.dumps(json.loads(sys.stdin.read()),sort_keys=True,indent=4);\
    print data' <<< "${vals}")

if [ ${failed_nodes} -gt 0 ] || [ ${failed_resources} -gt 0 ]; then
    echo "CRITICAL: ${alert_msg}: ${json}"
    exit $STATE_CRITICAL
else
    echo "OK: ${alert_msg}"
    print_val "${json}"
    exit $STATE_OK
fi
