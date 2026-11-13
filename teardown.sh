#!/usr/bin/env bash
# Removes everything the demo created: all five containers, the network, and
# the Docker volumes holding each box's Atsign keys. The platform keeps its
# state inside its container, so that goes too. Nothing is left on your disk.
#
#   ./teardown.sh            keep the images (next ./demo.sh works offline)
#   ./teardown.sh --images   also delete the images
. "$(dirname "$0")/scripts/lib.sh"

rmi=""
[ "${1:-}" = --images ] && rmi="--rmi all"
heading "Teardown"
# shellcheck disable=SC2086  # $rmi is empty or two words
dc down --volumes --remove-orphans --timeout 5 $rmi

left=$(docker ps -aq --filter label=com.docker.compose.project=noports-demo)
vols=$(docker volume ls -q --filter label=com.docker.compose.project=noports-demo)
if [ -z "$left$vols" ]; then
  say "Removed: containers, network, and the key volumes (client-keys, device-keys, relay-keys)."
else
  say "${RED}Some things were not removed:${RESET} $left $vols"; exit 1
fi
