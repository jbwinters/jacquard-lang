-- Warp suite for stormglass. Every case is hermetic BY TYPE: the simulator
-- discharges Net/Clock/State in-language, enumeration discharges Dist, so the
-- bodies close at {Check} and the props at {Dist, Check}. This file expects
-- model.jac's definitions. Under --exhaustive the props are PROOFS over
-- all 27 possible worlds.

stormglass-suite =
  Group("stormglass", [

    -- a pinned sunny day: exact simulated milliseconds and call counts
    Case("sunny day is deterministic to the millisecond", fn () ->
      match simulate(MkFleet(Up, Up, Up), fn () -> resilient-checkout()) {
        | (_, (ms, n)) -> {
            check.eq(ms, 60, int.eq, int.show, "elapsed simulated ms")
            check.eq(n, 3, int.eq, int.show, "fetches made")
          }
      }),

    -- the differentiating world: shipping hard-down
    Case("shipping outage: resilient ships anyway, naive gives up", fn () -> {
      let f = MkFleet(Up, Up, Down)
      check.eq(
        outcome.text(run-graded(f, fn () -> naive-checkout())),
        "blackout", text.eq, text.show, "naive")
      check.eq(
        outcome.text(run-graded(f, fn () -> resilient-checkout())),
        "choppy", text.eq, text.show, "resilient")
    }),

    -- a unit test asserting an EXACT probabilistic dominance claim:
    -- enumeration is pure, so a {Check} case may compute whole posteriors
    Case("resilient strictly beats naive on blackout mass", fn () -> {
      let naive-mass = mass-of(tally-policy(fn () -> naive-checkout()), "blackout")
      let resilient-mass = mass-of(tally-policy(fn () -> resilient-checkout()), "blackout")
      check.true(
        real.lt?(resilient-mass, naive-mass),
        "P(blackout | resilient) < P(blackout | naive)")
    }),

    -- the generator IS the weather model; --exhaustive proves it
    Prop("no world drives resilient past its fetch budget", fn () ->
      match simulate(forecast(), fn () -> resilient-checkout()) {
        | (_, (_, n)) ->
            check.true(bool.not(int.lt?(5, n)), "at most 5 calls in any weather")
      }),

    Prop("payment down is never sold as a clear day", fn () -> {
      let f = forecast()
      let out = outcome.text(run-graded(f, fn () -> resilient-checkout()))
      match f {
        | MkFleet(_, Down, _) ->
            check.true(bool.not(eq.fn(text.eq)(out, "clear")), "no false clear")
        | _ -> check.true(True, "payment was not down")
      }
    })

  ])
