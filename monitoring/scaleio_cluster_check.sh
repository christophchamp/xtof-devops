#!/bin/bash

################################################################################
# Sensu plugin to monitor ScaleIO cluster operation                            #
################################################################################

source /etc/sensu/plugins/scaleio_lib.sh

ALERT_NAME="CheckScaleioCluster"
VERSION="Version 1.0"
AUTHOR="Christoph Champ <christoph.champ@gmail.com>"

if [[ "$(hostname)" == "fuel" ]]; then
    echo "${ALERT_NAME} OK: Skipping check on fuel-lab"
    exit $STATE_OK
fi

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
   echo "$AUTHOR\n\nCheck ScaleIO cluster operation\n"
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

############# The good stuff  ############################################

# check cluster state

find_primary_mdm

raw=$(ssh -q $PRIMARY_MDM $SCLI --query_cluster 2>&1)
echo $raw | grep "Mode:" >/dev/null
status=${PIPESTATUS[1]}

if [[ status -eq "1" ]]; then 
   echo "${ALERT_NAME} UNKNOWN: Unable to obtain cluster status: $raw"
   exit $STATE_UNKNOWN 
fi

print_val "$raw"

mode_state=$(awk '/Mode/{gsub(",","");printf "%s;%s",$2,$5}' <<< "${raw}")

if [[ ${mode_state%%;*} != "Cluster" ]]; then
    echo "CRITICAL: Bad cluster mode: ${mode_state%%;*}"
    exit $STATE_CRITICAL
fi

if [[ ${mode_state#*;} != "Normal" ]]; then
    echo "CRITICAL: Bad cluster state: ${mode_state#*;}"
    exit $STATE_CRITICAL
fi

#########################################################################

echo "${ALERT_NAME} OK: ${mode_state%%;*} ${mode_state#*;}"
exit $STATE_OK
