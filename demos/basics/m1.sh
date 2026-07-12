#!/bin/sh
# M1 milestone demo (plan phase 2 gate).
set -u
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
JACQUARD_DEMO_ROOT=$(CDPATH= cd -- "$here/.." && pwd)
. "$JACQUARD_DEMO_ROOT/lib/demo-env.sh"

echo "== factorial =="
jacquard_demo run "$here/m1-fact.jac"

echo "== multi-shot choose =="
jacquard_demo run "$here/m1-choose.jac"

echo "== gated eval, WITHOUT the grant (expected: E0814 capability refusal, exit 3) =="
jacquard_demo run "$here/m1-gated.jac"
echo "exit code: $?"

echo "== gated eval, WITH --allow eval =="
jacquard_demo run "$here/m1-gated.jac" --allow eval
