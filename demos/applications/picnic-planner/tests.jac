picnic.near?(a, b) = real.lt?(real.abs(real.sub(a, b)), 1e-09)

picnic.rain-probability(
  table,
) =
  picnic.mean(table, fn (world) -> match world {
                                     | PicnicWorld(Rainy, _) -> 1.0
                                     | _ -> 0.0})

picnic.tests =
  Group(
    "picnic planner",
    [
      Case(
        "the prior has the stated rain rate and preserves attendance correlation",
        fn () ->
          {
            let prior = picnic.prior(30)
            check.true(picnic.near?(picnic.mass(prior), 1.0), "prior mass")
            check.true(picnic.near?(picnic.rain-probability(prior), 0.3), "rain rate")
            let rain-and-large =
              picnic.mean(
                prior,
                fn (world) -> match world {
                                | PicnicWorld(Rainy, LargeGroup) -> 1.0
                                | _ -> 0.0},
              )
            check.true(picnic.near?(rain-and-large, 0.075), "P(rain and large) = 0.3 * 0.25")
          },
      ),
      Case(
        "default venue scores match independent arithmetic",
        fn () ->
          {
            let prior = picnic.prior(30)
            check.true(picnic.near?(picnic.expected(Park, prior), 51.855), "park expectation")
            check.true(
              picnic.near?(picnic.expected(Pavilion, prior), 64.52),
              "pavilion expectation",
            )
            check.true(picnic.near?(picnic.expected(Indoors, prior), 53.93), "indoor expectation")
            check.eq(
              picnic.venue-name(picnic.best(prior)),
              "covered pavilion",
              text.eq,
              text.show,
              "default winner",
            )
          },
      ),
      Case(
        "extreme weather assumptions change the preferred venue",
        fn () ->
          {
            check.eq(
              picnic.venue-name(picnic.best(picnic.prior(0))),
              "park",
              text.eq,
              text.show,
              "always dry",
            )
            check.eq(
              picnic.venue-name(picnic.best(picnic.prior(100))),
              "indoors",
              text.eq,
              text.show,
              "always rainy",
            )
          },
      ),
      Case(
        "wet forecast posterior follows Bayes rule",
        fn () ->
          match picnic.posterior(30, 80, WetForecast) {
            | None -> check.true(False, "possible signal disappeared")
            | Some(table) -> {
              check.true(
                picnic.near?(picnic.rain-probability(table), real.div(12.0, 19.0)),
                "0.24 / 0.38",
              )
              check.eq(
                picnic.venue-name(picnic.best(table)),
                "indoors",
                text.eq,
                text.show,
                "wet forecast choice",
              )
            }
          },
      ),
      Case(
        "default forecast has a hand-calculated value of 3.275 points",
        fn () ->
          {
            check.true(
              picnic.near?(picnic.informed-value(30, 80), 67.795),
              "conditional strategy expectation",
            )
            check.true(picnic.near?(picnic.information-value(30, 80), 3.275), "value before price")
            check.true(picnic.buy?(30, 80, 1), "worth a one-point cost")
            check.true(bool.not(picnic.buy?(30, 80, 4)), "not worth four points")
          },
      ),
      Case(
        "perfect forecast bounds the benefit at 13.21 points",
        fn () ->
          check.true(
            picnic.near?(picnic.information-value(30, 100), 13.21),
            "perfect weather information",
          ),
      ),
      Case(
        "impossible perfect-forecast branches are explicit None",
        fn () ->
          {
            match picnic.posterior(0, 100, WetForecast) {
              | None -> check.true(True, "wet forecast impossible")
              | Some(_) -> check.true(False, "impossible posterior normalized")
            }
            match picnic.posterior(100, 100, DryForecast) {
              | None -> check.true(True, "dry forecast impossible")
              | Some(_) -> check.true(False, "impossible posterior normalized")
            }
            check.true(
              picnic.near?(picnic.information-value(0, 100), 0.0),
              "known dry weather gains no information",
            )
            check.true(
              picnic.near?(picnic.information-value(100, 100), 0.0),
              "known wet weather gains no information",
            )
          },
      ),
      Case(
        "invalid inputs are refused by the public advice function",
        fn () ->
          list.each(
            [(-1, 80, 1), (101, 80, 1), (30, 49, 1), (30, 101, 1), (30, 80, -1), (30, 80, 101)],
            fn (
              input,
            ) ->
              match input {
                | (rain, accuracy, cost) ->
                  match picnic.advice(rain, accuracy, cost) {
                    | Err(_) -> check.true(True, "invalid input refused")
                    | Ok(_) -> check.true(False, "invalid input accepted")}
              },
          ),
      ),
      Prop(
        "a coin-flip forecast has zero value and is not purchased on a tie",
        fn () ->
          {
            let rain = sample(UniformInt(0, 100))
            check.true(
              picnic.near?(picnic.information-value(rain, 50), 0.0),
              "uninformative signal",
            )
            check.true(bool.not(picnic.buy?(rain, 50, 0)), "skip on tie")
          },
      ),
      Prop(
        "forecast conditioning normalizes and recovers the prior when averaged",
        fn () ->
          {
            let rain =
              sample(
                Categorical([MkPair(0, 1.0), MkPair(30, 1.0), MkPair(70, 1.0), MkPair(100, 1.0)]),
              )
            let accuracy = sample(Categorical([MkPair(50, 1.0), MkPair(80, 1.0), MkPair(100, 1.0)]))
            let recovered-rain =
              list.fold(
                [DryForecast, WetForecast],
                0.0,
                fn (
                  total,
                  signal,
                ) ->
                  match picnic.posterior(rain, accuracy, signal) {
                    | None -> total
                    | Some(table) ->
                      real.add(
                        total,
                        real.mul(
                          picnic.signal-mass(rain, accuracy, signal),
                          picnic.rain-probability(table),
                        ),
                      )
                  },
              )
            check.true(picnic.near?(recovered-rain, picnic.rate(rain)), "law of total probability")
            list.each(
              [DryForecast, WetForecast],
              fn (
                signal,
              ) ->
                match picnic.posterior(rain, accuracy, signal) {
                  | None ->
                    check.true(
                      picnic.near?(picnic.signal-mass(rain, accuracy, signal), 0.0),
                      "only impossible branches omitted",
                    )
                  | Some(table) ->
                    check.true(picnic.near?(picnic.mass(table), 1.0), "posterior normalized")
                },
            )
          },
      ),
      Prop(
        "information helps by at most the value of a perfect weather forecast",
        fn () ->
          {
            let rain =
              sample(
                Categorical(
                  [
                    MkPair(0, 1.0),
                    MkPair(10, 1.0),
                    MkPair(30, 1.0),
                    MkPair(70, 1.0),
                    MkPair(100, 1.0),
                  ],
                ),
              )
            let accuracy =
              sample(
                Categorical([MkPair(50, 1.0), MkPair(65, 1.0), MkPair(80, 1.0), MkPair(100, 1.0)]),
              )
            let gain = picnic.information-value(rain, accuracy)
            check.true(real.gte?(gain, -1e-09), "can always ignore the signal")
            check.true(
              real.lte?(gain, real.add(picnic.information-value(rain, 100), 1e-09)),
              "perfect information upper bound",
            )
          },
      ),
      Prop(
        "downside is precisely rain risk for the park and zero for covered venues",
        fn () ->
          {
            let rain = sample(UniformInt(0, 100))
            let prior = picnic.prior(rain)
            check.true(
              picnic.near?(picnic.downside(Park, prior), picnic.rate(rain)),
              "park downside",
            )
            check.true(picnic.near?(picnic.downside(Pavilion, prior), 0.0), "pavilion downside")
            check.true(picnic.near?(picnic.downside(Indoors, prior), 0.0), "indoor downside")
          },
      ),
    ],
  )
