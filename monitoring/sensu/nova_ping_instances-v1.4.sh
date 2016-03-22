#!/bin/bash

################################################################################
# Sensu plugin to check if all instances are pingable                          #
################################################################################

ALERT_NAME="CheckNovaPing"
PROGNAME=$(`which basename` $0)
VERSION="Version 1.4"
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
function get_instance_array() {
    fields="name,OS-EXT-SRV-ATTR:hypervisor_hostname,OS-EXT-STS:vm_state,"
    fields+="status,networks,security_groups"
    instance_array=($(${NOVA} list --all-tenants --fields ${fields} |\
        awk -W posix -F'|' '$2 ~ /[[:alnum:]-]{36}/{
          nets=match($7, /, 10\.*/);tendot=substr($7,nets+2);
          secgrp=match($8,/default/);gsub(" |\t","");
          gsub(/(.example.com|.example.local)/,"",$4);
          vm_state=tolower($5);status=tolower($6);
          if(tendot ~ /10\./ && secgrp>0 && \
          vm_state=="active" && status=="active"){
          printf "%s;%s;%s;%s\n", $2,$3,$4,tendot}}'))

    if [[ ${#instance_array[@]} -eq 0 ]]; then
        echo "${ALERT_NAME} CRITICAL: Unable to communicate with nova!"
        exit $STATE_CRITICAL
    fi

    echo ${instance_array[@]}
}

instance_array=($(get_instance_array))

declare -A nodes
critical=0
warning=0
for instance_data in ${instance_array[@]}; do

    uuid=$(echo ${instance_data} | cut -d';' -f1)
    name=$(echo ${instance_data} | cut -d';' -f2)
    hypervisor=$(echo ${instance_data} | cut -d';' -f3)
    public_ip=$(echo ${instance_data} | cut -d';' -f4)

    packet_loss=$(ping_ip ${public_ip})

    re='^[0-9]+$' # expecting packet_loss to be an integer
    if ! [[ ${packet_loss} =~ $re ]] ; then
         echo "${ALERT_NAME} UNKOWN: Unable to run check"
         exit $STATE_UNKNOWN
    fi

    if [[ $packet_loss -ge ${CRITICAL_PACKET_LOSS} ]]; then
        print_val "CRITICAL: {${hypervisor}, ${name}, ${uuid}, ${public_ip}, ${packet_loss}%}"
        json="{\"vm_name\": \"${name}\", \"ip\": \"${public_ip}\", \"packet_loss\": \"${packet_loss}\"},"
        nodes["${hypervisor}"]+=$json
        critical=1
    elif [[ ${packet_loss} -gt ${WARNING_PACKET_LOSS} && \
            ${packet_loss} -lt ${CRITICAL_PACKET_LOSS} ]]; then
        print_val "WARNING: {${hypervisor}, ${name}, ${uuid}, ${public_ip}, ${packet_loss}%}"
        json="{\"vm_name\": \"${name}\", \"ip\": \"${public_ip}\", \"packet_loss\": \"${packet_loss}\"},"
        nodes["${hypervisor}"]+=$json
        warning=1
    else
        print_val "OK: {${hypervisor}, ${name}, ${uuid}, ${public_ip}, ${packet_loss}%}"
    fi

done

print_val "-----"

# Create JSON structure
output="{"
for key in ${!nodes[@]}; do
    output+="\"$key\":["
    for node in ${nodes[$key]%,}; do
        output+=$node
    done
    output+="],"
done
output=${output%,}
output+="}"

# Exit status with message
#data=re.sub(r"node-[0-9]+)", ''<br>\\1</br>'', raw);\
read -r vals <<< "${output}"
if [[ ${critical} -gt 0 ]]; then
    python -c 'import sys; import simplejson as json; \
               data=json.dumps(json.loads(sys.stdin.read()),sort_keys=True,indent=4);\
               print "'${ALERT_NAME}' CRITICAL: %s" % (data)' <<< "${vals}"
               #data.replace("],","],<br/>"))' <<< "${vals}"
    exit $STATE_CRITICAL
elif [[ ${critical} -eq 0 && ${warning} -gt 0 ]]; then
    python -c 'import sys; import simplejson as json; \
               data=json.dumps(json.loads(sys.stdin.read()),sort_keys=True,indent=4);\
               print "'${ALERT_NAME}' WARNING: %s" % (data)' <<< "${vals}"
               #data.replace("],","],<br/>"))' <<< "${vals}"
    exit $STATE_WARNING
else
    msg="${ALERT_NAME} OK: Able to ping all ${#instance_array[@]} instances "
    msg+="with 0% packet loss"
    echo $msg
    exit $STATE_OK
fi
