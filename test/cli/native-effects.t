Effects II (docs/native-plan.md, task 71): capturing and multi-shot handlers
compile; every handler-gauntlet semantic case runs natively byte-identical to
the interpreter. The twins and their mapping to the OCaml suites live in
test/native-gauntlet/ (MAPPING.md); the byte comparison here IS each case's
assertion, exit codes included.

  $ export JACQUARD_PRELUDE=../../prelude
  $ export JACQUARD_RUNTIME=../../runtime
  $ export CC=clang

  $ for f in ../../test/native-gauntlet/[eg]*.jqd; do
  >   n=$(basename $f .jqd)
  >   jacquard run $f > i.out 2>&1; ie=$?
  >   jacquard build $f -o prog > /dev/null 2>&1 || { echo "REFUSED: $n"; continue; }
  >   ./prog > n.out 2>&1; ne=$?
  >   if diff -q i.out n.out > /dev/null && [ "$ie" = "$ne" ]
  >   then echo "identical: $n (exit $ie)"
  >   else echo "DIVERGED: $n interpreter=$ie native=$ne"; diff i.out n.out
  >   fi
  > done
  identical: e02-erasure-type-error (exit 2)
  identical: e03-erasure-arity (exit 2)
  identical: e04-erasure-match-failure (exit 2)
  identical: e05-code-form-bad-head (exit 2)
  identical: e06-erasure-splice-not-code (exit 2)
  identical: e07-erasure-text-join (exit 2)
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
  identical: g23-fault-random (exit 0)
  identical: g24-dst (exit 0)
  identical: g25-chain-order (exit 0)
  identical: g26-lw-m3 (exit 0)
  identical: g27-lw-under-handler (exit 0)
  identical: g28-lw-nested (exit 0)
  identical: g29-lw-soft (exit 0)
  identical: g30-deep-mutual-tail (exit 0)
  identical: g31-repair-pure (exit 0)
  identical: g32-code-ops (exit 0)
  identical: g33-quote-effectful-splice (exit 0)
  identical: g34-spec-const-list (exit 0)
  identical: g35-stdlib-ss22 (exit 0)
  identical: g36-audit-code-render (exit 0)

