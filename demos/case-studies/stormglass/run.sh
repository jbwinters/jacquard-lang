#!/usr/bin/env sh
set -eu

JACQUARD="${JACQUARD:-dune exec jac --}"
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
scratch=${TMPDIR:-$PWD/.scratch/tmp}
mkdir -p "$scratch"
suite=$(mktemp "$scratch/jacquard-stormglass-tests.XXXXXX.jac")
trap 'rm -f "$suite"' EXIT

echo "== exact incident forecast for naive and resilient checkout policies =="
$JACQUARD run "$here/model.jac"

awk '/^-- --- demo driver ---$/ { exit } { print }' "$here/model.jac" > "$suite"
printf '\n' >> "$suite"
cat "$here/tests.jac" >> "$suite"

echo "== Warp: cases plus sampled properties =="
$JACQUARD test "$suite" --seed 42 --no-cache

echo "== Warp: exhaustive proof over all 27 service worlds =="
$JACQUARD test "$suite" --seed 42 --no-cache --exhaustive
