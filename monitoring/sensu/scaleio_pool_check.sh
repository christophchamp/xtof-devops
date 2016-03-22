#!/bin/bash

################################################################################
# Nagios plugin to monitor ScaleIO operation                                   #
################################################################################
source /etc/sensu/plugins/scaleio_lib.sh

ALERT_NAME="CheckScaleioPool"
PROGNAME=$(basename "$0")
VERSION="Version 1.0"
AUTHOR="Christoph Champ <christoph.champ@gmail.com>"

NUM_POOLS=0

# Helper functions #############################################################

function print_revision {
   # Print the revision number
   echo "$PROGNAME - $VERSION"
}

function print_usage {
   # Print a short usage statement
   echo "Usage: $PROGNAME [-v] -p <pool_name> <warn threshold (GB)> <crit threshold (GB)> ...."
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

-p POOL_NAME W_THRESH C_THRESH 
   Exit with WARNING status if less than W_THRESH GB of storage are free in storage pool POOL_NAME
   Exit with CRITICAL status if less than C_THRESH GB of storage are free in storage pool POOL_NAME

-v
   Verbose output
__EOT
}

is_flag() {
    # Check if $1 is a flag; e.g. "-h"
    [[ "$1" = -* ]] && return 0 || return 1
}

# Main #########################################################################

# Verbosity level
verbosity=0
declare -A cthreshholds
declare -A wthreshholds

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
       -p | --pool)
           if [[ -z "$2" || -z "$3" || -z "$4" ]] || is_flag "$2" || is_flag "$3" || is_flag "$4"; then
               # Thresholds not provided
               echo "$PROGNAME: Option '$1' requires three arguments!"
               print_usage
               exit $STATE_UNKNOWN
           elif [[ "$3" = +([0-9]) && "$4" = +([0-9]) ]]; then
               # Thresholds are numbers (GB)
               wthreshholds[$2]=$3
               cthreshholds[$2]=$4
               shift 4
               NUM_POOLS+=1
           else
               # Threshold is neither a number nor a percentage
               echo "$PROGNAME: Thresholds must be integer"
               print_usage
               exit $STATE_UNKNOWN
           fi
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

if [[ $NUM_POOLS -eq 0 ]]; then
    echo "${ALERT_NAME} UNKNOWN: At least one storage pool must be declared..."
    print_usage
    exit $STATE_UNKNOWN
fi

for K in "${!wthreshholds[@]}"; do
    wthresh=${wthreshholds[$K]}
    cthresh=${cthreshholds[$K]}

    if [[ -z "$wthresh" || -z "$cthresh" || "$cthresh" -gt "$wthresh" ]]; then
        # One or both thresholds were not specified
        echo "$PROGNAME: $pool Thresholds not set correctly. Got wthresh $wthresh, cthresh $cthresh"
        print_usage
        exit $STATE_UNKNOWN
    fi
done

############# The good stuff  ############################################

declare -A tvols
declare -A tavail

function parse_storage_pools() {
    local raw=$(ssh -q $PRIMARY_MDM $SCLI --query_all)
    local spools=$(IFS=$'\n'; awk '/^Storage Pool/{
                        if($3 ~ /default/){} # skip default storage pool
                        else{gsub(/\(|\)/,"");;if($13=="GB"){
                        printf "%s;%s|%s\n", $3,$7,$12}}}' <<< "${raw}")

    for pool in $spools; do
        local pool_name=${pool%%;*}
        local volspace=${pool#*;}

        tvols[$pool_name]=${volspace%%|*}
        tavail[$pool_name]=${volspace#*|}
    done

    echo $tvols
    echo $tavail
}

find_primary_mdm
parse_storage_pools

for K in "${!wthreshholds[@]}"; do
    wthresh=${wthreshholds[$K]}
    cthresh=${cthreshholds[$K]}
    av=${tavail[$K]}

    if [[ "$av" -lt "$cthresh" ]]; then
        echo "${ALERT_NAME} CRITICAL: pool: $K below threshold limit with $av GB remaining"
        exit $STATE_CRITICAL
    fi

    if [[ "$av" -lt "$wthresh" ]]; then
        echo "${ALERT_NAME} WARNING: pool: $K below threshold limit with $av GB remaining"
        exit $STATE_WARNING
    fi
done

for K in "${!wthreshholds[@]}"; do
    nvol=${tvols[$K]}
    avail=${tavail[$K]}
    msg+="Pool $K $nvol vols $avail GB available; "
done

echo "${ALERT_NAME} OK: ${msg%; }"
print_val $msg
exit $STATE_OK
