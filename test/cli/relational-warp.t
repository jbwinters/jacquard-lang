RW.6 relational Warp cases are a typed, hermetic, result-only layer. This
registered transcript proves all three parameterized heads are discovered and
executed. The VaryWorld pair models a stormglass fleet.serve handler and its
scripted rehearsal twin with the same elaborated row.

  $ export JACQUARD_PRELUDE=$PWD/../../prelude
  $ cat > relational-passing.jac <<'JACQUARD'
  > multi effect Fleet where {
  >   fleet-serve : () -> Int
  > }
  > --
  > fleet-live(body) =
  >   handle body() {
  >     | return value -> value
  >     | fleet-serve() resume continue -> continue(7)
  >   }
  > --
  > fleet-rehearsal(body) =
  >   handle body() {
  >     | return value -> value
  >     | fleet-serve() resume continue -> continue(7)
  >   }
  > --
  > schedule-decl =
  >   SameUnder("schedule-free answer", VarySchedule(3, fn () -> 42))
  > --
  > world-decl =
  >   SameUnder(
  >     "fleet.serve live equals rehearsal",
  >     VaryWorld(fleet-live, fleet-rehearsal, fn () -> fleet-serve()))
  > --
  > value-decl =
  >   SameUnder(
  >     "configuration ignored",
  >     VaryValue(
  >       Categorical([MkPair((1, 2), 1.0)]),
  >       fn (ignored) -> 0))
  > JACQUARD
  $ jacquard check relational-passing.jac --print-sigs
  fleet-live : forall a | e. (() ->{Fleet | e} a) ->{| e} a
  fleet-rehearsal : forall a | e. (() ->{Fleet | e} a) ->{| e} a
  schedule-decl : forall a b. WarpDecl a Int b
  world-decl : forall a. WarpDecl (() ->{Fleet} Int) Int a
  value-decl : forall a. WarpDecl a Int Int
  $ jacquard test relational-passing.jac --seed 73 --no-cache
  PASS schedule-decl/schedule-free answer (same under schedule: 3 runs, seed 73)
  PASS value-decl/configuration ignored (same under value: seed 193801056384563314)
  PASS world-decl/fleet.serve live equals rehearsal (same under world: 2 handlers)
  3 passed, 0 failed, 0 skipped, 0 refused

VarySchedule owns its declared count; the ordinary Case schedule option does
not form a second cross-product.

  $ jacquard test relational-passing.jac --seed 73 --schedules 2 --no-cache | grep schedule-decl
  PASS schedule-decl/schedule-free answer (same under schedule: 3 runs, seed 73)

VaryValue sampling is reproducible from the suite seed. Exhaustive mode uses
the evaluated-call scheduler seam and proves the bounded schedule tree complete.

  $ jacquard test relational-passing.jac --seed 73 --no-cache > reproducible-a.txt
  $ jacquard test relational-passing.jac --seed 73 --no-cache > reproducible-b.txt
  $ diff reproducible-a.txt reproducible-b.txt && echo identical
  identical
  $ jacquard test relational-passing.jac --seed 73 --exhaustive --budget 20 --no-cache
  PASS schedule-decl/schedule-free answer (same under schedule: verified exhaustively (1 world))
  PASS value-decl/configuration ignored (same under value: seed 193801056384563314)
  PASS world-decl/fleet.serve live equals rehearsal (same under world: 2 handlers)
  3 passed, 0 failed, 0 skipped, 0 refused

Relational entries use the ordinary hermetic cache shape. The variation count
and suite/leaf seeds are key material; --no-cache bypasses lookup and storage.

  $ rm -rf relational-cache
  $ jacquard test relational-passing.jac --seed 73 --cache-dir relational-cache | tail -1
  cache: 0 hit, 3 ran
  $ jacquard test relational-passing.jac --seed 73 --cache-dir relational-cache | tail -1
  cache: 3 hit, 0 ran
  $ sed 's/VarySchedule(3/VarySchedule(4/' relational-passing.jac > relational-count.jac
  $ jacquard test relational-count.jac --seed 73 --cache-dir relational-cache | tail -1
  cache: 2 hit, 1 ran
  $ jacquard test relational-passing.jac --seed 74 --cache-dir relational-cache | tail -1
  cache: 0 hit, 3 ran
  $ jacquard test relational-passing.jac --seed 73 --no-cache | tail -1
  3 passed, 0 failed, 0 skipped, 0 refused

