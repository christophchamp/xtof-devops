PROGNAME=`/bin/basename $0`

SCALEIO_USER=admin
SCALEIO_PW=<REDACTED>
SCLI=/bin/scli

# Exit codes
STATE_OK=0
STATE_WARNING=1
STATE_CRITICAL=2
STATE_UNKNOWN=3

PRIMARY_MDM=""
verbosity=0

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

function find_primary_mdm {
  controller_node_ids=$(fuel node | grep controller)

  for id in $controller_node_ids; do
    node_name=node-$id

    raw=$(ssh -q $node_name $SCLI --login --username $SCALEIO_USER --password $SCALEIO_PW 2>&1)
    echo $raw | grep "Logged in">/dev/null
    status=${PIPESTATUS[1]}

    if [[ $status -eq "0" ]]; then
       print_val "Found Primary MDM: $node_name"
       PRIMARY_MDM=$node_name
       break
    fi
  done

  if [[ -z $PRIMARY_MDM ]]; then
    echo "Unable to find primary MDM"
    exit $STATE_UNKNOWN
  fi
}
