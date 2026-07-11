docs-test : Test
docs-test = Case("documentation example", fn () ->
  check.true(True, "surface doctest"))
