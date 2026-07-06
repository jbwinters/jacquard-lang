Effects II (docs/native-plan.md, task 71): capturing and multi-shot handlers
compile; every handler-gauntlet semantic case runs natively byte-identical to
the interpreter. The twins and their mapping to the OCaml suites live in
test/native-gauntlet/ (MAPPING.md); the byte comparison here IS each case's
assertion, exit codes included.

  $ export JACQUARD_PRELUDE=../../prelude
  $ export JACQUARD_RUNTIME=../../runtime
  $ export CC=clang

  $ for f in ../../test/native-gauntlet/g*.jqd; do
  >   n=$(basename $f .jqd)
  >   jacquard run $f > i.out 2>&1; ie=$?
  >   jacquard build $f -o prog > /dev/null 2>&1 || { echo "REFUSED: $n"; continue; }
  >   ./prog > n.out 2>&1; ne=$?
  >   if diff -q i.out n.out > /dev/null && [ "$ie" = "$ne" ]
  >   then echo "identical: $n (exit $ie)"
  >   else echo "DIVERGED: $n interpreter=$ie native=$ne"; diff i.out n.out
  >   fi
  > done
  identical: g01-choose-tuple (exit 0)
  identical: g02-thrice (exit 0)
  identical: g03-deep-inner-count (exit 0)
  identical: g04-state-run (exit 0)
  identical: g05-abort-short-circuit (exit 0)
  identical: g06-deep-second-perform (exit 0)
  identical: g07-forwarding (exit 0)
  identical: g08-nearest-wins (exit 0)
  identical: g09-ret-transforms (exit 0)
  identical: g10-ret-per-resumption (exit 0)
  identical: g11-unhandled-names (exit 3)
  identical: g12-unhandled-past-other (exit 3)
  identical: g13-clause-escapes-outward (exit 0)
  identical: g14-op-as-value (exit 0)
  identical: g15-four-leaves (exit 0)
  identical: g16-nested-shadowing (exit 0)
  identical: g17-ret-outside-region (exit 3)
  identical: g18-abort-skips-pending (exit 0)
  identical: g19-escaped-resume (exit 0)
  identical: g20-throw-either (exit 0)
  identical: g21-conditional-resume (exit 0)
  identical: g22-enum-m3 (exit 0)

The flagship outputs, pinned so a both-engines regression cannot slip through
the diff-only loop above:

  $ jacquard build ../../test/native-gauntlet/g01-choose-tuple.jqd -o choose > /dev/null
  $ ./choose
  cons(1, cons(2, nil))
  $ jacquard build ../../test/native-gauntlet/g19-escaped-resume.jqd -o escaped > /dev/null
  $ ./escaped
  (done(2), done(3))
  $ jacquard build ../../test/native-gauntlet/g22-enum-m3.jqd -o enum-m3 > /dev/null
  $ ./enum-m3
  cons(mk-pair(true, 0.3333333333333333), cons(mk-pair(true, 0.3333333333333333), cons(mk-pair(false, 0.3333333333333333), cons(mk-pair(false, 0.0), nil))))

demos/m1.sh's three legs (task-71 DoD): fact and choose native-identical, the
gated-eval leg a pinned refusal.

  $ jacquard run ../../demos/m1-fact.jqd > i.out 2>&1
  $ jacquard build ../../demos/m1-fact.jqd -o fact > /dev/null
  $ ./fact > n.out 2>&1
  $ diff i.out n.out && echo identical
  identical
  $ jacquard run ../../demos/m1-choose.jqd > i.out 2>&1
  $ jacquard build ../../demos/m1-choose.jqd -o choose > /dev/null
  $ ./choose > n.out 2>&1
  $ diff i.out n.out && echo identical
  identical
  $ jacquard build ../../demos/m1-gated.jqd -o nope
  error[E1101]: not yet compilable (native v1 compiles programs without code values): top-level expression 0 uses eval, which requires the interpreter tier
  [1]

An effectful top-level definition is refused by the checker before either
engine runs (E0815) — the interpreter's decl-body isolation path is not
reachable from the surface:

  $ cat > iso.jqd <<'EOF_JQD'
  > (defeffect ticker () (op tick () (ttuple)))
  > (defterm ((binding poked ()
  >   (let nonrec (pwild) (app (var tick)) (lit 7)))))
  > (var poked)
  > EOF_JQD
  $ jacquard build iso.jqd -o nope 2>&1 | tail -2
  iso.jqd:2:11-3:49: error[E0815]: top-level definition `poked` performs the `ticker` effect while being defined
    hint: wrap the body in a lambda and perform the effect when called
