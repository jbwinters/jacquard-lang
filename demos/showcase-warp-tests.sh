#!/bin/sh
# Warp-backed checks for the demos. Run from the repo root:
#   sh demos/showcase-warp-tests.sh
set -eu

WEFT="${WEFT:-dune exec weft --}"
here="$(dirname "$0")"
tmp="$(mktemp "${TMPDIR:-/tmp}/weft-demo-tests.XXXXXX.wft")"
trap 'rm -f "$tmp"' EXIT

strip_driver() {
  awk '/^; --- demo driver ---$/ { exit } { print }' "$1" >> "$tmp"
  printf '\n' >> "$tmp"
}

strip_driver "$here/clarifying-question.wft"
strip_driver "$here/agent-dream.wft"
strip_driver "$here/ambiguity-pipeline.wft"
cat "$here/showcase-warp-tests.wft" >> "$tmp"

$WEFT test "$tmp" --seed 7 --no-cache
