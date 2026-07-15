SC.9 runs only the explicit FIFO queue. Repeated processes and an in-process
cache hit retain the exact event bytes.

  $ export JACQUARD_PRELUDE=$PWD/../../prelude

  $ ../round_robin_trace.exe > expected.out
  $ i=0; while test "$i" -lt 128; do ../round_robin_trace.exe > actual.out; cmp expected.out actual.out || exit 1; i=$((i + 1)); done
  $ cat expected.out
  decision=0 runnable=[0#0] chosen=0#0
  spawn parent=0#0 child=0#1
  decision=1 runnable=[0#1,0#0] chosen=0#1
  yield task=0#1
  decision=2 runnable=[0#0,0#1] chosen=0#0
  await waiter=0#0 target=0#1 blocked
  decision=3 runnable=[0#1] chosen=0#1
  yield task=0#1
  decision=4 runnable=[0#1] chosen=0#1
  terminal task=0#1 result=done(10)
  policy-observe decision=4 ordinal=0 task=0#1
  decision=5 runnable=[0#0] chosen=0#0
  terminal task=0#0 result=done(done(10))
  cache=miss,hit identical=true tasks=2 max-live=2 zero=true

Nested scopes join the same FIFO and accounting domain. The already-runnable
outer sibling runs before the nested body, and the cumulative task/live counts
include both scope paths.

  $ ../round_robin_trace.exe nested
  decision=0 runnable=[0#0] chosen=0#0
  spawn parent=0#0 child=0#1
  decision=1 runnable=[0#1,0#0] chosen=0#1
  yield task=0#1
  decision=2 runnable=[0#0,0#1] chosen=0#0
  scope-open parent=0 child=0/1
  decision=3 runnable=[0#1,0/1#0] chosen=0#1
  terminal task=0#1 result=done(9)
  policy-observe decision=3 ordinal=0 task=0#1
  decision=4 runnable=[0/1#0] chosen=0/1#0
  yield task=0/1#0
  decision=5 runnable=[0/1#0] chosen=0/1#0
  terminal task=0/1#0 result=done(42)
  scope-complete path=0/1 result=done(42)
  decision=6 runnable=[0#0] chosen=0#0
  terminal task=0#0 result=done(done(42))
  cache=miss,hit identical=true tasks=3 max-live=3 zero=true

The default interpreter path runs the frozen four Async operations with real
Eval continuations. Multiple waiters observe one immutable terminal result,
and the trusted scope term opens a nested scope without changing Async's hash.

  $ cat > waiters.jqd <<'EOF_JQD'
  > (let nonrec (pvar target)
  >   (app (var async.spawn)
  >     (lam () (let nonrec (pwild) (app (var async.yield)) (lit 7))))
  >   (let nonrec (pvar left)
  >     (app (var async.spawn) (lam () (app (var async.await) (var target))))
  >     (let nonrec (pvar right)
  >       (app (var async.spawn) (lam () (app (var async.await) (var target))))
  >       (tuple (app (var async.await) (var left))
  >         (app (var async.await) (var right))))))
  > EOF_JQD
  $ jacquard run waiters.jqd
  (done(done(7)), done(done(7)))

  $ cat > nested.jqd <<'EOF_JQD'
  > (app (var async.scope)
  >   (lam ()
  >     (let nonrec (pvar child) (app (var async.spawn) (lam () (lit 42)))
  >       (app (var async.await) (var child)))))
  > EOF_JQD
  $ jacquard run nested.jqd
  done(done(42))

Task values still cannot cross the scope boundary.

  $ cat > escape.jqd <<'EOF_JQD'
  > (app (var async.spawn) (lam () (lit 1)))
  > EOF_JQD
  $ jacquard run escape.jqd 2>&1
  error[E0907]: a Task may not escape, outlive, or be used outside the structured scope that created it: Task 0#1 escaped its creating structured scope
  [2]

Warp's Case lane reaches the same scheduler through `async.scope`; the Case
itself retains its closed Check-only row.

  $ cat > async-warp.jqd <<'EOF_JQD'
  > (defterm ((binding async-case ()
  >   (app (var case) (lit "runs a nested Async lifecycle")
  >     (lam ()
  >       (match
  >         (app (var async.scope)
  >           (lam ()
  >             (let nonrec (pvar child) (app (var async.spawn) (lam () (lit 42)))
  >               (app (var async.await) (var child)))))
  >         (clause (pcon done (pcon done (pvar value)))
  >           (app (var check.eq) (var value) (lit 42) (var int.eq) (var int.show)
  >             (lit "nested result")))
  >         (clause (pwild)
  >           (app (var check.true) (var false) (lit "nested result")))))))))
  > (defterm ((binding async-cancel-case ()
  >   (app (var case) (lit "cancels a yielded child")
  >     (lam ()
  >       (match
  >         (app (var async.scope)
  >           (lam ()
  >             (let nonrec (pvar child)
  >               (app (var async.spawn)
  >                 (lam ()
  >                   (let nonrec (pwild) (app (var async.yield))
  >                     (let nonrec (pwild) (app (var async.yield)) (lit 99)))))
  >               (let nonrec (pwild) (app (var async.cancel) (var child))
  >                 (app (var async.await) (var child))))))
  >         (clause (pcon cancelled)
  >           (app (var check.true) (var true) (lit "cancelled result")))
  >         (clause (pwild)
  >           (app (var check.true) (var false) (lit "cancelled result")))))))))
  > EOF_JQD
  $ jacquard test async-warp.jqd --no-cache
  PASS async-cancel-case/cancels a yielded child (1 check)
  PASS async-case/runs a nested Async lifecycle (1 check)
  2 passed, 0 failed, 0 skipped, 0 refused

The surface lane pins the rest of the checker-representable hostile matrix:
yield resumes once, fail-fast exposes a cancelled child as the scope result,
and a granted world case proves cancellation preempts the routed Console
callback.

  $ cat > async-warp-matrix.jac <<'EOF_JAC'
  > async-yield-case =
  >   Case("resumes after yield", fn () ->
  >     match async.scope(fn () -> { async.yield(); 8 }) {
  >       | Done(value) -> check.eq(value, 8, int.eq, int.show, "yield result")
  >       | _ -> check.true(false, "yield result")
  >     })
  > async-fail-fast-case =
  >   Case("selects cancelled child", fn () -> {
  >     let result = async.scope(fn () -> {
  >       let child = async.spawn(fn () -> { async.yield(); async.yield(); 99 })
  >       async.cancel(child)
  >       0
  >     })
  >     match result {
  >       | Cancelled -> check.true(true, "fail-fast cancellation")
  >       | _ -> check.true(false, "fail-fast cancellation")
  >     }})
  > async-routed-cancel =
  >   wcase("preempts routed console", fn () -> {
  >     let result = async.scope(fn () -> {
  >       let child = async.spawn(fn () -> { async.yield(); print("must-not-run") })
  >       async.cancel(child)
  >       0
  >     })
  >     match result {
  >       | Cancelled -> check.true(true, "routed cancellation")
  >       | _ -> check.true(false, "routed cancellation")
  >     }})
  > EOF_JAC
  $ jacquard test async-warp-matrix.jac --no-cache --allow console --allow fs --allow net --allow clock > matrix.out
  $ grep -c must-not-run matrix.out
  0
  [1]
  $ cat matrix.out
  PASS async-fail-fast-case/selects cancelled child (1 check)
  PASS async-routed-cancel/preempts routed console (1 check)
  PASS async-yield-case/resumes after yield (1 check)
  3 passed, 0 failed, 0 skipped, 0 refused

Child effects cannot be laundered through the closed Case row. This is the Warp
checker-side refusal cell; the diagnostic retains the spawned child's `Net`
authority after `async.scope` removes only `Async`.

  $ cat > async-child-row.jac <<'EOF_JAC'
  > async-child-row =
  >   Case("cannot hide net", fn () ->
  >     match async.scope(fn () -> {
  >       let child = async.spawn(fn () -> net.get("https://example.invalid"))
  >       check.true(true, "child row")
  >     }) {
  >       | Done(result) -> result
  >       | _ -> check.true(false, "child row")
  >     })
  > EOF_JAC
  $ jacquard check async-child-row.jac --manifest console
  async-child-row.jac:2:27-9:6: error[E0801]: argument: expected () ->{check} (), got () ->{net, check | e} () (a closed effect row cannot absorb extra effects; a stored definition passed as a thunk can be eta-expanded at the use site: (lam () (app (var f))))
    hint: the expected side comes from the surrounding context; make both sides agree
  [1]

The native backend has no root scheduler. It supports Async only when the
effect is discharged by an in-language handler; this parity check is explicitly
that narrower seam, not native scheduler support.

  $ export JACQUARD_RUNTIME=../../runtime
  $ export CC=clang
  $ cat > handled-yield.jqd <<'EOF_JQD'
  > (handle (app (var async.yield))
  >   (ret (pvar x) (var x))
  >   (opclause async.yield () k (app (var k) (tuple))))
  > EOF_JQD
  $ jacquard run handled-yield.jqd > interpreter.out 2>&1
  $ jacquard build handled-yield.jqd -o handled-yield > /dev/null
  $ ./handled-yield > native.out 2>&1
  $ diff interpreter.out native.out && cat native.out
  ()
