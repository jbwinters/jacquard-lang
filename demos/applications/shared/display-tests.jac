display.tests =
  Group(
    "numeric presentation",
    [
      Case(
        "round to three decimals, carry, pad, and suppress negative zero",
        fn () ->
          {
            list.each(
              [
                (0.0, "0.000"),
                (1.9999, "2.000"),
                (-17.235000000000003, "-17.235"),
                (-1e-14, "0.000"),
                (100.0, "100.000"),
                (0.16666666666666666, "0.167"),
                (0.005, "0.005"),
                (0.05, "0.050"),
                (1000.0, "1000.000"),
                (-1000.0, "-1000.000"),
              ],
              fn (
                example,
              ) ->
                match example {
                  | (value, expected) ->
                    check.eq(display.fixed3(value), expected, text.eq, text.show, "formatted value")
                },
            )
            check.eq(
              display.percent(real.div(1.0, 6.0)),
              "16.667%",
              text.eq,
              text.show,
              "probability percentage",
            )
          },
      ),
    ],
  )
