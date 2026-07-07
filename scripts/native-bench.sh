#!/bin/sh
# The benchmark table's producer (docs/native-plan.md, task 75). Three
# columns per program: interpreter, native, hand-written C reference where
# one exists. Method: median of 5 wall-clock runs, the engine's own startup
# subtracted (a `(lit 0)` program's median for each engine), clang -O2 -flto (the default)
# everywhere. The C column is raw — its ~1 ms process launch is NOT
# subtracted, which makes the reported native-vs-C ratios conservative.
# Reproduce the docs/native-compilation.md table with:
#   sh scripts/native-bench.sh
set -eu
export JACQUARD_PRELUDE=${JACQUARD_PRELUDE:-$PWD/prelude}
export JACQUARD_RUNTIME=${JACQUARD_RUNTIME:-$PWD/runtime}
export CC=${CC:-clang}
BIN=${JACQUARD:-"dune exec jacquard --"}

work=$(mktemp -d "${TMPDIR:-/tmp}/jq-bench-XXXXXX")
trap 'rm -rf "$work"' EXIT
echo "(lit 0)" > "$work/null.jqd"

now_ns() { date +%s%N; }

# median-of-5 wall time of a command, milliseconds
median5() {
  for _ in 1 2 3 4 5; do
    s=$(now_ns)
    "$@" > /dev/null 2>&1
    e=$(now_ns)
    echo $(((e - s) / 1000000))
  done | sort -n | sed -n 3p
}

$BIN build "$work/null.jqd" -o "$work/null" > /dev/null
i_base=$(median5 sh -c "$BIN run $work/null.jqd")
n_base=$(median5 "$work/null")
echo "startup baselines: interpreter ${i_base}ms, native ${n_base}ms"
echo
echo "| program | interpreter | native | hand C |"
echo "| --- | --- | --- | --- |"

row() {
  prog=$1; ref=${2:-}
  $BIN build "bench/$prog.jqd" -o "$work/$prog" > /dev/null
  i=$(median5 sh -c "$BIN run bench/$prog.jqd")
  n=$(median5 "$work/$prog")
  i=$((i - i_base)); [ $i -lt 0 ] && i=0
  n=$((n - n_base)); [ $n -lt 0 ] && n=0
  if [ -n "$ref" ]; then
    $CC -std=c11 -O2 -o "$work/ref-$prog" "bench/ref/$ref"
    c=$(median5 "$work/ref-$prog")
    echo "| $prog | ${i} ms | ${n} ms | ${c} ms |"
  else
    echo "| $prog | ${i} ms | ${n} ms | — |"
  fi
}

row fib fib.c
row sort sort.c
row sum sum.c
row text text.c
row pure
row avl
row state-loop state-loop.c
row enum
row mutate mutate.c
