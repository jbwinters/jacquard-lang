nb.formula-value(
  source,
) =
  match nb.parse(source) {
    | NbBadFormula(e) -> nb.diagnostic-text(e)
    | NbFormula(expr) -> nb.value-text(nb.fresh(expr, [], "formula"))
  }

nb.parser-tests =
  Group(
    "formula syntax and arithmetic",
    [
      Case(
        "precedence, associativity, unary minus, and checked arithmetic",
        fn () ->
          list.each(
            [
              ("2 + 3 * 4", "14"),
              ("(2 + 3) * 4", "20"),
              ("20 - 5 - 3", "12"),
              ("24 / 4 / 2", "3"),
              ("-7 / 3", "-2"),
              ("7 / -3", "-2"),
              ("--4 * -(2+1)", "-12"),
              ("1000000", "1000000"),
              ("-1000000", "-1000000"),
              ("1000000 * 1000000", "ERROR [formula]: result outside -1000000..1000000"),
              ("1 / 0", "ERROR [formula]: division by zero"),
              ("missing + 1", "ERROR [missing]: undefined cell"),
            ],
            fn (
              example,
            ) ->
              {
                let (source, expected) = example
                check.eq(nb.formula-value(source), expected, text.eq, text.show, source)
              },
          ),
      ),
      Case(
        "diagnostics locate malformed and excessive input",
        fn () ->
          {
            list.each(
              [
                ("", "column 1:"),
                ("1 +", "column 4:"),
                ("1 2", "column 3:"),
                ("(1 + 2", "column 7:"),
                ("1 @ 2", "column 3:"),
                ("1 + )", "column 5:"),
                ("1000001", "column 1:"),
                ("123456789012345678901234567890", "column 1:"),
                ("abc______________________", "column 1:"),
                ("é", "column 1:"),
              ],
              fn (
                example,
              ) ->
                {
                  let (source, expected) = example
                  check.true(text.contains?(nb.formula-value(source), expected), source)
                },
            )
            let excessive = nb.join(list.map(list.range(0, 101), fn (_) -> "-"), "")
            check.true(
              text.contains?(nb.formula-value(text.concat(excessive, "1")), "100 tokens"),
              "token limit",
            )
          },
      ),
      Case(
        "exact token, text, name, and arithmetic boundaries",
        fn () ->
          {
            let negations = nb.join(list.map(list.range(0, 99), fn (_) -> "-"), "")
            check.eq(
              nb.formula-value(text.concat(negations, "1")),
              "-1",
              text.eq,
              text.show,
              "exactly 100 tokens",
            )
            let padding = nb.join(list.map(list.range(0, 4095), fn (_) -> " "), "")
            check.eq(
              nb.formula-value(text.concat(padding, "1")),
              "1",
              text.eq,
              text.show,
              "exactly 4096 characters",
            )
            check.true(
              text.contains?(nb.formula-value(text.concat(padding, "12")), "4096 characters"),
              "text limit",
            )
            check.true(nb.valid-name?("abcdefghijklmnopqrstuvwx"), "24-character name")
            check.true(bool.not(nb.valid-name?("abcdefghijklmnopqrstuvwxy")), "25-character name")
            list.each(
              [
                "1000000 + 1",
                "-1000000 - 1",
                "1000000 * 1000000",
                "-1000000 * 1000000",
                "1000000 + 1 - 1",
              ],
              fn (
                source,
              ) ->
                check.true(text.contains?(nb.formula-value(source), "outside"), source),
            )
            check.eq(
              nb.formula-value("1000000 / -1"),
              "-1000000",
              text.eq,
              text.show,
              "negative boundary",
            )
          },
      ),
    ],
  )
