-- Warp checks for the release-risk case study. This file is assembled after
-- model.jac's declarations by run.sh.

decision-same?(a, b) =
  match (a, b) {
    | (Ship, Ship) -> True
    | (Canary(x), Canary(y)) -> eq(x, y)
    | (Hold(x), Hold(y)) -> eq.fn(text.eq)(x, y)
    | _ -> False
  }

decision.show(d) =
  match d {
    | Ship -> "ship"
    | Canary(percent) -> text.concat("canary ", text.from-int(percent))
    | Hold(reason) -> text.concat("hold ", reason)
  }

decision.eq = MkEq(decision-same?)
decision.showing = MkShow(decision.show)

posterior-mass(table) =
  list.fold(table, 0.0, fn (total, entry) ->
    match entry {
      | MkPair(_, probability) -> real.add(total, probability)
    })

health-world() =
  Categorical([
    MkPair(Healthy, 1.0),
    MkPair(Degraded, 1.0),
    MkPair(Down, 1.0)
  ])

release-risk-suite =
  Group("release risk", [
    Case("the concrete snapshot chooses a five-percent canary", fn () ->
      match current-snapshot() {
        | Assessment(Healthy, Degraded, False, decision) ->
            check.eq(
              decision,
              Canary(5),
              decision.eq,
              decision.showing,
              "snapshot decision")
        | _ -> check.true(False, "unexpected snapshot")
      }),

    Case("the conditioned posterior is normalized with five decisions", fn () -> {
      let posterior =
        dist.enumerate(fn () -> conditioned-release-risk())
        |> dist.tally(decision.eq)
      check.eq(list.length(posterior), 5, int.eq, int.show, "support size")
      check.true(
        real.lt?(real.abs(real.sub(posterior-mass(posterior), 1.0)), 0.000000001),
        "posterior mass is one")
    }),

    Prop("a down service is never approved to ship", fn () -> {
      let inventory = sample(health-world())
      let payments = sample(health-world())
      let spike = sample(Bernoulli(0.5))
      let decision = decide(inventory, payments, spike)
      match (inventory, payments, decision) {
        | (Down, _, Ship) -> check.true(False, "inventory was down")
        | (_, Down, Ship) -> check.true(False, "payments were down")
        | _ -> check.true(True, "safe release decision")
      }
    })
  ])
