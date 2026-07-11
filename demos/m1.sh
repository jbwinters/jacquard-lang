#!/bin/sh
# M1 milestone demo (plan phase 2 gate). Run from the repo root:
#   sh demos/m1.sh
# Uses the built `jac` alias unless JACQUARD is set to an installed binary.
set -u
JACQUARD="${JACQUARD:-dune exec jac --}"
here="$(dirname "$0")"

echo "== factorial =="
$JACQUARD run "$here/m1-fact.jac"

echo "== multi-shot choose =="
$JACQUARD run "$here/m1-choose.jac"

echo "== gated eval, WITHOUT the grant (expected: E0814 capability refusal, exit 3) =="
$JACQUARD run "$here/m1-gated.jac"
echo "exit code: $?"

echo "== gated eval, WITH --allow eval =="
$JACQUARD run "$here/m1-gated.jac" --allow eval
