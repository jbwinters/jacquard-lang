dice.near?(a, b) = real.lt?(real.abs(real.sub(a, b)), 1e-09)

dice.tests =
  Group(
    "dice coach",
    [
      Case(
        "zero rolls banks the existing pot without bust risk",
        fn () ->
          {
            let table = dice.distribution(Bold, 17, 0)
            check.true(dice.near?(dice.expected(table), 17.0), "banked score")
            check.true(dice.near?(dice.bust-risk(table), 0.0), "no roll, no bust")
            check.eq(list.length(table), 1, int.eq, int.show, "one outcome")
          },
      ),
      Case(
        "one forced roll has six outcomes and one-sixth bust risk",
        fn () ->
          {
            let table = dice.distribution(Bold, 10, 1)
            check.eq(list.length(table), 6, int.eq, int.show, "five scores plus bust")
            check.true(
              dice.near?(dice.expected(table), real.div(70.0, 6.0)),
              "hand-calculated expectation",
            )
            check.true(dice.near?(dice.bust-risk(table), real.div(1.0, 6.0)), "one bust face")
          },
      ),
      Case(
        "bank wins the exact tie at twenty",
        fn () ->
          {
            check.eq(
              dice.action-name(dice.choose(Optimal, 19, 1)),
              "ROLL",
              text.eq,
              text.show,
              "below threshold",
            )
            check.eq(
              dice.action-name(dice.choose(Optimal, 20, 3)),
              "BANK",
              text.eq,
              text.show,
              "tie",
            )
            check.eq(
              dice.action-name(dice.choose(Optimal, 21, 3)),
              "BANK",
              text.eq,
              text.show,
              "above threshold",
            )
          },
      ),
      Case(
        "three compulsory surviving rolls have 125 out of 216 non-bust paths",
        fn () ->
          {
            let table = dice.distribution(Bold, 0, 3)
            check.true(
              dice.near?(dice.bust-risk(table), real.div(91.0, 216.0)),
              "analytic survival probability",
            )
            check.true(
              dice.near?(dice.expected(table), real.div(1500.0, 216.0)),
              "survival times conditional mean score",
            )
          },
      ),
      Case(
        "public advice refuses negative and unbounded inputs",
        fn () ->
          list.each(
            [(-1, 2), (61, 2), (10, -1), (10, 4)],
            fn (
              input,
            ) ->
              match input {
                | (pot, rolls) ->
                  match dice.advice(pot, rolls) {
                    | Err(_) -> check.true(True, "invalid input refused")
                    | Ok(_) -> check.true(False, "invalid input accepted")}
              },
          ),
      ),
      Prop(
        "one-roll advice agrees with the independent closed-form threshold",
        fn () ->
          {
            let pot = sample(UniformInt(0, 40))
            let expected = if int.lt?(pot, 20) then "ROLL" else "BANK"
            check.eq(
              dice.action-name(dice.choose(Optimal, pot, 1)),
              expected,
              text.eq,
              text.show,
              "threshold twenty",
            )
          },
      ),
      Prop(
        "exact policy distributions normalize and obey score bounds",
        fn () ->
          {
            let policy =
              sample(Categorical([MkPair(Cautious, 1.0), MkPair(Bold, 1.0), MkPair(Optimal, 1.0)]))
            let pot =
              sample(
                Categorical([MkPair(0, 1.0), MkPair(10, 1.0), MkPair(20, 1.0), MkPair(30, 1.0)]),
              )
            let rolls = sample(UniformInt(0, 2))
            let table = dice.distribution(policy, pot, rolls)
            check.true(dice.near?(dice.mass(table), 1.0), "normalized")
            list.each(
              table,
              fn (
                entry,
              ) ->
                match entry {
                  | MkPair(outcome, probability) -> {
                    check.true(
                      bool.and(real.gte?(probability, 0.0), real.lte?(probability, 1.0)),
                      "valid probability",
                    )
                    match outcome {
                      | Busted -> check.true(True, "bust is permitted")
                      | Banked(points) ->
                        check.true(
                          bool.and(
                            int.gte?(points, pot),
                            int.lte?(points, add(pot, mul(6, rolls))),
                          ),
                          "reachable score",
                        )
                    }
                  }
                },
            )
          },
      ),
      Prop(
        "enumerated optimal play realizes the Bellman value and dominates both fixed policies",
        fn () ->
          {
            let pot =
              sample(
                Categorical([MkPair(0, 1.0), MkPair(12, 1.0), MkPair(19, 1.0), MkPair(24, 1.0)]),
              )
            let rolls = sample(UniformInt(0, 3))
            let best-value = dice.expected(dice.distribution(Optimal, pot, rolls))
            check.true(
              dice.near?(best-value, dice.optimal-value(pot, rolls)),
              "model agrees with recurrence",
            )
            list.each(
              [Cautious, Bold],
              fn (
                policy,
              ) ->
                check.true(
                  real.gte?(
                    real.add(best-value, 1e-09),
                    dice.expected(dice.distribution(policy, pot, rolls)),
                  ),
                  "optimal dominates fixed strategy",
                ),
            )
          },
      ),
    ],
  )
