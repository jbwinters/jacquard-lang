#!/bin/sh
# Value-of-information demo: ask a clarifying question only when its expected
# utility beats the interruption cost. Run from the repo root:
#   sh demos/clarifying-question.sh
set -u
JACQUARD="${JACQUARD:-dune exec jacquard --}"
here="$(dirname "$0")"

$JACQUARD run "$here/clarifying-question.wft"
