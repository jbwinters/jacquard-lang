#!/bin/sh
# Warp-backed checks for the demos.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
JACQUARD_DEMO_ROOT=$(CDPATH= cd -- "$here/.." && pwd)
. "$JACQUARD_DEMO_ROOT/lib/demo-env.sh"
demos=$JACQUARD_DEMO_ROOT
tmp="$(mktemp "$TMPDIR/jacquard-demo-tests.XXXXXX.jqd")"
trap 'rm -f "$tmp"' EXIT

strip_driver() {
  awk '/^; --- demo driver ---$/ { exit } { print }' "$1" >> "$tmp"
  printf '\n' >> "$tmp"
}

strip_driver "$demos/inference/clarifying-question.jqd"
strip_driver "$demos/worlds/agent-dream.jqd"
strip_driver "$demos/inference/ambiguity-pipeline.jqd"
cat "$here/showcase-warp-tests.jqd" >> "$tmp"

jacquard_demo test "$tmp" --seed 7 --no-cache
