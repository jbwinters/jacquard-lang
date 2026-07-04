#!/bin/sh
# M1 milestone demo (plan phase 2 gate). Run from the repo root:
#   sh demos/m1.sh
# Uses `dune exec weft --` unless WEFT is set to an installed binary.
set -u
WEFT="${WEFT:-dune exec weft --}"
here="$(dirname "$0")"

echo "== factorial =="
$WEFT run "$here/m1-fact.wft"

echo "== multi-shot choose =="
$WEFT run "$here/m1-choose.wft"

echo "== gated eval, WITHOUT the grant (expected: unhandled effect, exit 3) =="
$WEFT run "$here/m1-gated.wft"
echo "exit code: $?"

echo "== gated eval, WITH --allow eval =="
$WEFT run "$here/m1-gated.wft" --allow eval
