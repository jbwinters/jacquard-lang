req.refused?(r) = match r { | Ok(_) -> false | Err(_) -> true }

req.tests =
  Group(
    "validated request",
    [
      Case("blank name refused", fn () -> check.true(req.refused?(req.validate("  ", "a@b", 30)), "blank")),
      Case("email without @ refused", fn () -> check.true(req.refused?(req.validate("Ada", "ada", 30)), "email")),
      Case("age below 13 refused", fn () -> check.true(req.refused?(req.validate("Ada", "a@b", 12)), "young")),
      Case("age above 130 refused", fn () -> check.true(req.refused?(req.validate("Ada", "a@b", 131)), "old")),
      Case(
        "ages 13 and 130 accepted",
        fn () ->
          check.true(
            bool.and(
              bool.not(req.refused?(req.validate("Ada", "a@b", 13))),
              bool.not(req.refused?(req.validate("Ada", "a@b", 130)))),
            "bounds")),
      Case(
        "valid request keeps its trimmed fields",
        fn () ->
          match req.validate(" Ada ", "ada@example.org", 36) {
            | Ok(r) ->
                {
                  check.eq(req.name(r), "Ada", text.eq, text.show, "trimmed name")
                  check.eq(req.email(r), "ada@example.org", text.eq, text.show, "email")
                  check.eq(req.age(r), 36, int.eq, int.show, "age")
                }
            | Err(why) -> check.true(false, req.reason(why))
          })
    ])
