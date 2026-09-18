-- Capture the real interactive applications using a Jacquard Console handler.
-- Empty input behaves like terminal EOF. No subprocess or host test code.
interaction.capture(
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
    list.fold(list.reverse(messages), "", fn (text, message) -> text.concat(text, message))
  }

interaction.tests =
  Group(
    "interactive applications",
    [
      Case(
        "dice reads numbers and reports the same checked recommendation",
        fn () ->
          {
            let transcript = interaction.capture(fn () -> dice.interactive(), [" 19 ", "3"])
            check.true(
              text.contains?(transcript, "Pot 19, at most 3 more rolls: ROLL"),
              "trim and parse inputs",
            )
            check.true(text.contains?(transcript, "19.167"), "formatted expectation")
          },
      ),
      Case(
        "dice invalid input and EOF give readable messages",
        fn () ->
          {
            check.true(
              text.contains?(
                interaction.capture(fn () -> dice.interactive(), ["hello", "2"]),
                "Please enter whole numbers",
              ),
              "malformed input",
            )
            check.true(
              text.contains?(
                interaction.capture(fn () -> dice.interactive(), ["10", "4"]),
                "remaining rolls from 0 to 3",
              ),
              "bound refused",
            )
            check.true(
              text.contains?(
                interaction.capture(fn () -> dice.interactive(), []),
                "Please enter whole numbers",
              ),
              "EOF terminates",
            )
          },
      ),
      Case(
        "picnic reads assumptions and explains a useful forecast",
        fn () ->
          {
            let transcript = interaction.capture(fn () -> picnic.interactive(), ["30", "80", "1"])
            check.true(
              text.contains?(transcript, "Without more information: choose covered pavilion"),
              "baseline decision",
            )
            check.true(text.contains?(transcript, "3.275 enjoyment points"), "information value")
            check.true(
              text.contains?(transcript, "Recommendation: buy the forecast"),
              "purchase decision",
            )
          },
      ),
      Case(
        "picnic handles impossible observations, malformed inputs, bounds, and EOF",
        fn () ->
          {
            let known-dry = interaction.capture(fn () -> picnic.interactive(), ["0", "100", "0"])
            check.true(
              text.contains?(known-dry, "wet forecast: impossible"),
              "explicit impossible branch",
            )
            check.true(
              text.contains?(known-dry, "Recommendation: skip the forecast"),
              "zero information tie",
            )
            check.true(
              text.contains?(
                interaction.capture(fn () -> picnic.interactive(), ["rain", "80", "1"]),
                "Please enter whole numbers",
              ),
              "malformed input",
            )
            check.true(
              text.contains?(
                interaction.capture(fn () -> picnic.interactive(), ["30", "49", "1"]),
                "forecast accuracy 50..100%",
              ),
              "bound refused",
            )
            check.true(
              text.contains?(
                interaction.capture(fn () -> picnic.interactive(), []),
                "Please enter whole numbers",
              ),
              "EOF terminates",
            )
          },
      ),
    ],
  )
