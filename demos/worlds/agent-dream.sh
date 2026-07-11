#!/bin/sh
# Agent dream mode: run one policy under scripted and probabilistic Net handlers.
# Run from the repo root:
#   sh demos/worlds/agent-dream.sh
set -u
JACQUARD="${JACQUARD:-dune exec jac --}"
here="$(dirname "$0")"

echo "== policy authority =="
$JACQUARD check "$here/agent-dream.jac" --print-sigs | grep '^support-policy'

echo "== scripted worlds and probabilistic dream =="
$JACQUARD run "$here/agent-dream.jac"
