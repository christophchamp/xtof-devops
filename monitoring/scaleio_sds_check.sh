#!/bin/bash

################################################################################
# Nagios plugin to monitor ScaleIO SDS operations                              #
################################################################################
source /etc/sensu/plugins/scaleio_lib.sh

ALERT_NAME="CheckScaleioSDS"
VERSION="Version 1.0"
AUTHOR="Christoph Champ <christoph.champ@gmail.com>"

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
   echo "$AUTHOR\n\nCheck ScaleIO operation\n"
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

# check the SDS's

find_primary_mdm

IFS="
"
raw=$(ssh -q $PRIMARY_MDM $SCLI --query_all_sds | tail -n +4)

for sds in $raw; do
  sds_state=$(echo $sds | awk '{printf "%s %s", $7, $8}')
  node=$(echo $sds | awk '{printf "%s", $5}')
  print_val "$node SDS State: $sds_state"
 
  if [[ $sds_state != "Connected, Joined" ]]; then
     echo "${ALERT_NAME} CRITICAL: bad SDS state: $sds_state"
     exit $STATE_CRITICAL
  fi
done

IFS="
"

raw=$(ssh -q $PRIMARY_MDM $SCLI --query_all)

## first look for critical items, we'll do warning later...
##
## we will flag failed capacity and degraded-failed-capacity as CRIT
##
##
## 0 Bytes failed capacity
## 0 Bytes degraded-failed capacity
## 0 Bytes decreased capacity

failed=$(echo "$raw" | grep -E "failed capacity|degraded-failed capacity|decreased capacity")
msg=""
print_val "Looking for failures..." 

for f in $failed; do
  val=$(echo "$f" | awk '{print $1}')
  print_val "$f"

  if [[ "$val" != "0" ]]; then
    msg+="$f "
  fi
done

if [ -n "$msg" ]; then
  echo "${ALERT_NAME} CRITICAL: $msg"
  exit $STATE_CRITICAL
fi

## we will warn on any of the following being non-0
##	0 Bytes degraded-healthy capacity
##	0 Bytes unreachable-unused capacity
##	0 Bytes rebalance capacity
##	0 Bytes fwd-rebuild capacity
##	0 Bytes bck-rebuild capacity

print_val "looking for warnings..."

warn=$(echo "$raw" | grep -E "degraded-healthy capacity|unreachable-unused capacity|\
rebalance capacity|fwd-rebuild capacity|bck-rebuild capacity")

for w in $warn; do
  print_val "$w"

  val=$(echo "$w" | awk '{print $1}')
  if [[ $val != "0" ]]; then
    msg+="$w "
  fi
done

if [ -n "$msg" ]; then
  echo "${ALERT_NAME} WARNING: $msg"
  exit $STATE_WARNING
fi

#########################################################################

echo "${ALERT_NAME} OK"
exit $STATE_OK
