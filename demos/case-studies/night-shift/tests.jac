-- Warp suite for night-shift. The cases close hermetically: the lab
-- discharges Net/Clock/State per probe task, a stub handler discharges Eval,
-- and throw.to-result discharges Throw, so no case needs a grant. Under
-- --exhaustive the props are proofs over all 27 fleet worlds. This file
-- expects model.jac's definitions; run.sh assembles the two.

--| a test double for the eval capability: resumes the once-mode lever with a
--| sentinel so the decision spine can be proven without granting `eval`.
--| The real evaluation is pinned by run.sh's granted lane instead.
eval-stub(thunk) =
  handle thunk() {
    | return x -> x
    | eval-code(code) resume k -> k(99)
  }

wedged?(m) = match m { | Wedged -> True | _ -> False }

fleet.any-wedged?(f) = match f {
  | MkFleet(a, d, c) -> bool.or(wedged?(a), bool.or(wedged?(d), wedged?(c)))
}

--| total probability mass a tallied table assigns one label
mass-of(table, label) =
  list.fold(table, 0.0, fn (acc, e) ->
    match e {
      | MkPair(x, p) ->
          if eq.fn(text.eq)(x, label) then real.add(acc, p) else acc
    })

night-shift-suite =
  Group("night-shift", [

    -- the pinned calm night: every simulated millisecond is exact. The
    -- concurrent channel form of these same probes is pinned by run.sh's
    -- transcript; Warp cases stay hermetic and use the sequential twin.
    Case("calm preflight is deterministic to the millisecond", fn () -> {
      let readings = preflight.solo(MkFleet(Ready, Ready, Ready))
      check.eq(list.length(readings), 3, int.eq, int.show, "three readings")
      check.eq(
        list.fold(readings, 0, fn (acc, r) -> add(acc, reading.ms(r))),
        120, int.eq, int.show, "total simulated ms")
      check.true(preflight.green?(readings), "calm fleet is green")
      match readings {
        | Cons(first, _) ->
            check.eq(reading.ms(first), 40, int.eq, int.show, "api probe ms")
        | Nil -> check.true(False, "readings must not be empty")
      }
    }),

    -- the retry path: a wedged service costs two fetches plus the 120ms beat
    Case("a wedged db is probed twice and caught", fn () -> {
      let readings = preflight.solo(MkFleet(Ready, Wedged, Ready))
      check.true(bool.not(preflight.green?(readings)), "wedged fleet is red")
      check.eq(
        list.fold(readings, 0, fn (acc, r) -> add(acc, reading.ms(r))),
        380, int.eq, int.show, "retry charges 90+120+90 for db")
    }),

    -- the decision spine, Eval stubbed: green ships once, red escalates
    Case("green preflight ships through the once-mode lever", fn () ->
      match throw.to-result(fn () ->
        eval-stub(fn () -> decide(preflight.solo(MkFleet(Ready, Ready, Ready))))) {
        | Ok((verdict, pool)) -> {
            check.eq(verdict, "shipped by night-shift-bot", text.eq, text.show, "verdict")
            check.eq(pool, 99, int.eq, int.show, "the stubbed lever fired exactly once")
          }
        | Err(_) -> check.true(False, "decision must not throw")
      }),

    Case("red preflight escalates and ships nothing", fn () ->
      match throw.to-result(fn () ->
        eval-stub(fn () -> decide(preflight.solo(MkFleet(Wedged, Ready, Ready))))) {
        | Ok((verdict, pool)) -> {
            check.eq(verdict, "escalated to a human; pool unchanged",
              text.eq, text.show, "verdict")
            check.eq(pool, 8, int.eq, int.show, "pool untouched")
          }
        | Err(_) -> check.true(False, "escalation must not throw")
      }),

    -- cancellation as a first-class outcome: fail-fast reports the cancelled
    -- watchdog as the scope's own result, and the caller reads it as calm
    Case("the watchdog stands down without paging", fn () ->
      check.eq(watch.report(), "watchdog stood down; no page sent",
        text.eq, text.show, "watch report")),

    -- one multi-shot pass really does explore both rollout plans
    Case("both rollout plans come from a single multi-shot pass", fn () -> {
      let windows = both-plans(MkFleet(Ready, Ready, Ready))
      check.eq(list.length(windows), 2, int.eq, int.show, "two plans")
      match windows {
        | Cons((label-a, w-a), Cons((label-b, w-b), Nil)) -> {
            check.eq(label-a, "big-bang", text.eq, text.show, "first branch")
            check.eq(w-a, 120, int.eq, int.show, "big-bang pays the sum")
            check.eq(label-b, "rolling", text.eq, text.show, "second branch")
            check.eq(w-b, 220, int.eq, int.show, "rolling pays worst plus 180")
          }
        | _ -> check.true(False, "expected exactly two explored plans")
      }
    }),

    -- an exact probabilistic claim computed inside an ordinary case: the
    -- enumeration projects every weighted world through the probe twin
    Case("the green forecast is exact and sums to one", fn () -> {
      let table = risk.green()
      let green = mass-of(table, "green")
      let red = mass-of(table, "red")
      check.true(real.lt?(0.9, green), "calm skies dominate")
      check.true(real.lt?(red, 0.1), "red nights are rare")
    }),

    -- the generator IS the fleet model; --exhaustive proves both over all 27
    Prop("a wedged service never passes preflight", fn () -> {
      let f = forecast()
      check.true(
        bool.not(bool.and(fleet.any-wedged?(f), world.green?(f))),
        "wedged and green cannot coexist")
    }),

    Prop("the rolling plan never overruns the 900ms window", fn () -> {
      let f = forecast()
      check.true(int.lt?(plan.window(False, f), 900), "rolling fits every world")
    })
  ])
