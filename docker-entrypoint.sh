#!/bin/bash
DATA_PATH=${DATA_PATH:="/data"}
set -e

_sig() {
  kill -TERM $child 2>/dev/null
}

if [ "$1" = 'osrm' ]; then
  trap _sig SIGKILL SIGTERM SIGHUP SIGINT EXIT

  echo "Content of $DATA_PATH"
  ls $DATA_PATH

  echo "Content of /opt"
  ls /opt/

    echo "Content of /opt/lib"
    ls /opt/lib

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
    echo "osrm-extract finished"
    ls $DATA_PATH
    osrm-contract $DATA_PATH/data.osrm
  fi

  osrm-routed $DATA_PATH/data.osrm --max-table-size 8000 --algorithm ch &
  child=$!
  wait "$child"
else
  exec "$@"
fi
