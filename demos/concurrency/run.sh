#!/bin/sh
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
JACQUARD_DEMO_ROOT=$(CDPATH= cd -- "$here/.." && pwd)
. "$JACQUARD_DEMO_ROOT/lib/demo-env.sh"

driver="$jacquard_demo_checkout/_build/default/demos/concurrency/concurrency_evidence.exe"
if [ ! -x "$driver" ]; then
  driver="$jacquard_demo_checkout/demos/concurrency/concurrency_evidence.exe"
fi
if [ ! -x "$driver" ]; then
  echo "the structured-concurrency evidence demo requires a source checkout built with dune build @all" >&2
  exit 1
fi

echo "== child authority stays visible =="
jacquard_demo check "$here/task-schedules.jac" --print-sigs |
  grep -E '^(spawn-net|scoped-net) :'

echo "== one task program, four scheduler handlers =="
"$driver" "$jacquard_demo_checkout/prelude" "$here/task-schedules.jac"
