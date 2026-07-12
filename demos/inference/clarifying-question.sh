#!/bin/sh
# Value-of-information demo: ask a clarifying question only when its expected
# utility beats the interruption cost.
set -u
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
JACQUARD_DEMO_ROOT=$(CDPATH= cd -- "$here/.." && pwd)
. "$JACQUARD_DEMO_ROOT/lib/demo-env.sh"

jacquard_demo run "$here/clarifying-question.jac"
