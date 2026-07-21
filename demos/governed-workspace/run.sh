#!/usr/bin/env sh
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
checkout=$(CDPATH= cd -- "$here/../.." && pwd)

if [ ! -f "$checkout/dune-project" ]; then
  echo "governed-workspace is checkout-only developer evidence" >&2
  echo "run it from a Jacquard source checkout with the local opam switch" >&2
  exit 1
fi

: "${TMPDIR:=$checkout/.scratch/tmp}"
export TMPDIR
mkdir -p "$TMPDIR"
run_tmp=$(mktemp -d "$TMPDIR/jacquard-governed-workspace.XXXXXX")
trap 'rm -rf "$run_tmp"' EXIT HUP INT TERM

dune build --root "$checkout" bin/main.exe test/test_jacquard.exe
jac="$checkout/_build/default/bin/main.exe"
bridge="$checkout/_build/default/test/test_jacquard.exe"
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

echo "== deterministic dry and nested live worlds =="
"$jac" run "$story"

echo "== durable approval queue host bridge =="
bridge_tmp="$run_tmp/bridge-tmp"
mkdir -p "$bridge_tmp"
if ! (cd "$checkout/test" && TMPDIR="$bridge_tmp" "$bridge" test governance-approval-bridge 4 --compact --color=never) >"$run_tmp/bridge.out" 2>"$run_tmp/bridge.err"; then
  cat "$run_tmp/bridge.out"
  cat "$run_tmp/bridge.err" >&2
  exit 1
fi
echo '("agent/queue-denial", "Governance_approval_bridge", "durable exact proposal", "Denied", "raw-actions", 0)'

echo "== verified audit chain for inner pass then outer refusal =="
chain="$run_tmp/nested-refusal.audit"
head=$("$jac" audit genesis | awk '{ print $2 }')
for entry in audit-inner-allow.jqd audit-outer-block.jqd audit-forwarded-refusal.jqd; do
  head=$("$jac" audit append "$chain" "$here/$entry" --previous "$head" | awk '{ print $2 }')
done
"$jac" governance verify-log "$chain" --head "$head"

echo "== Warp: sampled demo laws =="
"$jac" test "$suite" --seed 42 --no-cache

echo "== Warp: exhaustive strict/permissive policy worlds =="
"$jac" test "$suite" --seed 42 --no-cache --exhaustive

echo "== GM.15 hostile fault space (existing executable lane) =="
"$jac" test "$checkout/test/cli/governance-fault-laws.jqd" --exhaustive --no-cache
