#!/bin/sh
# M1 milestone demo (plan phase 2 gate). Run from the repo root:
#   sh demos/m1.sh
# Uses `dune exec jacquard --` unless JACQUARD is set to an installed binary.
set -u
JACQUARD="${JACQUARD:-dune exec jacquard --}"
here="$(dirname "$0")"

echo "== factorial =="
$JACQUARD run "$here/m1-fact.jqd"

echo "== multi-shot choose =="
$JACQUARD run "$here/m1-choose.jqd"

echo "== gated eval, WITHOUT the grant (expected: E0814 capability refusal, exit 3) =="
$JACQUARD run "$here/m1-gated.jqd"
echo "exit code: $?"

echo "== gated eval, WITH --allow eval =="
$JACQUARD run "$here/m1-gated.jqd" --allow eval
