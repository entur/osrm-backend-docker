#!/bin/bash
DATA_PATH=${DATA_PATH:="osrm-data"}
set -e

_sig() {
  kill -TERM $child 2>/dev/null
}

if [ "$1" = 'osrm' ]; then
  trap _sig SIGKILL SIGTERM SIGHUP SIGINT EXIT

  if [ ! -f /opt/$2.lua ]; then
    echo "You need to give a valid profile name as argument. Invalid: $2"
    echo "You can choose from the following:"
    ls /opt/ | grep lua | cut -d. -f 1
    exit 1
  fi

  ln -s /opt/$2.lua profile.lua

  if [ ! -f $DATA_PATH/$2.osrm ]; then
    if [ ! -f "$3" ]; then
      echo "You need to give a valid path to a osm protobuf data file"
      exit 1
    fi
    osrm-extract -p profile.lua $3
    osrm-contract $DATA_PATH/$2.osrm
  fi

  osrm-routed $DATA_PATH/$2.osrm --max-table-size 8000 &
  child=$!
  wait "$child"
else
  exec "$@"
fi
