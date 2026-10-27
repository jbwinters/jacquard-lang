double(n) = mul(n, 2)

unit-tests =
  Group("arithmetic", [
    Case("double", fn () ->
      check.eq(double(21), 42, int.eq, int.show, "double 21")),

    Prop("doubling is even", fn () -> {
      let n = sample(UniformInt(-100, 100))
      check.eq(mod(double(n), 2), 0, int.eq, int.show, "even")
    })
  ])
