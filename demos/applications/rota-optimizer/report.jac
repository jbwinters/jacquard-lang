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
    rota-problem.shifts(problem),
    Nil,
    fn (
      messages,
      left,
    ) ->
      list.fold(
        rota-problem.shifts(problem),
        messages,
        fn (
          found,
          right,
        ) ->
          if int.gte?(rota-shift.id(left), rota-shift.id(right)) then found
          else match (rota.candidates(problem, left, Nil), rota.candidates(problem, right, Nil)) {
                 | (Cons(a, Nil), Cons(b, Nil)) ->
                   if bool.and(
                        eq(rota-staff.id(a), rota-staff.id(b)),
                        bool.not(rota.rested?(left, right, rota-problem.rest(problem))),
                      ) then
                     {
                       let reason =
                         $"  {rota-staff.name(a)} is the only candidate for {rota-shift.label(left)} and {rota-shift.label(right)}. Those intervals do not leave the required {text.from-int(rota-problem.rest(problem))} hours of rest."
                       list.append(found, [reason])}
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
        rota-problem.shifts(problem),
        fn (shift) -> eq(list.length(rota.candidates(problem, shift, Nil)), 0),
      )
    let forced = rota.forced-conflicts(problem)
    list.each(
      uncovered,
      fn (
        shift,
      ) ->
        println($"  No available, qualified staff with capacity for {rota-shift.label(shift)}."),
    )
    list.each(forced, fn (message) -> println(message))
    let capacity =
      list.fold(
        rota-problem.staff(problem),
        0,
        fn (total, person) -> add(total, rota-staff.limit(person)),
      )
    if int.lt?(capacity, list.length(rota-problem.shifts(problem))) then
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
        $"Penalty = {text.from-int(rota-problem.fairness(problem))} * sum(each person's shift count squared).",
      )
      list.each(
        rota-problem.shifts(problem),
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
                      eq(rota-shift.id(assigned), rota-shift.id(shift))
                  },
              )
            match selected {
              | None -> println("  Internal error: shift missing from completed schedule.")
              | Some(RotaAssignment(_, id)) ->
                match rota.find-person(rota-problem.staff(problem), id) {
                  | None -> println("  Internal error: unknown employee.")
                  | Some(person) ->
                    match shift {
                      | RotaShift(start: start, finish: finish, skill: skill) -> {
                        println(
                          $"  {rota-shift.label(shift)} [hours {text.from-int(start)}..{text.from-int(finish)}, {rota.skill-name(skill)}]: {rota-staff.name(person)}; preference {text.from-int(rota.preference(person, shift))}",
                        )
                      }}}
            }
          },
      )
      println("Workloads:")
      list.each(
        rota-problem.staff(problem),
        fn (
          person,
        ) ->
          {
            let count = rota.load(rota-staff.id(person), assignments)
            println(
              $"  {rota-staff.name(person)}: {text.from-int(count)}/{text.from-int(rota-staff.limit(person))} shifts; {text.from-int(mul(8, count))} hours",
            )
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
    println(
      $"Staff {text.from-int(list.length(rota-problem.staff(problem)))}, shifts {text.from-int(list.length(rota-problem.shifts(problem)))}, minimum rest {text.from-int(rota-problem.rest(problem))}h, node budget {text.from-int(budget)}",
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
                  $"Best found score {text.from-int(rota-solution.score(solution))}; global relaxation upper bound {text.from-int(bound)}.",
                )
                println(
                  $"Optimality gap is at most {text.from-int(sub(bound, rota-solution.score(solution)))} points; optimality has NOT been proved.",
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

-- The prompts accept at most six decimal digits, with an optional sign; a
-- longer number is an input error even when it would fit in an Int.
rota.parse-integer(
  input,
) =
  {
    let trimmed = text.trim(input)
    let digits = list.length(list.filter(text.split(trimmed, ""), text.ascii-digit?))
    if int.gt?(digits, 6) then None else text.to-int(trimmed)
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
                      list.any?(
                        rota-problem.staff(problem),
                        fn (person) -> eq(rota-staff.id(person), excluded),
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
