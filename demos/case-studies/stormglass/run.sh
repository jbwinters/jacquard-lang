#!/usr/bin/env sh
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
JACQUARD_DEMO_ROOT=$(CDPATH= cd -- "$here/../.." && pwd)
. "$JACQUARD_DEMO_ROOT/lib/demo-env.sh"
suite=$(mktemp "$TMPDIR/jacquard-stormglass-tests.XXXXXX.jac")
trap 'rm -f "$suite"' EXIT

echo "== exact incident forecast for naive and resilient checkout policies =="
jacquard_demo run "$here/model.jac"

awk '/^-- --- demo driver ---$/ { exit } { print }' "$here/model.jac" > "$suite"
printf '\n' >> "$suite"
cat "$here/tests.jac" >> "$suite"

echo "== Warp: cases plus sampled properties =="
jacquard_demo test "$suite" --seed 42 --no-cache

echo "== Warp: exhaustive proof over all 27 service worlds =="
jacquard_demo test "$suite" --seed 42 --no-cache --exhaustive
