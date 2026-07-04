#!/bin/sh
# Agent dream mode: run one policy under scripted and probabilistic Net handlers.
# Run from the repo root:
#   sh demos/agent-dream.sh
set -u
WEFT="${WEFT:-dune exec weft --}"
here="$(dirname "$0")"

echo "== policy authority =="
$WEFT check "$here/agent-dream.wft" --print-sigs | grep '^support-policy'

echo "== scripted worlds and probabilistic dream =="
$WEFT run "$here/agent-dream.wft"
