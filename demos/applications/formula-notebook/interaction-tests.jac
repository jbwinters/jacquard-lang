-- Exercise the actual Console loop with deterministic input and captured output.
nb.capture(
  thunk,
  inputs,
) =
  {
    let (_, (_, messages)) =
      state.run(
        fn () ->
          handle thunk() {
            | return result -> result
            | print(
              message,
            ) resume k ->
              {
                let (remaining, output) = get()
                put((remaining, Cons(message, output)))
                k(())
              }
            | read-line() resume k ->
              {
                let (remaining, output) = get()
                match remaining {
                  | Cons(line, more) -> {
                    put((more, output))
                    k(line)
                  }
                  | Nil -> k("")
                }
              }
          },
        (inputs, Nil),
      )
    nb.join(list.reverse(messages), "")
  }

nb.interaction-tests =
  Group(
    "interactive notebook",
    [
      Case(
        "actual loop supports editing, preview, history, and dependency explanations",
        fn () ->
          {
            let output =
              nb.capture(
                nb.main,
                [
                  "set a = 2",
                  "set b = a * 3",
                  "whatif a = 7",
                  "show b",
                  "set a = 4",
                  "undo",
                  "redo",
                  "why b",
                  "quit",
                  "set NEVER = 1",
                ],
              )
            list.each(
              [
                "preview (live state unchanged)",
                "b: 6 -> 21",
                "b = 6    [a * 3]",
                "b: 12 -> 6",
                "b: 6 -> 12",
                "direct dependencies: a",
                "a = 4",
                "bye",
              ],
              fn (expected) -> check.true(text.contains?(output, expected), expected),
            )
            check.true(bool.not(text.contains?(output, "NEVER")), "quit stops consuming commands")
          },
      ),
      Case(
        "errors recover and EOF exits cleanly",
        fn () ->
          {
            let output =
              nb.capture(
                nb.main,
                [
                  "set result = missing + 2",
                  "show result",
                  "set missing = 4",
                  "set missing = result",
                  "set missing = (",
                  "nonsense",
                  "show result",
                ],
              )
            list.each(
              [
                "ERROR [missing]: undefined cell",
                "result: ERROR [missing]: undefined cell -> 6",
                "cycle: missing -> result -> missing",
                "column 2:",
                "unknown command",
                "result = 6",
                "bye (empty input or EOF)",
              ],
              fn (expected) -> check.true(text.contains?(output, expected), expected),
            )
          },
      ),
      Case(
        "help, whitespace, empty workbook, missing names, and empty input",
        fn () ->
          {
            let output =
              nb.capture(
                nb.main,
                [
                  " ",
                  "help",
                  "show",
                  "show ghost",
                  "why ghost",
                  "undo",
                  "redo",
                  "quit extra",
                  "",
                  "set NEVER = 1",
                ],
              )
            list.each(
              [
                "100 tokens",
                "(empty workbook)",
                "ghost = ERROR [ghost]: undefined cell",
                "undefined cell: ghost",
                "nothing to undo",
                "nothing to redo",
                "unexpected arguments",
                "bye (empty input or EOF)",
              ],
              fn (expected) -> check.true(text.contains?(output, expected), expected),
            )
            check.true(bool.not(text.contains?(output, "NEVER")), "empty input terminates")
          },
      ),
      Case(
        "command parsing validates names and separates formula diagnostics",
        fn () ->
          {
            list.each(
              [
                "set x 1",
                "unset a b",
                "show a b",
                "why",
                "undo 1",
                "redo 1",
                "help extra",
                "Set x = 1",
                "set _x = 1",
                "set é = 1",
                "set a-b = 1",
                "set x = 1 = 2",
              ],
              fn (
                line,
              ) ->
                {
                  let response = nb.execute(nb.empty(), line)
                  check.true(text.contains?(nb.response-output(response), "rejected:"), line)
                  check.eq(
                    nb.book-text(nb.response-book(response)),
                    nb.book-text(nb.empty()),
                    text.eq,
                    text.show,
                    "invalid command is atomic",
                  )
                },
            )
            let book = nb.run-lines([" \tset\t A_1 = 4  ", "set a_1 = 7", "set sum = A_1 + a_1"])
            nb.check-value(book, "sum", "11")
          },
      ),
      Case(
        "demo shows hand-calculated financial values and rejects invalid edits",
        fn () ->
          {
            let output = nb.capture(nb.demo, [])
            list.each(
              [
                "surplus = 580",
                "surplus: 580 -> 800",
                "surplus = 1100",
                "cycle: tickets -> surplus -> revenue -> tickets",
                "column 7:",
              ],
              fn (expected) -> check.true(text.contains?(output, expected), expected),
            )
          },
      ),
    ],
  )
