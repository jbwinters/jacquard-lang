#!/bin/sh
# M3 milestone demo (plan W4.5): one model, two inference algorithms.
set -u
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
JACQUARD_DEMO_ROOT=$(CDPATH= cd -- "$here/.." && pwd)
. "$JACQUARD_DEMO_ROOT/lib/demo-env.sh"

echo "== exact posterior by multi-shot enumeration =="
jacquard_demo infer enumerate "$here/m3-two-coins.jac"

echo "== approximate posterior by likelihood weighting (seed 42, K = 100000) =="
jacquard_demo infer lw "$here/m3-two-coins.jac" --seed 42 --samples 100000

echo "== the model file is untouched between runs; only the handler changed =="
jacquard_demo hash "$here/m3-two-coins.jac" | head -n 1
