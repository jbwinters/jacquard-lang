#!/bin/sh
# Agent dream mode: run one policy under scripted and probabilistic Net handlers.
# Run from the repo root:
#   sh demos/agent-dream.sh
set -u
JACQUARD="${JACQUARD:-dune exec jacquard --}"
here="$(dirname "$0")"

echo "== policy authority =="
$JACQUARD check "$here/agent-dream.jqd" --print-sigs | grep '^support-policy'

echo "== scripted worlds and probabilistic dream =="
$JACQUARD run "$here/agent-dream.jqd"
