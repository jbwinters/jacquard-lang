#!/bin/sh
# Perceus leak harness (docs/native-plan.md, tasks 68 + 71): builds every given
# program with ASAN+leak detection and fails on any sanitizer report. The
# default set is the pure differential battery PLUS the whole effect gauntlet
# (capture/resume is where RC bugs live — the task-71 DoD requires every
# gauntlet program here). Programs that legitimately exit 3 (unhandled or
# ungranted effects) still leak-check: LeakSanitizer runs at exit.
# Run from the repo root with clang available.
set -eu
export JACQUARD_PRELUDE=${JACQUARD_PRELUDE:-$PWD/prelude}
export JACQUARD_RUNTIME=${JACQUARD_RUNTIME:-$PWD/runtime}
export CC=${CC:-clang}
export JACQUARD_NATIVE_CFLAGS="-fsanitize=address -O1 -g"
BIN=${JACQUARD:-"dune exec jacquard --"}
out=$(mktemp -u "${TMPDIR:-/tmp}/jq-leak-XXXXXX")
log=$(mktemp "${TMPDIR:-/tmp}/jq-leak-log-XXXXXX")
trap 'rm -f "$out" "$log"' EXIT
progs=${*:-"bench/pure.jqd bench/avl.jqd corpus/valid/prelude-map.jqd corpus/valid/even-odd.jqd corpus/valid/fact.jqd corpus/valid/lit-int.jqd corpus/valid/app-add.jqd corpus/valid/lit-real.jqd corpus/valid/lit-text.jqd corpus/valid/tuple-unit.jqd corpus/valid/let-shadow.jqd corpus/valid/match-bool.jqd corpus/valid/to-option.jqd corpus/valid/safe-div.jqd demos/m1-fact.jqd demos/m1-choose.jqd $(ls test/native-gauntlet/g*.jqd 2>/dev/null | tr '\n' ' ')"}
for f in $progs; do
  $BIN build "$f" -o "$out" > /dev/null
  status=0
  ASAN_OPTIONS=detect_leaks=1 "$out" > "$log" 2>&1 || status=$?
  if grep -q "Sanitizer" "$log"; then
    echo "LEAK/ERROR: $f"; head -20 "$log"; exit 1
  fi
  case $status in
    0|3) ;;
    *) echo "UNEXPECTED EXIT $status: $f"; head -10 "$log"; exit 1 ;;
  esac
  echo "clean: $f (exit $status)"
done
echo "native leak check: PASS"
