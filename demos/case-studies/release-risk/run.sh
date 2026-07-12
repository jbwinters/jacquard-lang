#!/usr/bin/env sh
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
JACQUARD_DEMO_ROOT=$(CDPATH= cd -- "$here/../.." && pwd)
. "$JACQUARD_DEMO_ROOT/lib/demo-env.sh"
snapshot=$(mktemp "$TMPDIR/jacquard-release-risk-snapshot.XXXXXX.jac")
suite=$(mktemp "$TMPDIR/jacquard-release-risk-tests.XXXXXX.jac")
trap 'rm -f "$snapshot" "$suite"' EXIT

strip_driver() {
  awk '/^-- --- demo driver ---$/ { exit } { print }' "$here/model.jac"
}

echo "== inferred authority =="
jacquard_demo check "$here/model.jac" --print-sigs | grep -E '^(release-assessment|with-snapshot|with-risk-model|conditioned-release-risk) '

echo "== the same policy under a concrete snapshot handler =="
strip_driver > "$snapshot"
printf '\ncurrent-snapshot()\n' >> "$snapshot"
jacquard_demo run "$snapshot"

echo "== the policy under a probabilistic telemetry handler =="
jacquard_demo infer enumerate "$here/model.jac"

echo "== Warp: cases plus sampled property =="
strip_driver > "$suite"
printf '\n' >> "$suite"
cat "$here/tests.jac" >> "$suite"
jacquard_demo test "$suite" --seed 42 --no-cache

echo "== Warp: exhaustive proof over all 18 telemetry worlds =="
jacquard_demo test "$suite" --seed 42 --no-cache --exhaustive
