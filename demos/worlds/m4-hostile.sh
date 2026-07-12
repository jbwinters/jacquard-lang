#!/bin/sh
# M4 demo 2 (plan W5.5): the hostile function. A generated-looking helper
# reaches for the network; every caller's signature carries `net`; the check
# refuses without the grant and the granted run succeeds against the stub.
set -u
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
JACQUARD_DEMO_ROOT=$(CDPATH= cd -- "$here/.." && pwd)
. "$JACQUARD_DEMO_ROOT/lib/demo-env.sh"

echo "== the signatures announce the authority =="
jacquard_demo check "$here/m4-hostile.jqd" --print-sigs

echo "== check WITHOUT the net grant (expected: E0814 refusal, exit 1) =="
jacquard_demo check "$here/m4-hostile.jqd" --manifest console
echo "exit code: $?"

echo "== check WITH the grant =="
jacquard_demo check "$here/m4-hostile.jqd" --manifest net,console

echo "== the granted run, against the stub net handler =="
jacquard_demo run "$here/m4-hostile.jqd" --allow net
