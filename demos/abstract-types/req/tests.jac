req.refused?(r) = match r { | Ok(_) -> false | Err(_) -> true }

req.tests =
  Group(
    "validated request",
    [
      Case("blank name refused", fn () -> check.true(req.refused?(req.validate("  ", "a@b", 30)), "blank")),
      Case("email without @ refused", fn () -> check.true(req.refused?(req.validate("Ada", "ada", 30)), "email")),
      Case("age below 13 refused", fn () -> check.true(req.refused?(req.validate("Ada", "a@b", 12)), "young")),
      Case(
        "valid request keeps its trimmed fields",
        fn () ->
          match req.validate(" Ada ", "ada@example.org", 36) {
            | Ok(r) -> check.true(bool.and(text.eq?(req.name(r), "Ada"), int.between?(req.age(r), 36, 36)), "fields")
            | Err(why) -> check.true(false, req.reason(why))
          })
    ])
