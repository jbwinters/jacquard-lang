nel.tests =
  Group(
    "non-empty list",
    [
      Case(
        "of-list refuses the empty list",
        fn () -> check.true(match nel.of-list([]) { | None -> true | Some(_) -> false }, "empty")),
      Case(
        "of-list keeps every element",
        fn () ->
          match nel.of-list([1, 2, 3]) {
            | Some(n) -> check.eq(list.length(nel.to-list(n)), 3, int.eq, int.show, "round trip")
            | None -> check.true(false, "a non-empty list was refused")
          }),
      Case("head of a singleton", fn () -> check.eq(nel.head(nel.singleton(7)), 7, int.eq, int.show, "head")),
      Case(
        "map keeps the head",
        fn () ->
          check.eq(nel.head(nel.map(nel.singleton(2), fn (x) -> int.mul(x, 10))), 20, int.eq, int.show, "map"))
    ])
