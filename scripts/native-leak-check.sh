#!/bin/sh
# Perceus leak harness (docs/native-plan.md, task 68): builds every given
# program (defaults to the differential set) with ASAN+leak detection and
# fails on any report. Run from the repo root with clang available.
set -eu
export JACQUARD_PRELUDE=${JACQUARD_PRELUDE:-$PWD/prelude}
export JACQUARD_RUNTIME=${JACQUARD_RUNTIME:-$PWD/runtime}
export CC=${CC:-clang}
export JACQUARD_NATIVE_CFLAGS="-fsanitize=address -O1 -g"
BIN=${JACQUARD:-"dune exec jacquard --"}
out=$(mktemp -u "${TMPDIR:-/tmp}/jq-leak-XXXXXX")
trap 'rm -f "$out"' EXIT
progs=${*:-"bench/pure.jqd bench/avl.jqd corpus/valid/prelude-map.jqd corpus/valid/even-odd.jqd corpus/valid/fact.jqd corpus/valid/lit-int.jqd corpus/valid/app-add.jqd corpus/valid/lit-real.jqd corpus/valid/lit-text.jqd corpus/valid/tuple-unit.jqd corpus/valid/let-shadow.jqd corpus/valid/match-bool.jqd"}
for f in $progs; do
  $BIN build "$f" -o "$out" > /dev/null
  ASAN_OPTIONS=detect_leaks=1 "$out" > /dev/null 2>&1 || {
    echo "LEAK/ERROR: $f"; ASAN_OPTIONS=detect_leaks=1 "$out" 2>&1 | head -20; exit 1; }
  echo "clean: $f"
done
echo "native leak check: PASS"
