rota.status-name(
  status,
) =
  match status {
    | ProvenOptimal -> "PROVEN OPTIMAL"
    | ProvenImpossible -> "PROVEN INFEASIBLE"
    | BudgetStopped -> "BUDGET EXHAUSTED"
  }

rota.skill-name(skill) = match skill {
                           | GeneralSkill -> "general"
                           | LeadSkill -> "lead"}

rota.forced-conflicts(
  problem,
) =
  list.fold(
    rota.shifts(problem),
    Nil,
    fn (
      messages,
      left,
    ) ->
      list.fold(
        rota.shifts(problem),
        messages,
        fn (
          found,
          right,
        ) ->
          if int.gte?(rota.shift-id(left), rota.shift-id(right)) then found
          else match (rota.candidates(problem, left, Nil), rota.candidates(problem, right, Nil)) {
                 | (Cons(a, Nil), Cons(b, Nil)) ->
                   if bool.and(
                        eq(rota.staff-id(a), rota.staff-id(b)),
                        bool.not(rota.rested?(left, right, rota.rest(problem))),
                      ) then
                     {
                       let pair =
                         $"  {rota.staff-name(a)} is the only candidate for {rota.shift-label(left)} and {rota.shift-label(right)}."
                       let reason =
                         $" Those intervals do not leave the required {text.from-int(rota.rest(problem))} hours of rest."
                       list.append(found, [text.concat(pair, reason)])}
                   else found
                 | _ -> found
          },
      ),
  )

rota.explain-impossible(
  problem,
) =
  {
    let uncovered =
      list.filter(
        rota.shifts(problem),
        fn (shift) -> eq(list.length(rota.candidates(problem, shift, Nil)), 0),
      )
    let forced = rota.forced-conflicts(problem)
    list.each(
      uncovered,
      fn (
        shift,
      ) ->
        println($"  No available, qualified staff with capacity for {rota.shift-label(shift)}."),
    )
    list.each(forced, fn (message) -> println(message))
    let capacity =
      list.fold(
        rota.people(problem),
        0,
        fn (total, person) -> add(total, rota.staff-limit(person)),
      )
    if int.lt?(capacity, list.length(rota.shifts(problem))) then
      println("  Total staff capacity is smaller than the number of shifts.")
    else if bool.and(eq(list.length(uncovered), 0), eq(list.length(forced), 0)) then
           println(
             "  Exhaustive search found no joint assignment satisfying availability, skills, limits, and rest. This is not a minimal conflict explanation.",
           )
    else ()
  }

rota.show-solution(
  problem,
  solution,
) =
  match solution {
    | RotaSolution(
        assignments: assignments,
        preference: preference,
        penalty: penalty,
        score: score,
      ) -> {
      println(
        $"Score {text.from-int(score)} = preferences {text.from-int(preference)} - workload penalty {text.from-int(penalty)}",
      )
      println(
        $"Penalty = {text.from-int(rota.weight(problem))} * sum(each person's shift count squared).",
      )
      list.each(
        rota.shifts(problem),
        fn (
          shift,
        ) ->
          {
            let selected =
              list.find(
                assignments,
                fn (
                  assignment,
                ) ->
                  match assignment {
                    | RotaAssignment(assigned, _) ->
                      eq(rota.shift-id(assigned), rota.shift-id(shift))
                  },
              )
            match selected {
              | None -> println("  Internal error: shift missing from completed schedule.")
              | Some(RotaAssignment(_, id)) ->
                match rota.find-person(rota.people(problem), id) {
                  | None -> println("  Internal error: unknown employee.")
                  | Some(person) ->
                    match shift {
                      | RotaShift(start: start, finish: finish, skill: skill) -> {
                        let interval =
                          $"  {rota.shift-label(shift)} [hours {text.from-int(start)}..{text.from-int(finish)}"
                        let employee =
                          $", {rota.skill-name(skill)}]: {rota.staff-name(person)}; preference {text.from-int(rota.preference(person, shift))}"
                        println(text.concat(interval, employee))
                      }}}
            }
          },
      )
      println("Workloads:")
      list.each(
        rota.people(problem),
        fn (
          person,
        ) ->
          {
            let count = rota.load(rota.staff-id(person), assignments)
            let allocation =
              $"  {rota.staff-name(person)}: {text.from-int(count)}/{text.from-int(rota.staff-limit(person))} shifts"
            println(text.concat(allocation, $"; {text.from-int(mul(8, count))} hours"))
          },
      )
      println(
        "Complete schedule independently rechecked: availability, skills, capacity, coverage, and rest all satisfied.",
      )
    }
  }

