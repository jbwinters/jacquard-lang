#!/bin/sh
# The demos a release reproduces, in one list shared by Release Evidence
# (scripts/release/reproduce-0.3.sh) and the CI development gate, so a demo
# that breaks fails a pull request instead of the multi-hour release run.
#
# usage: run-demos.sh --list   print "<name> <script>" for each demo, one per line
#        run-demos.sh          run every demo in a source checkout; exit 1 if any fails
#
# Run from the repository root after building the CLI (dune build @all). JACQUARD
# is ignored, so the demos use the checkout's own build, as a release run does.
set -eu

demos() {
  cat <<'EOF'
m1 demos/basics/m1.sh
m3 demos/inference/m3.sh
clarifying-question demos/inference/clarifying-question.sh
agent-dream demos/worlds/agent-dream.sh
ambiguity-pipeline demos/inference/ambiguity-pipeline.sh
demo-warp-tests demos/tooling/showcase-warp-tests.sh
repair demos/tooling/repair.sh
hostile-manifest demos/worlds/m4-hostile.sh
preflight demos/worlds/preflight.sh
escrow demos/worlds/escrow/run.sh
release-risk demos/case-studies/release-risk/run.sh
stormglass demos/case-studies/stormglass/run.sh
structured-concurrency demos/concurrency/run.sh
governed-workspace demos/governed-workspace/run.sh
night-shift demos/case-studies/night-shift/run.sh
EOF
}

if [ "$#" -eq 1 ] && [ "$1" = --list ]; then
  demos
  exit 0
fi
if [ "$#" -ne 0 ]; then
  echo "usage: run-demos.sh [--list]" >&2
  exit 2
fi

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$root"
unset JACQUARD
JACQUARD_PRELUDE=$root/prelude
export JACQUARD_PRELUDE

failed=
demos >"${TMPDIR:-/tmp}/run-demos.$$"
while read -r name script; do
  echo "== $name =="
  if ! sh "$script" </dev/null; then
    echo "demo failed: $name ($script)" >&2
    failed="$failed $name"
  fi
done <"${TMPDIR:-/tmp}/run-demos.$$"
rm -f "${TMPDIR:-/tmp}/run-demos.$$"

if [ -n "$failed" ]; then
  echo "failed demos:$failed" >&2
  exit 1
fi
