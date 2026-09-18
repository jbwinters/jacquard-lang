rota.capture(
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

rota.parser-tests =
  Group(
    "rota decimal input",
    [
      Case(
        "bounded signed decimal parsing accepts domain endpoints and rejects malformed input",
        fn () ->
          {
            list.each(
              [
                ("0", 0),
                (" -1 ", -1),
                ("+20000", 20000),
                ("000048", 48),
                ("999999", 999999),
                ("-999999", -999999),
                ("-000000", 0),
              ],
              fn (
                example,
              ) ->
                match example {
                  | (input, expected) ->
                    match rota.parse-integer(input) {
                      | Some(actual) ->
                        check.eq(actual, expected, int.eq, int.show, "parsed integer")
                      | None -> check.true(False, "valid decimal rejected")}
                },
            )
            list.each(
              [
                "",
                " ",
                "+",
                "-",
                "1.5",
                "1e2",
                "0x10",
                "1 2",
                "１２",
                "0000000",
                "1000000",
                "4611686018427387904",
              ],
              fn (
                input,
              ) ->
                match rota.parse-integer(input) {
                  | None -> check.true(True, "malformed or oversized decimal refused")
                  | Some(_) -> check.true(False, "invalid decimal accepted")
                },
            )
          },
      ),
    ],
  )

rota.interaction-tests =
  Group(
    "rota interaction",
    [
      Case(
        "the actual interactive application explains a balanced solution",
        fn () ->
          {
            let transcript =
              rota.capture(fn () -> rota.interactive(), [" 2 ", "200", "8", "2", "-1"])
            check.true(text.contains?(transcript, "PROVEN OPTIMAL"), "optimal status")
            check.true(
              text.contains?(transcript, "Score 20 = preferences 36 - workload penalty 16"),
              "objective explained",
            )
            check.true(text.contains?(transcript, "Alex: 2/4 shifts"), "balanced workload shown")
          },
      ),
      Case(
        "budget output distinguishes an incumbent from unknown feasibility",
        fn () ->
          {
            let partial = rota.capture(fn () -> rota.interactive(), ["2", "5", "8", "2", "-1"])
            check.true(text.contains?(partial, "BUDGET EXHAUSTED"), "stopped status")
            check.true(
              text.contains?(partial, "optimality has NOT been proved"),
              "no false optimality claim",
            )
            check.true(
              text.contains?(partial, "Optimality gap is at most 4 points"),
              "honest relaxation gap",
            )
            let unknown = rota.capture(fn () -> rota.interactive(), ["2", "0", "8", "2", "-1"])
            check.true(text.contains?(unknown, "Feasibility is UNKNOWN"), "no incumbent")
            check.true(
              bool.not(text.contains?(unknown, "PROVEN INFEASIBLE")),
              "budget is not infeasibility",
            )
          },
      ),
      Case(
        "absence changes the schedule and missing coverage is explained",
        fn () ->
          {
            let absent = rota.capture(fn () -> rota.interactive(), ["2", "200", "8", "2", "0"])
            check.true(text.contains?(absent, "Alex: 0/4 shifts"), "excluded staff never assigned")
            check.true(text.contains?(absent, "Blair: 4/4 shifts"), "remaining staff covers work")
            let impossible = rota.capture(fn () -> rota.interactive(), ["3", "200", "8", "2", "0"])
            check.true(text.contains?(impossible, "PROVEN INFEASIBLE"), "coverage impossible")
            check.true(
              text.contains?(
                impossible,
                "No available, qualified staff with capacity for First lead shift",
              ),
              "specific uncovered shift named",
            )
            let conflict = rota.capture(fn () -> rota.interactive(), ["3", "200", "8", "2", "-1"])
            check.true(
              text.contains?(conflict, "Only lead is the only candidate"),
              "forced employee identified",
            )
            check.true(
              text.contains?(conflict, "required 8 hours of rest"),
              "concrete rest conflict explained",
            )
          },
      ),
      Case(
        "input errors and EOF are readable and terminate",
        fn () ->
          list.each(
            [
              (["hello", "200", "8", "2", "-1"], "Enter whole numbers"),
              ([], "EOF ends this run"),
              (["4", "200", "8", "2", "-1"], "Scenario must be 1..3"),
              (["2", "200", "8", "2", "99"], "employee ID does not exist"),
              (["2", "-1", "8", "2", "-1"], "Node budget must be 0..20000"),
              (["2", "200", "49", "2", "-1"], "Rest must be 0..48 hours"),
              (["2", "200", "8", "11", "-1"], "Fairness weight must be 0..10"),
            ],
            fn (
              example,
            ) ->
              match example {
                | (inputs, expected) ->
                  check.true(
                    text.contains?(rota.capture(fn () -> rota.interactive(), inputs), expected),
                    "input refusal",
                  )
              },
          ),
      ),
    ],
  )
