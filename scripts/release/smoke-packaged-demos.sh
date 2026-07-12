#!/usr/bin/env sh
set -eu

if [ "$#" -ne 1 ]; then
  echo "usage: $0 PACKAGE_ROOT_OR_PREFIX" >&2
  exit 2
fi

root=$(CDPATH= cd -- "$1" && pwd)
demos="$root/share/jacquard/demos"
if [ ! -x "$root/bin/jac" ] || [ ! -d "$demos" ]; then
  echo "not a Jacquard package root: $root" >&2
  exit 1
fi
test -f "$root/share/jacquard/LICENSE"
test -f "$root/share/jacquard/RUNTIME-EXCEPTION.md"
test -f "$root/share/jacquard/COMMERCIAL-LICENSE.md"
test -f "$root/share/jacquard/TRADEMARKS.md"
test -f "$root/share/jacquard/runtime/jq_value.h"
grep -q 'Additional permission applies' "$root/share/jacquard/runtime/jq_value.h"

: "${TMPDIR:=$root/.demo-smoke-tmp}"
export TMPDIR
mkdir -p "$TMPDIR"

# The installed demo contract must not inherit a developer toolchain. The
# scripts discover jac from the package and the wrapper discovers its prelude.
PATH="$root/bin:/usr/bin:/bin"
export PATH
unset JACQUARD JACQUARD_PRELUDE
if command -v dune >/dev/null 2>&1; then
  echo "packaged demo smoke unexpectedly found dune" >&2
  exit 1
fi

release_risk="$TMPDIR/release-risk.out"
agent_dream="$TMPDIR/agent-dream.out"
escrow="$TMPDIR/escrow.out"
native="$TMPDIR/native-fact"

sh "$demos/case-studies/release-risk/run.sh" >"$release_risk" 2>&1
grep -q '^== inferred authority ==$' "$release_risk"
grep -q 'verified exhaustively (18 cases)' "$release_risk"

sh "$demos/worlds/agent-dream.sh" >"$agent_dream" 2>&1
grep -q '^support-policy : ' "$agent_dream"
grep -q 'issue-refund' "$agent_dream"

sh "$demos/worlds/escrow/run.sh" >"$escrow" 2>&1
grep -q '^== dry-run: intended actions, no receipt mutation ==$' "$escrow"
grep -q 'approval invalidated' "$escrow"

native_work="$TMPDIR/native-build"
rm -rf "$native_work"
mkdir -p "$native_work"
(
  cd "$native_work"
  jac build "$demos/basics/m1-fact.jqd" -o "$native"
) >/dev/null
test "$("$native")" = "120"
grep -R -q 'licensed under terms chosen by the user' "$native_work/.jacquard-native"

echo "packaged demos: PASS (release-risk, agent-dream, escrow, native build; no dune)"
