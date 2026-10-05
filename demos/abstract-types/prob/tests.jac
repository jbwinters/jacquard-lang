prob.accepted?(r) = match r { | Ok(_) -> true | Err(_) -> false }

prob.tests =
  Group(
    "probability",
    [
      Case("of-real accepts 0", fn () -> check.true(prob.accepted?(prob.of-real(0.0)), "zero")),
      Case("of-real accepts 1", fn () -> check.true(prob.accepted?(prob.of-real(1.0)), "one")),
      Case("of-real rejects below 0", fn () -> check.true(bool.not(prob.accepted?(prob.of-real(-0.1))), "negative")),
      Case("of-real rejects above 1", fn () -> check.true(bool.not(prob.accepted?(prob.of-real(1.5))), "above one")),
      Case("of-real rejects NaN", fn () -> check.true(bool.not(prob.accepted?(prob.of-real(real.div(0.0, 0.0)))), "nan")),
      Case(
        "complement and both stay in range",
        fn () ->
          match prob.of-real(0.25) {
            | Ok(p) ->
                check.true(
                  real.between?(prob.value(prob.both(p, prob.complement(p))), 0.0, 1.0),
                  "closed operations")
            | Err(message) -> check.true(false, message)
          })
    ])