Opaque host values are the exception to the public direct-member carrier: their
marker identity is absent from the store's derived-hash index, so the checker and
native builder both fail closed before a generic constructor value can cross the
validated Hash boundary.

  $ cat > opaque-hash-ref.jqd <<'EOF_JQD'
  > (ref #d48426af83dd64417666d11346b732136f39950871f9c4708e947515f9eda3db con)
  > EOF_JQD
  $ jacquard check opaque-hash-ref.jqd 2>&1 | sed 's/opaque-hash-ref.jqd:[0-9]*:[0-9]*-[0-9]*/opaque-hash-ref.jqd:LINE:SPAN/'
  opaque-hash-ref.jqd:LINE:SPAN: error[E0805]: error[E0601]: unknown hash d48426af83dd64417666d11346b732136f39950871f9c4708e947515f9eda3db
  $ jacquard build opaque-hash-ref.jqd -o opaque-native 2>&1 | sed 's/opaque-hash-ref.jqd:[0-9]*:[0-9]*-[0-9]*/opaque-hash-ref.jqd:LINE:SPAN/'
  opaque-hash-ref.jqd:LINE:SPAN: error[E0805]: error[E0601]: unknown hash d48426af83dd64417666d11346b732136f39950871f9c4708e947515f9eda3db

The flagship outputs, pinned so a both-engines regression cannot slip through
the diff-only loop above:

  $ jacquard build ../../test/native-gauntlet/g01-choose-tuple.jqd -o choose > /dev/null
  $ ./choose
  cons(1, cons(2, nil))
  $ jacquard build ../../test/native-gauntlet/g04-state-run.jqd -o state-branches > /dev/null
  $ ./state-branches
  cons((1, 1), cons((2, 2), nil))

The D43 successor keeps the two prelude transformers whose next-state values
must be computed before resuming. These witnesses pin their public behavior on
both engines after that semantics-preserving source rewrite:

  $ cat > record-transformer.jqd <<'EOF_JQD'
  > (app (var throw.catch)
  >   (lam ()
  >     (app (var net.scripted)
  >       (lam ()
  >         (match
  >           (app (var net.record)
  >             (lam ()
  >               (match (app (var fetch) (app (var mk-request) (lit "http://record") (lit "")))
  >                 (clause (pcon mk-response (pwild) (pvar body)) (var body)))))
  >           (clause (ptuple (pvar result) (pwild)) (var result))))
  >       (app (var cons) (app (var mk-response) (lit 200) (lit "recorded")) (var nil))))
  >   (lam ((pvar error)) (var error)))
  > EOF_JQD
  $ jacquard run record-transformer.jqd > record-i.out
  $ cat record-i.out
  "recorded"
  $ jacquard build record-transformer.jqd -o record-transformer > /dev/null
  $ ./record-transformer > record-n.out
  $ diff record-i.out record-n.out && cat record-i.out
  "recorded"
  $ cat > fs-transformer.jqd <<'EOF_JQD'
  > (app (var throw.catch)
  >   (lam ()
  >     (match
  >       (app (var fs.in-memory)
  >         (lam ()
  >           (let nonrec (pwild) (app (var write) (lit "note") (lit "hello"))
  >             (app (var read) (lit "note"))))
  >         (app (var map.empty) (var text.ord)))
  >       (clause (ptuple (pvar result) (pwild)) (var result))))
  >   (lam ((pvar error)) (var error)))
  > EOF_JQD
  $ jacquard run fs-transformer.jqd > fs-i.out
  $ jacquard build fs-transformer.jqd -o fs-transformer > /dev/null
  $ ./fs-transformer > fs-n.out
  $ diff fs-i.out fs-n.out && cat fs-i.out
  "hello"

  $ jacquard build ../../test/native-gauntlet/g19-escaped-resume.jqd -o escaped > /dev/null
  $ ./escaped
  (done(2), done(3))
  $ jacquard build ../../test/native-gauntlet/g22-enum-m3.jqd -o enum-m3 > /dev/null
  $ ./enum-m3
  cons(mk-pair(true, 0.3333333333333333), cons(mk-pair(true, 0.3333333333333333), cons(mk-pair(false, 0.3333333333333333), cons(mk-pair(false, 0.0), nil))))

The DST battery is bit-deterministic natively: run twice, byte-identical
(the task-72 DoD; both runs also byte-match the interpreter through the
loop above):

  $ jacquard build ../../test/native-gauntlet/g24-dst.jqd -o dst > /dev/null
  $ ./dst > dst1.out 2>&1
  $ ./dst > dst2.out 2>&1
  $ diff dst1.out dst2.out && echo stable
  stable
  $ cat dst1.out
  mk-report(cons(("net.fetch=ok body99", true), cons(("net.fetch=FAULT net: connection refused (injected)", true), nil)), none)

demos/basics/m1.sh's three legs (task-71 DoD): fact and choose native-identical, the
gated-eval leg a pinned refusal.

  $ jacquard run ../../demos/basics/m1-fact.jqd > i.out 2>&1
  $ jacquard build ../../demos/basics/m1-fact.jqd -o fact > /dev/null
  $ ./fact > n.out 2>&1
  $ diff i.out n.out && echo identical
  identical
  $ jacquard run ../../demos/basics/m1-choose.jqd > i.out 2>&1
  $ jacquard build ../../demos/basics/m1-choose.jqd -o choose > /dev/null
  $ ./choose > n.out 2>&1
  $ diff i.out n.out && echo identical
  identical
  $ jacquard build ../../demos/basics/m1-gated.jqd -o nope
  error[E1102]: top-level expression 0 uses eval, which requires the interpreter tier
  [1]

Dist parity (task 72). The likelihood-weighting driver reproduces the
interpreter's seeded stream exactly — one split per run, one draw per
sample — and its merge/normalize/sort down to float addition ORDER (the
interpreter folds a cons-prepended run list, so sums run in reverse
chronological order; g29 pins the soft-likelihood case where a forward
sum drifts by one ULP). The M3 model at seed 42:

  $ jacquard build ../../test/native-gauntlet/g26-lw-m3.jqd -o lw-m3 > /dev/null
  $ ./lw-m3
  cons(mk-pair(true, 0.6683497209673133), cons(mk-pair(false, 0.3316502790326867), nil))

The `%.6f` posterior table of `jacquard infer` is CLI tooling with no
program-reachable rendering; the buildable m3 target is this weighted
list (docs/native-plan.md records the boundary). The LW error legs:

  $ cat > lw-zero.jqd <<'EOF_JQD'
  > (app (var dist.sample-lw) (lam () (app (var sample) (app (var bernoulli) (lit 0.5)))) (lit 0) (lit 11))
  > EOF_JQD
  $ jacquard build lw-zero.jqd -o lw-zero > /dev/null
  $ ./lw-zero
  arithmetic error: dist.sample-lw needs a positive sample count
  [2]
  $ cat > lw-empty.jqd <<'EOF_JQD'
  > (app (var dist.sample-lw) (lam () (let nonrec (pwild) (app (var observe) (app (var bernoulli) (lit 1.0)) (var false)) (lit 1))) (lit 5) (lit 42))
  > EOF_JQD
  $ jacquard build lw-empty.jqd -o lw-empty > /dev/null
  $ ./lw-empty
  arithmetic error: error[E0901]: the posterior is empty: every run is impossible under the observations
  [2]

A model op that only an OUTER handler could cover is hidden by the run's
isolation on both engines, and the failure flattens through the driver's
diagnostics (E0902, exit 2) with the pseudo-effect named:

  $ cat > lw-outer-op.jqd <<'EOF_JQD'
  > (defeffect e-x ((tvar a)) (op xop () (tref int)))
  > (handle
  >   (app (var dist.sample-lw) (lam () (app (var xop))) (lit 3) (lit 42))
  >   (ret (pvar x) (var x))
  >   (opclause xop () k (app (var k) (lit 1))))
  > EOF_JQD
  $ jacquard build lw-outer-op.jqd -o lw-outer-op > /dev/null
  $ ./lw-outer-op
  arithmetic error: error[E0902]: unhandled effect (not handled during inference): operation `xop` reached the root without a handler
  [2]

The root sampling grant: --allow dist with --seed draws the interpreter's
exact stream; observe at the root is the interpreter's E0904 defect:

  $ cat > die.jqd <<'EOF_JQD'
  > (app (var sample) (app (var uniform-int) (lit 1) (lit 6)))
  > EOF_JQD
  $ jacquard build die.jqd -o die > /dev/null
  $ jacquard run die.jqd --allow dist --seed 42
  5
  $ ./die --allow dist --seed 42
  5
  $ ./die --allow dist --seed=7
  3
  $ cat > obs.jqd <<'EOF_JQD'
  > (app (var observe) (app (var bernoulli) (lit 1.0)) (var true))
  > EOF_JQD
  $ jacquard build obs.jqd -o obs > /dev/null
  $ ./obs --allow dist
  error[E0904]: observe reached the sampling root handler; observation requires an inference driver (use jacquard infer)
  [2]

Row erasure can also smuggle a wrongly-typed value into a GRANT (the op
payload type does not flow to the handler): the grant's defensive type
error is live parity surface too:

  $ cat > erasure-grant.jqd <<'EOF_JQD'
  > (handle (app (var println) (app (var get)))
  >   (ret (pvar x) (var x))
  >   (opclause get () k (app (var k) (lit 5))))
  > EOF_JQD
  $ jacquard build erasure-grant.jqd -o erasure-grant > /dev/null
  $ jacquard run erasure-grant.jqd --allow console > i.out 2>&1; echo "exit $?"
  exit 2
  $ ./erasure-grant --allow console > n.out 2>&1; echo "exit $?"
  exit 2
  $ diff i.out n.out && echo identical
  identical

The infer stub grant, both prompt shapes; the completion cache stays
interpreter-only until task 73's reader port, loudly:

  $ cat > haiku.jqd <<'EOF_JQD'
  > (app (var complete) (app (var mk-prompt) (lit "write a haiku") (var none)))
  > EOF_JQD
  $ jacquard build haiku.jqd -o haiku > /dev/null
  $ ./haiku --allow infer
  "<stub completion for: write a haiku>"
  $ ./haiku --allow infer --infer-cache cache-dir
  error[E1103]: native binaries do not cache completions yet (the cache entry format needs task 73's reader); rerun without --infer-cache
  [1]

--dry-run is an interpreter run; build rejects it up front:

  $ jacquard build die.jqd -o nope --dry-run
  error[E1103]: jacquard build does not support --dry-run; the consent sheet is an interpreter run (use jacquard run --dry-run)
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

EL.0's dynamic once backstop is tested below the future mode-syntax layer. Both probes capture a
real non-empty continuation, resume it once, then attempt the same captured instance again. The C
probe goes through jq_handle2/jq_perform/jq_dispatch rather than fabricating an empty JQ_RESUME.

  $ SRC="../../runtime/jq_alloc.c ../../runtime/jq_rc.c ../../runtime/jq_text.c ../../runtime/jq_error.c ../../runtime/jq_show.c ../../runtime/jq_utf8.c ../../runtime/jq_rng.c ../../runtime/jq_apply.c ../../runtime/jq_code.c ../../runtime/jq_intrinsics.c ../../runtime/jq_effects.c ../../runtime/jq_frames.c ../../runtime/jq_grants.c ../../runtime/test/test_runtime.c"
  $ $CC -std=c11 -O2 -Wall -Wextra -Werror -o once-native $SRC
  $ ../once_interpreter_probe.exe > once-interpreter.out 2>&1; echo "interpreter exit $?"
  interpreter exit 2
  $ ./once-native once-resume-twice > once-native.out 2>&1; echo "native exit $?"
  native exit 2
  $ diff -u once-interpreter.out once-native.out && echo identical
  identical
  $ cat once-interpreter.out
  error[E0906]: a once continuation may be resumed at most once per captured instance

EL.2 rejects a statically visible duplicate before either engine runs. EL.0's probes above remain
the dynamic backstop for unchecked or host-driven paths, while this declared Once clause names both
source spans at the ordinary check/build boundary.

  $ cat > declared-once.jqd <<'EOF_JQD'
  > (defeffect linear () (op signal once () (tref int)))
  > (handle (app (var signal))
  >   (ret (pvar x) (var x))
  >   (opclause signal () k
  >     (let nonrec (pwild) (app (var k) (lit 1))
  >       (app (var k) (lit 2)))))
  > EOF_JQD
  $ jacquard run declared-once.jqd > declared-run.out 2>&1; echo "run exit $?"
  run exit 1
  $ jacquard build declared-once.jqd -o declared-native > declared-build.out 2>&1; echo "build exit $?"
  build exit 1
  $ diff -u declared-run.out declared-build.out && echo identical
  identical
  $ cat declared-run.out
  declared-once.jqd:6:7-28: error[E0816]: once resumption `k` may be consumed twice on one possible execution path; first consumption at declared-once.jqd:5:25-46, second consumption at declared-once.jqd:6:7-28
    hint: a once resumption may be dropped or moved, but it may be consumed at most once on each possible execution path

A Multi branch outside code that enters a Once handler is legal: each branch enters the handler
afresh and captures its own Once continuation. Moving the Multi perform into the already-captured
Once clause is different: the Multi resumption re-enters that clause with the same Once instance,
so its second branch reaches the E0906 dynamic backstop. Both compositions have interpreter/native
parity.

  $ cat > multi-around-fresh-once.jqd <<'EOF_JQD'
  > (defeffect branching () (op pick () (tref bool)))
  > (defeffect linear () (op ping once () (tref int)))
  > (handle
  >   (let nonrec (pvar b) (app (var pick))
  >     (handle (app (var ping))
  >       (ret (pvar x) (var x))
  >       (opclause ping () k
  >         (app (var k)
  >           (match (var b)
  >             (clause (pcon true) (lit 1))
  >             (clause (pcon false) (lit 2)))))))
  >   (ret (pvar x) (app (var cons) (var x) (var nil)))
  >   (opclause pick () k
  >     (app (var list.append) (app (var k) (var true)) (app (var k) (var false)))))
  > EOF_JQD
  $ jacquard run multi-around-fresh-once.jqd > legal-i.out 2>&1; echo "interpreter exit $?"
  interpreter exit 0
  $ jacquard build multi-around-fresh-once.jqd -o legal-native > /dev/null
  $ ./legal-native > legal-n.out 2>&1; echo "native exit $?"
  native exit 0
  $ diff -u legal-i.out legal-n.out && cat legal-i.out
  cons(1, cons(2, nil))
  $ cat > multi-inside-captured-once.jqd <<'EOF_JQD'
  > (defeffect branching () (op pick () (tref bool)))
  > (defeffect linear () (op ping once () (tref int)))
  > (handle
  >   (handle (app (var ping))
  >     (ret (pvar x) (var x))
  >     (opclause ping () k
  >       (let nonrec (pvar b) (app (var pick))
  >         (app (var k)
  >           (match (var b)
  >             (clause (pcon true) (lit 1))
  >             (clause (pcon false) (lit 2)))))))
  >   (ret (pvar x) (app (var cons) (var x) (var nil)))
  >   (opclause pick () k
  >     (app (var list.append) (app (var k) (var true)) (app (var k) (var false)))))
  > EOF_JQD
  $ jacquard run multi-inside-captured-once.jqd > illegal-i.out 2>&1; echo "interpreter exit $?"
  interpreter exit 2
  $ jacquard build multi-inside-captured-once.jqd -o illegal-native > /dev/null
  $ ./illegal-native > illegal-n.out 2>&1; echo "native exit $?"
  native exit 2
  $ diff -u illegal-i.out illegal-n.out && cat illegal-i.out
  error[E0906]: a once continuation may be resumed at most once per captured instance
EL.3 generates one statically hostile handler for every reviewed Once operation in the shipped
prelude. Each program is a lambda, so polymorphic operation parameters need no fabricated values;
the handler recursively performs the same operation to obtain a correctly typed resume value, then
tries to consume the same resumption twice. Run and native build must reject the identical source at
the shared affine-check boundary with E0816. The low-level pair above separately proves that an
unchecked/host-driven second resume reaches byte-identical E0906 in both runtimes.

  $ ../gen_once_hostile.exe ../../prelude ../../prelude/operation-modes.manifest once-prelude
  generated 14 once-hostile cases from reviewed inventory
  $ passed=0; for f in once-prelude/*.jqd; do
  >   jacquard run "$f" > once-run.out 2>&1; run_status=$?
  >   jacquard build "$f" -o once-prog > once-build.out 2>&1; build_status=$?
  >   if [ "$run_status" = 1 ] && [ "$build_status" = 1 ] &&
  >      diff -q once-run.out once-build.out >/dev/null && grep -q 'error\[E0816\]' once-run.out
  >   then passed=$((passed + 1)); else echo "FAILED: $(basename "$f")"; fi
  > done; echo "$passed/14 generated once-operation cases reject identically"
  14/14 generated once-operation cases reject identically
