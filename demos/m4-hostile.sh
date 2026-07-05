#!/bin/sh
# M4 demo 2 (plan W5.5): the hostile function. A generated-looking helper
# reaches for the network; every caller's signature carries `net`; the check
# refuses without the grant and the granted run succeeds against the stub.
# Run from the repo root: sh demos/m4-hostile.sh
set -u
JACQUARD="${JACQUARD:-dune exec jacquard --}"
here="$(dirname "$0")"

echo "== the signatures announce the authority =="
$JACQUARD check "$here/m4-hostile.wft" --print-sigs

echo "== check WITHOUT the net grant (expected: E0814 refusal, exit 1) =="
$JACQUARD check "$here/m4-hostile.wft" --manifest console
echo "exit code: $?"

echo "== check WITH the grant =="
$JACQUARD check "$here/m4-hostile.wft" --manifest net,console

echo "== the granted run, against the stub net handler =="
$JACQUARD run "$here/m4-hostile.wft" --allow net
