#!/bin/bash

################################################################################
# Sensu plugin to check if all instances are pingable                          #
################################################################################

ALERT_NAME="CheckNovaPing"
PROGNAME=$(`which basename` $0)
VERSION="Version 1.2"
AUTHOR="Christoph Champ <christoph.champ@gmail.com>"

source /etc/sensu/plugins/openrc

# Verbosity level
verbosity=0

# Exit codes
STATE_OK=0
STATE_WARNING=1
STATE_CRITICAL=2
STATE_UNKNOWN=3
STATE_DEPENDENT=4

# percent packet loss allowed before we trigger alerts
WARNING_PACKET_LOSS=0
CRITICAL_PACKET_LOSS=100

PING=$(which ping)
GREP=$(which grep)
NOVA=$(which nova)

# Helper functions #############################################################

function print_revision {
   # Print the revision number
   echo "$PROGNAME - $VERSION"
}

function print_usage {
   # Print a short usage statement
   echo "Usage: $PROGNAME [-v] [-V]"
}

function print_help {
   # Print detailed help information
   print_revision
   echo -e "$AUTHOR\n\nCheck ${ALERT_NAME} cluster operation\n"
   print_usage

   /bin/cat <<__EOT

Options:
-h
   Print detailed help screen
-V
   Print version information
-v
   Verbose output
__EOT
}

function print_val {
  if [[ $verbosity -ge 1 ]]; then
    echo $1
  fi
}

function ping_ip {
    local ip="$1"
    echo $(${PING} -c 3 -W 2 -q ${ip} | ${GREP} -oP '\d+(?=% packet loss)')
}

# Main #########################################################################

# Parse command line options
while [ "$1" ]; do
   case "$1" in
       -h | --help)
           print_help
           exit $STATE_OK
           ;;
       -V | --version)
           print_revision
           exit $STATE_OK
           ;;
       -v | --verbose)
           : $(( verbosity++ ))
           shift
           ;;
       -?)
           print_usage
           exit $STATE_OK
           ;;
       *)
           echo "$PROGNAME: Invalid option '$1'"
           print_usage
           exit $STATE_UNKNOWN
           ;;
   esac
done

#== Start of actual check =====================================================
fields="name,OS-EXT-SRV-ATTR:hypervisor_hostname,OS-EXT-STS:vm_state,status,"
fields+="networks,security_groups"
instance_array=($(nova list --all-tenants --fields ${fields} |\
    awk -W posix -F'|' '$2 ~ /[[:alnum:]-]{36}/{
      nets=match($7, /, 10\.*/);tendot=substr($7,nets+2);
      secgrp=match($8,/My-default/);gsub(" ","",$2);gsub(" ","",$3);
      gsub(" ","",$4);gsub(" ","",$5);gsub(" ","",$6);gsub(" ","",tendot);
      vm_state=tolower($5);status=tolower($6);
      if(tendot ~ /10\./ && secgrp>0 && vm_state=="active" && status=="active"){
      printf "%s;%s;%s;%s\n", $2,$3,$4,tendot}}'))

if [[ ${#instance_array[@]} -eq 0 ]]; then
    echo "${ALERT_NAME} CRITICAL: Unable to communicate with nova!"
    exit $STATE_CRITICAL
fi

declare -A alert_array
for instance_data in ${instance_array[@]}; do

    uuid=$(echo ${instance_data} | cut -d';' -f1)
    name=$(echo ${instance_data} | cut -d';' -f2)
    hypervisor=$(echo ${instance_data} |\
        awk -F';' '{gsub(/(.example.com|.example.local)/,"",$3);print $3}')
    public_ip=$(echo ${instance_data} | cut -d';' -f4)

    packet_loss=$(ping_ip ${public_ip})

    re='^[0-9]+$' # expecting packet_loss to be an integer
    if ! [[ ${packet_loss} =~ $re ]] ; then
         echo "${ALERT_NAME} UNKOWN: Unable to run check"
         exit $STATE_UNKNOWN
    fi

    if [[ $packet_loss -ge ${CRITICAL_PACKET_LOSS} ]]; then
        print_val "CRITICAL: {${hypervisor}::${name}(${uuid})::${public_ip}}"
        alert_array["critical"]+="{${hypervisor}::${name}(${uuid})::${public_ip}} "
    elif [[ ${packet_loss} -gt ${WARNING_PACKET_LOSS} && \
            ${packet_loss} -lt ${CRITICAL_PACKET_LOSS} ]]; then
        print_val "WARNING: {${hypervisor}::${name}(${uuid})::${public_ip}}"
        alert_array["warning"]+="{${hypervisor}::${name}(${uuid})::${public_ip}} "
    else
        print_val "OK: {${hypervisor}::${name}(${uuid})::${public_ip}}"
        alert_array["ok"]+="{${hypervisor}::${name}(${uuid})::${public_ip}} "
    fi
done

print_val "-----"

# Sort arrays (makes output easier to dissect)
critical=($(tr ' ' '\n' <<< "${alert_array['critical']}" | sort | tr '\n' ' '))
warning=($(tr ' ' '\n' <<< "${alert_array['warning']}" | sort | tr '\n' ' '))
okay=($(tr ' ' '\n' <<< "${alert_array['ok']}" | sort | tr '\n' ' '))

# Exit status with message
msg=""
if [[ ${#alert_array["critical"]} -gt 0 && \
      ${#alert_array["warning"]} -gt 0 ]]; then
    msg="${ALERT_NAME} CRITICAL: ${CRITICAL_PACKET_LOSS}% packet loss "
    msg+="whilst pinging the following ${#critical[@]} "
    msg+="instance(s): [${critical[@]}]; "
    msg+="WARNING: Some packet loss whilst pinging the following "
    msg+="${#warning[@]} instance(s): [${warning[@]}]"
    echo $msg
    exit $STATE_CRITICAL
elif [[ ${#alert_array["critical"]} -gt 0 && \
        ${#alert_array["warning"]} -eq 0 ]]; then
    msg="${ALERT_NAME} CRITICAL: ${CRITICAL_PACKET_LOSS}% packet loss "
    msg+="whilst pinging the following ${#critical[@]} "
    msg+="instance(s): [${critical[@]}]"
    echo $msg
    exit $STATE_CRITICAL
elif [[ ${#alert_array["warning"]} -gt 0 ]]; then
    msg="${ALERT_NAME} WARNING: Some packet loss whilst pinging the "
    msg+="following ${#warning[@]} instance(s): "
    msg+="[${warning[@]}]"
    echo $msg
    exit $STATE_WARNING
else
    msg="${ALERT_NAME} OK: Able to ping all ${#okay[@]} instances "
    msg+="with 0% packet loss"
    echo $msg
    exit $STATE_OK
fi
