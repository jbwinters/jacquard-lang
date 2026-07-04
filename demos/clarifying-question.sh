#!/bin/sh
# Value-of-information demo: ask a clarifying question only when its expected
# utility beats the interruption cost. Run from the repo root:
#   sh demos/clarifying-question.sh
set -u
WEFT="${WEFT:-dune exec weft --}"
here="$(dirname "$0")"

$WEFT run "$here/clarifying-question.wft"
