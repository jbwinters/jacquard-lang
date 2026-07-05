#!/bin/sh
# Ambiguity-preserving extraction: keep a posterior, then condition on a user click.
# Run from the repo root:
#   sh demos/ambiguity-pipeline.sh
set -u
JACQUARD="${JACQUARD:-dune exec jacquard --}"
here="$(dirname "$0")"

$JACQUARD run "$here/ambiguity-pipeline.wft"
