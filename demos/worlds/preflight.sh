#!/bin/sh
# Preflight: score generated agent plans under alternate worlds, then refuse
# the live policy until Net is granted. Run from the repo root:
#   sh demos/worlds/preflight.sh
set -u
JACQUARD="${JACQUARD:-dune exec jac --}"
here="$(dirname "$0")"

echo "== rows: dreams need eval; the live policy needs net =="
$JACQUARD check "$here/preflight.jac" --print-sigs

echo "== without grants the pure prefix runs; the first posterior refuses =="
$JACQUARD run "$here/preflight.jac" 2>&1
echo "exit code: $?"

echo "== with eval: posteriors and diffs; live policy still refuses without net =="
$JACQUARD run "$here/preflight.jac" --allow eval 2>&1
echo "exit code: $?"
