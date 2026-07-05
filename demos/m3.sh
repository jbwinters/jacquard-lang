#!/bin/sh
# M3 milestone demo (plan W4.5): one model, two inference algorithms.
# Run from the repo root: sh demos/m3.sh
set -u
JACQUARD="${JACQUARD:-dune exec jacquard --}"
here="$(dirname "$0")"

echo "== exact posterior by multi-shot enumeration =="
$JACQUARD infer enumerate "$here/m3-two-coins.wft"

echo "== approximate posterior by likelihood weighting (seed 42, K = 100000) =="
$JACQUARD infer lw "$here/m3-two-coins.wft" --seed 42 --samples 100000

echo "== the model file is untouched between runs; only the handler changed =="
$JACQUARD hash "$here/m3-two-coins.wft" | head -n 1