rota.show(
  problem,
  budget,
) =
  {
    let size =
      $"Staff {text.from-int(list.length(rota.people(problem)))}, shifts {text.from-int(list.length(rota.shifts(problem)))}"
    println(
      text.concat(
        size,
        $", minimum rest {text.from-int(rota.rest(problem))}h, node budget {text.from-int(budget)}",
      ),
    )
    match rota.solve(problem, budget) {
      | Err(errors) ->
        list.each(errors, fn (error) -> println(text.concat("INPUT ERROR: ", error)))
      | Ok(
          RotaReport(status: status, best: best, expanded: expanded, pruned: pruned, upper: upper),
        ) -> {
        println(rota.status-name(status))
        println(
          $"Expanded {text.from-int(expanded)} search nodes; {text.from-int(pruned)} pruning decisions.",
        )
        match (status, best) {
          | (ProvenImpossible, _) -> rota.explain-impossible(problem)
          | (BudgetStopped, None) ->
            println(
              "No complete schedule found yet. Feasibility is UNKNOWN; this is not evidence of impossibility.",
            )
          | (_, Some(solution)) -> {
            rota.show-solution(problem, solution)
            match (status, upper) {
              | (BudgetStopped, Some(bound)) -> {
                println(
                  $"Best found score {text.from-int(rota.solution-score(solution))}; global relaxation upper bound {text.from-int(bound)}.",
                )
                println(
                  $"Optimality gap is at most {text.from-int(sub(bound, rota.solution-score(solution)))} points; optimality has NOT been proved.",
                )
              }
              | _ -> ()
            }
          }
          | _ -> ()
        }
      }
    }
  }

rota.demo() =
  {
    println("STAFF ROTA OPTIMIZER")
    println("One person per eight-hour shift. Preferences compete with workload balance.")
    println("\nEight staff across fourteen shifts:")
    rota.show(rota.week(), 2000)
    println("\nSmall problem: preference-only objective, then balanced workloads:")
    rota.show(rota.configure(rota.tiny(), 8, 0, -1), 200)
    rota.show(rota.tiny(), 200)
    println("\nA rest conflict requiring a joint feasibility check:")
    rota.show(rota.rest-conflict(), 200)
    println("\nA short search with a usable incumbent but no optimality proof:")
    rota.show(rota.tiny(), 5)
    println("\nZero search budget must not claim infeasibility:")
    rota.show(rota.week(), 0)
  }

-- Native v1 has no text.to-int intrinsic. Parse at most six ASCII decimal
-- digits, with an optional sign, so accumulation cannot wrap a 63-bit Int.
rota.decimal-digits =
  [
    MkPair("0", 0),
    MkPair("1", 1),
    MkPair("2", 2),
    MkPair("3", 3),
    MkPair("4", 4),
    MkPair("5", 5),
    MkPair("6", 6),
    MkPair("7", 7),
    MkPair("8", 8),
    MkPair("9", 9),
  ]

rota.parse-digits(
  characters,
  value,
  count,
) =
  match characters {
    | Nil -> if int.gt?(count, 0) then Some(value) else None
    | Cons(character, remaining) ->
      if int.gte?(count, 6) then None
      else {
             let digit =
               list.find(
                 rota.decimal-digits,
                 fn (entry) -> match entry {
                                 | MkPair(letter, _) -> text.eq?(character, letter)},
               )
             match digit {
               | None -> None
               | Some(MkPair(_, number)) ->
                 rota.parse-digits(remaining, add(mul(value, 10), number), add(count, 1))
             }
      }
  }

rota.parse-integer(
  input,
) =
  {
    let trimmed = text.trim(input)
    if int.gt?(text.length(trimmed), 7) then None
    else {
           let characters = text.split(trimmed, "")
           match characters {
             | Nil -> None
             | Cons(first, remaining) ->
               if text.eq?(first, "-") then
                 match rota.parse-digits(remaining, 0, 0) {
                   | None -> None
                   | Some(value) -> Some(sub(0, value))}
               else if text.eq?(first, "+") then rota.parse-digits(remaining, 0, 0)
               else rota.parse-digits(characters, 0, 0)
           }
    }
  }

rota.interactive() =
  {
    println("STAFF ROTA OPTIMIZER")
    println(
      "Scenario 1: eight staff / fourteen shifts. 2: two staff / four shifts. 3: lead rest conflict.",
    )
    let scenario-input = console.ask("Scenario (1..3)?")
    let budget-input = console.ask("Node budget (0..20000; try 2000)?")
    let rest-input = console.ask("Minimum rest in hours (0..48; try 12)?")
    let fairness-input = console.ask("Workload balance weight (0..10; try 2)?")
    let excluded-input =
      console.ask(
        "Employee to make unavailable (-1 for none; IDs 0..7 in scenario 1, 0..1 otherwise)?",
      )
    let parsed =
      (
        rota.parse-integer(scenario-input),
        rota.parse-integer(budget-input),
        rota.parse-integer(rest-input),
        rota.parse-integer(fairness-input),
        rota.parse-integer(excluded-input),
      )
    match parsed {
      | (Some(scenario), Some(budget), Some(rest), Some(fairness), Some(excluded)) ->
        if bool.or(int.lt?(scenario, 1), int.gt?(scenario, 3)) then
          println("INPUT ERROR: Scenario must be 1..3.")
        else {
               let problem =
                 match scenario {
                   | 1 -> rota.week()
                   | 2 -> rota.tiny()
                   | _ -> rota.rest-conflict()}
               if bool.and(
                    bool.not(eq(excluded, -1)),
                    bool.not(
                      rota.any(
                        rota.people(problem),
                        fn (person) -> eq(rota.staff-id(person), excluded),
                      ),
                    ),
                  ) then
                 println("INPUT ERROR: Excluded employee ID does not exist in this scenario.")
               else rota.show(rota.configure(problem, rest, fairness, excluded), budget)
        }
      | _ ->
        println(
          "INPUT ERROR: Enter whole numbers (at most six decimal digits) for all five prompts. EOF ends this run.",
        )
    }
  }
