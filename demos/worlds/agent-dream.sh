#!/bin/sh
# Agent dream mode: run one policy under scripted and probabilistic Net handlers.
set -u
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
JACQUARD_DEMO_ROOT=$(CDPATH= cd -- "$here/.." && pwd)
. "$JACQUARD_DEMO_ROOT/lib/demo-env.sh"

echo "== policy authority =="
jacquard_demo check "$here/agent-dream.jac" --print-sigs | grep '^support-policy'

echo "== scripted worlds and probabilistic dream =="
jacquard_demo run "$here/agent-dream.jac"
