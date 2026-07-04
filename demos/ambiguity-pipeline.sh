#!/bin/sh
# Ambiguity-preserving extraction: keep a posterior, then condition on a user click.
# Run from the repo root:
#   sh demos/ambiguity-pipeline.sh
set -u
WEFT="${WEFT:-dune exec weft --}"
here="$(dirname "$0")"

$WEFT run "$here/ambiguity-pipeline.wft"
