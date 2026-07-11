#!/usr/bin/env sh
set -eu

JACQUARD="${JACQUARD:-dune exec jac --}"
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
scratch=${TMPDIR:-$PWD/.scratch/tmp}
mkdir -p "$scratch"
snapshot=$(mktemp "$scratch/jacquard-release-risk-snapshot.XXXXXX.jac")
suite=$(mktemp "$scratch/jacquard-release-risk-tests.XXXXXX.jac")
trap 'rm -f "$snapshot" "$suite"' EXIT

strip_driver() {
  awk '/^-- --- demo driver ---$/ { exit } { print }' "$here/model.jac"
}

echo "== inferred authority =="
$JACQUARD check "$here/model.jac" --print-sigs | grep -E '^(release-assessment|with-snapshot|with-risk-model|conditioned-release-risk) '

echo "== the same policy under a concrete snapshot handler =="
strip_driver > "$snapshot"
printf '\ncurrent-snapshot()\n' >> "$snapshot"
$JACQUARD run "$snapshot"

echo "== the policy under a probabilistic telemetry handler =="
$JACQUARD infer enumerate "$here/model.jac"

echo "== Warp: cases plus sampled property =="
strip_driver > "$suite"
printf '\n' >> "$suite"
cat "$here/tests.jac" >> "$suite"
$JACQUARD test "$suite" --seed 42 --no-cache

echo "== Warp: exhaustive proof over all 18 telemetry worlds =="
$JACQUARD test "$suite" --seed 42 --no-cache --exhaustive
