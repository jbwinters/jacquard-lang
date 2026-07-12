#!/bin/sh
# Ambiguity-preserving extraction: keep a posterior, then condition on a user click.
set -u
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
JACQUARD_DEMO_ROOT=$(CDPATH= cd -- "$here/.." && pwd)
. "$JACQUARD_DEMO_ROOT/lib/demo-env.sh"

jacquard_demo run "$here/ambiguity-pipeline.jac"
