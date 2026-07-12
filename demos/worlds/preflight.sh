#!/bin/sh
# Preflight: score generated agent plans under alternate worlds, then refuse
# the live policy until Net is granted.
set -u
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
JACQUARD_DEMO_ROOT=$(CDPATH= cd -- "$here/.." && pwd)
. "$JACQUARD_DEMO_ROOT/lib/demo-env.sh"

echo "== rows: dreams need eval; the live policy needs net =="
jacquard_demo check "$here/preflight.jac" --print-sigs

echo "== without grants the pure prefix runs; the first posterior refuses =="
jacquard_demo run "$here/preflight.jac" 2>&1
echo "exit code: $?"

echo "== with eval: posteriors and diffs; live policy still refuses without net =="
jacquard_demo run "$here/preflight.jac" --allow eval 2>&1
echo "exit code: $?"
