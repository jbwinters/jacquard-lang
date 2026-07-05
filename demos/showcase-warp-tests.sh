#!/bin/sh
# Warp-backed checks for the demos. Run from the repo root:
#   sh demos/showcase-warp-tests.sh
set -eu

JACQUARD="${JACQUARD:-dune exec jacquard --}"
here="$(dirname "$0")"
tmp="$(mktemp "${TMPDIR:-/tmp}/jacquard-demo-tests.XXXXXX.jqd")"
trap 'rm -f "$tmp"' EXIT

strip_driver() {
  awk '/^; --- demo driver ---$/ { exit } { print }' "$1" >> "$tmp"
  printf '\n' >> "$tmp"
}

strip_driver "$here/clarifying-question.jqd"
strip_driver "$here/agent-dream.jqd"
strip_driver "$here/ambiguity-pipeline.jqd"
cat "$here/showcase-warp-tests.jqd" >> "$tmp"

$JACQUARD test "$tmp" --seed 7 --no-cache
