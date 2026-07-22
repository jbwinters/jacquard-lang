#!/usr/bin/env sh
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
checkout=$(CDPATH= cd -- "$here/../.." && pwd)
audit_fixtures="$checkout/corpus/governance"

if [ -f "$checkout/dune-project" ]; then
  jac="$checkout/_build/default/bin/main.exe"
  live_host="$checkout/_build/default/demos/governed-workspace/live_evidence.exe"
else
  # Dune's cram sandbox mirrors the checkout under _build/default.
  jac="$checkout/bin/main.exe"
  live_host="$checkout/demos/governed-workspace/live_evidence.exe"
fi

if [ ! -f "$checkout/dune-project" ] &&
  { [ ! -x "$jac" ] || [ ! -x "$live_host" ]; }; then
  echo "governed-workspace is checkout-only developer evidence" >&2
  echo "run it from a Jacquard source checkout with the local opam switch" >&2
  exit 1
fi

: "${TMPDIR:=$checkout/.scratch/tmp}"
export TMPDIR
mkdir -p "$TMPDIR"
run_tmp=$(mktemp -d "$TMPDIR/jacquard-governed-workspace.XXXXXX")
trap 'rm -rf "$run_tmp"' EXIT HUP INT TERM

if [ ! -x "$jac" ] || [ ! -x "$live_host" ]; then
  dune build --root "$checkout" bin/main.exe demos/governed-workspace/live_evidence.exe
fi
export JACQUARD_PRELUDE="$checkout/prelude"

story="$run_tmp/story.jac"
suite="$run_tmp/tests.jac"
sed '$a\' "$here/agent.jac" > "$story"
sed '$a\' "$here/story.jac" >> "$story"
sed '$a\' "$here/agent.jac" > "$suite"
awk '/^-- --- demo driver ---$/ { exit } { print }' "$here/story.jac" >> "$suite"
sed '$a\' "$here/tests.jac" >> "$suite"

echo "== unchanged Workspace-only agent =="
"$jac" check "$here/agent.jac" --print-sigs | grep '^governed-deploy-agent '
"$jac" hash "$here/agent.jac" | awk -F' ' '/:governed-deploy-agent / { print "agent-id " $2 }'

echo "== inferred dry/live authority =="
"$jac" check "$story" --print-sigs | grep -E '^(dry-world|live-world) '

echo "== deterministic world-free dry and agent fault worlds =="
"$jac" run "$story"

echo "== deterministic nested live drivers =="
host_tmp="$run_tmp/live-host-tmp"
mkdir -p "$host_tmp"
TMPDIR="$host_tmp" "$live_host" "$checkout/prelude" "$here/agent.jac" "$here/story.jac" live

echo "== durable approval queue host bridge =="
bridge_tmp="$run_tmp/bridge-tmp"
mkdir -p "$bridge_tmp"
TMPDIR="$bridge_tmp" "$live_host" "$checkout/prelude" "$here/agent.jac" "$here/story.jac" queue

echo "== verified audit chain for inner pass then outer refusal =="
chain="$run_tmp/nested-refusal.audit"
head=$("$jac" audit genesis | awk '{ print $2 }')
for entry in gm18-audit-inner-allow.jqd gm18-audit-outer-block.jqd gm18-audit-forwarded-refusal.jqd; do
  head=$("$jac" audit append "$chain" "$audit_fixtures/$entry" --previous "$head" | awk '{ print $2 }')
done
"$jac" governance verify-log "$chain" --head "$head"

echo "== Warp: sampled demo laws =="
"$jac" test "$suite" --seed 42 --no-cache

echo "== Warp: exhaustive policy and agent fault worlds =="
"$jac" test "$suite" --seed 42 --no-cache --exhaustive

echo "== GM.15 supporting hostile infrastructure =="
"$jac" test "$checkout/test/cli/governance-fault-laws.jqd" --exhaustive --no-cache
