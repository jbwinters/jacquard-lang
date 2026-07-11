#!/bin/sh
# The differential harness (docs/native-plan.md, task 74): walks the corpus,
# demos, and bench trees; every file that builds natively must byte-match the
# interpreter — stdout and stderr compared SEPARATELY plus the exit status (a
# merged stream would mask interleaving differences under buffering); every
# file that refuses must appear in test/native-eligibility.txt with its
# expected error line. Runs with no grants and no stdin, so every eligible
# program is deterministic on both engines.
#
# Usage: scripts/native-diff.sh [FILE.jqd ...]   (default: the full walk)
# Env: JACQUARD (default `dune exec jacquard --`), JACQUARD_PRELUDE,
#      JACQUARD_RUNTIME, CC (clang required by the native v1 toolchain).
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
: "${TMPDIR:=$ROOT/.scratch/tmp}"
export TMPDIR
mkdir -p "$TMPDIR"
export JACQUARD_PRELUDE=${JACQUARD_PRELUDE:-$PWD/prelude}
export JACQUARD_RUNTIME=${JACQUARD_RUNTIME:-$PWD/runtime}
export CC=${CC:-clang}
BIN=${JACQUARD:-"dune exec jacquard --"}
MANIFEST=${MANIFEST:-test/native-eligibility.txt}

work=$(mktemp -d "$TMPDIR/jq-diff-XXXXXX")
trap 'rm -rf "$work"' EXIT

files=${*:-"$(find corpus/valid corpus/sigs demos bench -name '*.jqd' 2>/dev/null | sort)"}
# a shrinking walk must be LOUD: bump the floor when files are added, and a
# deletion/renaming that drops coverage fails here instead of passing vacuously
FLOOR=${FLOOR:-69}

pass=0
refused=0
fail=0
for f in $files; do
  if timeout 120 $BIN build "$f" -o "$work/prog" > "$work/build.out" 2> "$work/build.err"; then
    timeout 180 $BIN run "$f" < /dev/null > "$work/i.out" 2> "$work/i.err"; ie=$?
    timeout 180 "$work/prog" < /dev/null > "$work/n.out" 2> "$work/n.err"; ne=$?
    ok=1
    [ "$ie" = "$ne" ] || { echo "DIVERGED (exit): $f interpreter=$ie native=$ne"; ok=0; }
    cmp -s "$work/i.out" "$work/n.out" || { echo "DIVERGED (stdout): $f"; diff "$work/i.out" "$work/n.out" | head -6; ok=0; }
    cmp -s "$work/i.err" "$work/n.err" || { echo "DIVERGED (stderr): $f"; diff "$work/i.err" "$work/n.err" | head -6; ok=0; }
    if [ $ok = 1 ]; then pass=$((pass+1)); else fail=$((fail+1)); fi
  else
    # the refusal must be manifested with a stderr line that matches
    # (exact first-field match: a path must not select another's entry)
    want=$(awk -F'|' -v f="$f" '$1 == f { print substr($0, length(f) + 2); exit }' "$MANIFEST" 2>/dev/null)
    if [ -z "$want" ]; then
      echo "UNMANIFESTED REFUSAL: $f"
      head -2 "$work/build.err"
      fail=$((fail+1))
    elif grep -qF "$want" "$work/build.err"; then
      refused=$((refused+1))
    else
      echo "REFUSAL DRIFTED: $f"
      echo "  manifest: $want"
      echo "  actual:   $(head -1 "$work/build.err")"
      fail=$((fail+1))
    fi
  fi
done
echo "native-diff: $pass identical, $refused manifested refusals, $fail failures"
[ $fail = 0 ] || exit 1
if [ $# = 0 ] && [ $((pass + refused)) -lt "$FLOOR" ]; then
  echo "native-diff: the walk covered $((pass + refused)) files, below the floor of $FLOOR"
  exit 1
fi
echo "native-diff: PASS"
