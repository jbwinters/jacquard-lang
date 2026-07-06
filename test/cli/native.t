Native compilation (docs/native-plan.md, task 67): pure programs compile to
standalone binaries whose output is byte-identical to the interpreter. v1
requires clang (musttail).

  $ export JACQUARD_PRELUDE=../../prelude
  $ export JACQUARD_RUNTIME=../../runtime
  $ export CC=clang

Ten pure programs, interpreter vs native, byte-compared (stdout and exit):

  $ for f in lit-int app-add lit-real lit-text tuple-unit let-shadow match-bool fact even-odd prelude-map; do
  >   jacquard run ../../corpus/valid/$f.jqd > i.out 2>&1
  >   jacquard build ../../corpus/valid/$f.jqd -o prog > /dev/null 2>&1
  >   ./prog > n.out 2>&1
  >   if diff -q i.out n.out > /dev/null; then echo "identical: $f"; else echo "DIVERGED: $f"; diff i.out n.out; fi
  > done
  identical: lit-int
  identical: app-add
  identical: lit-real
  identical: lit-text
  identical: tuple-unit
  identical: let-shadow
  identical: match-bool
  identical: fact
  identical: even-odd
  identical: prelude-map

The benchmark file (recursion, list traffic, a dictionary sort) too:

  $ jacquard run ../../bench/pure.jqd > i.out 2>&1
  $ jacquard build ../../bench/pure.jqd -o bench-prog
  native: compiled 15 unit(s)
  $ ./bench-prog > n.out 2>&1
  $ diff i.out n.out && echo identical
  identical

The unit cache is content-addressed: an unchanged program recompiles nothing.

  $ jacquard build ../../bench/pure.jqd -o bench-prog2
  native: compiled 0 unit(s)

Monomorphization (task 69): a sort at int.ord erases its dictionary — the
specialized unit calls the comparator intrinsic directly and contains no
generic apply at all — and the spec cache is content-addressed like every
other unit (second build recompiles nothing).

  $ cat > sortprog.jqd <<'EOF_JQD'
  > (app (var list.length) (app (var list.sort) (app (var list.reverse) (app (var list.range) (lit 0) (lit 100))) (var int.ord)))
  > EOF_JQD
  $ jacquard build sortprog.jqd -o sortprog > /dev/null
  $ ./sortprog
  100
  $ grep -l 'jq_i_int_compare' .jacquard-native/v1/unit_*.c | wc -l | tr -d ' '
  1
  $ grep -c 'jq_apply' $(grep -l 'jq_i_int_compare' .jacquard-native/v1/unit_*.c)
  0
  [1]
  $ jacquard build sortprog.jqd -o sortprog2
  native: compiled 0 unit(s)
  $ JACQUARD_SPEC=off jacquard build sortprog.jqd -o sortprog-ns > /dev/null
  $ ./sortprog-ns
  100

Ineligible REACHABLE constructs are errors naming the construct and its
home, never silent miscompiles — a handler, an effect operation, a quote.
(Unreachable declarations are fine: eligibility walks the dependency DAG
from the top-level expressions, not the whole file.)

  $ cat > handler.jqd <<'EOF_JQD'
  > (handle (lit 1) (ret (pvar x) (var x)))
  > EOF_JQD
  $ jacquard build handler.jqd -o nope
  error[E1101]: not yet compilable (native v1 compiles pure programs without handlers): top-level expression 0 contains a handler (effects land with tasks 70-71)
  [1]
  $ jacquard build ../../corpus/valid/eval-gated.jqd -o nope
  error[E1101]: not yet compilable (native v1 compiles pure programs without handlers): top-level expression 0 performs an effect operation
  [1]
  $ cat > quoted.jqd <<'EOF_JQD'
  > (quote (lit 1))
  > EOF_JQD
  $ jacquard build quoted.jqd -o nope
  error[E1101]: not yet compilable (native v1 compiles pure programs without handlers): top-level expression 0 contains a quote (code values land with task 73)
  [1]
