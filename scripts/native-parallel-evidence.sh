#!/bin/sh
# SC.2 evidence harness for the deliberately sequential native fallback.
# It does not claim threaded coverage: docs/native-parallel-decision.md records
# why worker execution is unsafe in the current runtime.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
case ${JACQUARD_PRELUDE:-} in
  "") ;;
  /*) ;;
  *) JACQUARD_PRELUDE=$(CDPATH= cd -- "$JACQUARD_PRELUDE" && pwd) ;;
esac
case ${JACQUARD_RUNTIME:-} in
  "") ;;
  /*) ;;
  *) JACQUARD_RUNTIME=$(CDPATH= cd -- "$JACQUARD_RUNTIME" && pwd) ;;
esac
cd "$ROOT"
: "${TMPDIR:=$ROOT/.scratch/tmp}"
export TMPDIR
mkdir -p "$TMPDIR"
export JACQUARD_PRELUDE=${JACQUARD_PRELUDE:-$ROOT/prelude}
export JACQUARD_RUNTIME=${JACQUARD_RUNTIME:-$ROOT/runtime}
export CC=${CC:-clang}
BIN=${JACQUARD:-"dune exec jacquard --"}
ITERATIONS=${JACQUARD_PARALLEL_EVIDENCE_ITERATIONS:-20}
BENCH_RUNS=${JACQUARD_PARALLEL_BENCH_RUNS:-9}

work=$(mktemp -d "$TMPDIR/jq-parallel-evidence-XXXXXX")
trap 'rm -rf "$work"' EXIT

hash_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

build() {
  build_flags=$1
  build_src=$2
  build_out=$3
  JACQUARD_NATIVE_CFLAGS=$build_flags $BIN build "$build_src" -o "$build_out" >/dev/null
}

compare_one() {
  compare_src=$1
  label=$2
  $BIN run "$compare_src" >"$work/$label.i.out" 2>"$work/$label.i.err" || i_status=$?
  : "${i_status:=0}"
  build "" "$compare_src" "$work/$label"
  "$work/$label" >"$work/$label.n.out" 2>"$work/$label.n.err" || n_status=$?
  : "${n_status:=0}"
  test "$i_status" = "$n_status"
  cmp "$work/$label.i.out" "$work/$label.n.out"
  cmp "$work/$label.i.err" "$work/$label.n.err"
  printf '%s\n' "$i_status" >"$work/$label.i.status"
  printf '%s: exit %s, stdout %s, stderr %s\n' "$label" "$n_status" \
    "$(hash_file "$work/$label.n.out")" "$(hash_file "$work/$label.n.err")"
  unset i_status n_status
}

compare_one test/native-parallel/success.jqd success
compare_one test/native-parallel/fail-map.jqd fail-map
compare_one test/native-parallel/fail-both.jqd fail-both

test "$(cat "$work/fail-map.i.err")" = "arithmetic error: division by zero"
test "$(cat "$work/fail-both.i.err")" = "arithmetic error: division by zero"
grep -q '(var mod)' test/native-parallel/fail-map.jqd
grep -q '(var mod)' test/native-parallel/fail-both.jqd
printf 'failure order: map first-of-two and both left-before-right select division before modulo\n'

for n in $(seq 1 "$ITERATIONS"); do
  "$work/success" >"$work/stress.out" 2>"$work/stress.err"
  cmp "$work/success.n.out" "$work/stress.out"
  cmp "$work/success.n.err" "$work/stress.err"
done
printf 'stress: %s identical native runs\n' "$ITERATIONS"

sanitizer_parity() {
  sanitizer=$1
  sanitizer_flags=$2
  for label in success fail-map fail-both; do
    sanitizer_src="test/native-parallel/$label.jqd"
    sanitizer_exe="$work/$label-$sanitizer"
    sanitizer_out="$work/$label.$sanitizer.out"
    sanitizer_err="$work/$label.$sanitizer.err"
    build "$sanitizer_flags" "$sanitizer_src" "$sanitizer_exe"
    if test "$sanitizer" = asan; then
      ASAN_OPTIONS=detect_leaks=1:halt_on_error=1 "$sanitizer_exe" >"$sanitizer_out" \
        2>"$sanitizer_err" || run_status=$?
    else
      TSAN_OPTIONS=halt_on_error=1 "$sanitizer_exe" >"$sanitizer_out" \
        2>"$sanitizer_err" || run_status=$?
    fi
    : "${run_status:=0}"
    test "$run_status" = "$(cat "$work/$label.i.status")"
    cmp "$work/$label.i.out" "$sanitizer_out"
    cmp "$work/$label.i.err" "$sanitizer_err"
    if grep -Eq 'AddressSanitizer|LeakSanitizer|ThreadSanitizer|data race' "$sanitizer_err"; then
      sed -n '1,20p' "$sanitizer_err"
      exit 1
    fi
    printf '%s-%s: exit %s, stdout %s, stderr %s\n' "$sanitizer" "$label" "$run_status" \
      "$(hash_file "$sanitizer_out")" "$(hash_file "$sanitizer_err")"
    unset run_status
  done
}

sanitizer_parity asan "-fsanitize=address -O1 -g"

if test "${JACQUARD_PARALLEL_TSAN:-0}" = 1; then
  sanitizer_parity tsan "-fsanitize=thread -O1 -g"
else
  printf 'tsan: skipped (set JACQUARD_PARALLEL_TSAN=1 where available)\n'
fi

if test "${JACQUARD_PARALLEL_BENCH:-0}" = 1; then
  build "" test/native-parallel/bench-sequential.jqd "$work/bench-sequential"
  build "" test/native-parallel/bench-hint.jqd "$work/bench-hint"
  "$work/bench-sequential" >"$work/bench-sequential.out" 2>"$work/bench-sequential.err"
  "$work/bench-hint" >"$work/bench-hint.out" 2>"$work/bench-hint.err"
  cmp "$work/bench-sequential.out" "$work/bench-hint.out"
  cmp "$work/bench-sequential.err" "$work/bench-hint.err"
  printf 'benchmark output: identical, stdout %s, stderr %s\n' \
    "$(hash_file "$work/bench-hint.out")" "$(hash_file "$work/bench-hint.err")"
  for mode in sequential hint; do
    timings="$work/$mode.ns"
    : >"$timings"
    n=0
    while test "$n" -lt "$BENCH_RUNS"; do
      start=$(date +%s%N)
      "$work/bench-$mode" >/dev/null
      finish=$(date +%s%N)
      echo $((finish - start)) >>"$timings"
      n=$((n + 1))
    done
    middle=$((BENCH_RUNS / 2 + 1))
    median=$(sort -n "$timings" | sed -n "${middle}p")
    awk -v mode="$mode" -v ns="$median" -v runs="$BENCH_RUNS" \
      'BEGIN { printf "benchmark %s: %.3f ms median-of-%d\n", mode, ns / 1000000, runs }'
  done
else
  printf 'benchmark: skipped (set JACQUARD_PARALLEL_BENCH=1)\n'
fi