Every variation pins a first RW.2 result divergence. The schedule fixture uses
a hermetic cancellation race because structured-concurrency aggregates expose
creation order, never raw completion order.

  $ cat > relational-failing.jac <<'JACQUARD'
  > multi effect Probe where {
  >   probe-read : () -> Int
  > }
  > --
  > probe-live(body) =
  >   handle body() {
  >     | return value -> value
  >     | probe-read() resume continue -> continue(7)
  >   }
  > --
  > probe-different(body) =
  >   handle body() {
  >     | return value -> value
  >     | probe-read() resume continue -> continue(8)
  >   }
  > --
  > schedule-diverges =
  >   SameUnder("schedule race", VarySchedule(12, fn () ->
  >     async.scope(fn () -> {
  >       let victim = async.spawn(fn () -> { async.yield(); 1 })
  >       let canceller = async.spawn(fn () -> { async.cancel(victim); 0 })
  >       (async.await(victim), async.await(canceller))
  >     })))
  > --
  > world-diverges =
  >   SameUnder(
  >     "world difference",
  >     VaryWorld(probe-live, probe-different, fn () -> probe-read()))
  > --
  > value-diverges =
  >   SameUnder(
  >     "value identity",
  >     VaryValue(
  >       Categorical([MkPair((1, 2), 1.0)]),
  >       fn (value) -> value))
  > JACQUARD
  $ jacquard test relational-failing.jac --seed 73 --no-cache > failing-a.txt 2>&1; test $? = 1
  $ jacquard test relational-failing.jac --seed 73 --no-cache > failing-b.txt 2>&1; test $? = 1
  $ diff failing-a.txt failing-b.txt && echo identical
  identical
  $ sed -E 's/seed -?[0-9]+/seed <seed>/g' failing-a.txt
  FAIL schedule-diverges/schedule race (same under schedule: diverged 3/12, seed <seed>)
    ! Runs 1 and 3 diverged with value-divergence:
        at observation[0].value:
          - "done((done(1), done(0)))\n"
          + "cancelled\n"
  FAIL value-diverges/value identity (same under value: diverged, seed <seed>)
    ! Runs 1 and 2 diverged with value-divergence:
        at observation[0].value:
          - "1\n"
          + "2\n"
  FAIL world-diverges/world difference (same under world: diverged)
    ! Runs 1 and 2 diverged with value-divergence:
        at observation[0].value:
          - "7\n"
          + "8\n"
  0 passed, 3 failed, 0 skipped, 0 refused

The identity-guarded VaryWorld rule refuses unequal elaborated body rows before
ordinary open-row unification can merge them. Scheduled thunks retain Case's
ordinary closed-row E0801 behavior for Channel.

  $ cat > relational-row-mismatch.jac <<'JACQUARD'
  > multi effect Probe where {
  >   probe-read : () -> Int
  > }
  > multi effect OtherProbe where {
  >   other-read : () -> Int
  > }
  > probe-handler(body) =
  >   handle body() {
  >     | return value -> value
  >     | probe-read() resume continue -> continue(7)
  >   }
  > other-probe-handler(body) =
  >   handle body() {
  >     | return value -> value
  >     | other-read() resume continue -> continue(7)
  >   }
  > row-mismatch =
  >   SameUnder(
  >     "mismatch",
  >     VaryWorld(probe-handler, other-probe-handler, fn () -> probe-read()))
  > JACQUARD
  $ jacquard check relational-row-mismatch.jac
  relational-row-mismatch.jac:20:5-73: error[E0801]: Types do not agree
    Cause: VaryWorld handlers and subject do not have equal checked thunk rows: left (() ->{probe | e} a) ->{e} a, right (() ->{other-probe | e} a) ->{e} a, subject () ->{probe | e} int
    Next step: Give both VaryWorld handlers the same zero-argument thunk interface and discharge the same fully elaborated effect row.
  [1]
  $ cat > relational-alias-mismatch.jac <<'JACQUARD'
  > world-constructor = VaryWorld
  > --
  > non-thunk-world =
  >   SameUnder(
  >     "not a thunk",
  >     world-constructor(fn (value) -> value, fn (value) -> value, 7))
  > JACQUARD
  $ jacquard check relational-alias-mismatch.jac
  relational-alias-mismatch.jac:6:65-66: error[E0801]: Types do not agree
    Cause: argument: expected a, got int (relational body must be a zero-argument thunk)
    Next step: the expected side comes from the surrounding context; make both sides agree
  [1]
  $ cat > relational-call-subject.jac <<'JACQUARD'
  > invoke-subject(variation) =
  >   match variation {
  >     | VaryWorld(left, right, subject) -> subject()
  >     | _ -> 0
  >   }
  > --
  > answer =
  >   invoke-subject(
  >     VaryWorld(
  >       fn (body) -> body(),
  >       fn (body) -> body(),
  >       fn () -> 7))
  > JACQUARD
  $ jacquard check relational-call-subject.jac --print-sigs
  invoke-subject : forall a b | e. (Variation (() ->{| e} Int) a b) ->{| e} Int
  answer : Int
  $ cat > relational-channel-row.jac <<'JACQUARD'
  > channel-row =
  >   SameUnder(
  >     "channel row cannot close",
  >     VarySchedule(2, fn () -> channel.open(0)))
  > JACQUARD
  $ jacquard check relational-channel-row.jac
  relational-channel-row.jac:4:21-45: error[E0801]: Types do not agree
    Cause: argument: expected () ->{} a, got () ->{channel | e} result channel-error (channel-handle a) (a closed effect row cannot absorb extra effects; a stored definition passed as a thunk can be eta-expanded at the use site: (lam () (app (var f))))
    Next step: the expected side comes from the surrounding context; make both sides agree
  [1]
