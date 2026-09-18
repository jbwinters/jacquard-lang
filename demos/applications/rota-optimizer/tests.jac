-- Oracle: enumerate every employee choice, even obviously invalid prefixes.
-- Only complete assignments are filtered by the separate full verifier.
-- No MRV, candidate filtering, objective bound, or search budget is reused.
rota.oracle(
  problem,
  todo,
  assignments,
) =
  match todo {
    | Nil ->
      if rota.verify(problem, assignments) then Some(rota.solution(problem, assignments)) else None
    | Cons(shift, remaining) ->
      list.fold(
        rota.people(problem),
        None,
        fn (
          best,
          person,
        ) ->
          {
            let candidate =
              rota.oracle(
                problem,
                remaining,
                Cons(RotaAssignment(shift, rota.staff-id(person)), assignments),
              )
            match (best, candidate) {
              | (None, _) -> candidate
              | (_, None) -> best
              | (Some(previous), Some(next)) ->
                if int.gt?(rota.solution-score(next), rota.solution-score(previous)) then candidate
                else best
            }
          },
      )
  }

rota.same-best?(
  a,
  b,
) =
  match (a, b) {
    | (None, None) -> True
    | (Some(left), Some(right)) -> eq(rota.solution-score(left), rota.solution-score(right))
    | _ -> False
  }

rota.bit?(
  number,
  bit,
) =
  eq(mod(div(number, match bit {
                       | 0 -> 1
                       | 1 -> 2
                       | 2 -> 4
                       | 3 -> 8
                       | _ -> 16}), 2), 1)

rota.generated(
  seed,
  fairness,
) =
  {
    let shifts =
      list.map(
        [0, 1, 2],
        fn (
          id,
        ) ->
          {
            let start = match id {
                          | 0 -> 0
                          | 1 -> 12
                          | _ -> 32}
            RotaShift(
              id: id,
              label: text.from-int(id),
              start: start,
              finish: add(start, 8),
              skill: if bool.and(eq(id, 1), rota.bit?(seed, 2)) then LeadSkill else GeneralSkill,
            )
          },
      )
    let people =
      list.map(
        [0, 1],
        fn (
          id,
        ) ->
          {
            let skills = if eq(id, 0) then [GeneralSkill, LeadSkill] else [GeneralSkill]
            let available =
              list.filter(
                [0, 1, 2],
                fn (
                  shift,
                ) ->
                  if eq(id, 0) then bool.or(eq(shift, 2), rota.bit?(seed, shift))
                  else bool.or(eq(shift, 0), bool.not(rota.bit?(seed, shift))),
              )
            let preferences =
              list.map(
                [0, 1, 2],
                fn (shift) -> MkPair(shift, mod(add(add(seed, mul(id, 3)), mul(shift, 2)), 11)),
              )
            RotaStaff(
              id: id,
              name: text.from-int(id),
              skills: skills,
              available: available,
              limit: if eq(id, 0) then add(1, mod(seed, 3)) else 2,
              preferences: preferences,
            )
          },
      )
    RotaProblem(
      staff: people,
      shifts: shifts,
      rest: if rota.bit?(seed, 4) then 8 else 0,
      fairness: fairness,
    )
  }

rota.check-optimal(
  problem,
  budget,
  expected,
) =
  match rota.solve(problem, budget) {
    | Ok(RotaReport(status: ProvenOptimal, best: Some(solution), upper: Some(bound))) -> {
      check.eq(rota.solution-score(solution), expected, int.eq, int.show, "optimal objective")
      check.eq(bound, expected, int.eq, int.show, "closed optimality gap")
      check.true(rota.verify(problem, rota.solution-assignments(solution)), "independent validity")
    }
    | _ -> check.true(False, "expected a proved optimum with a valid complete schedule")
  }

rota.tests =
  Group(
    "rota optimizer",
    [
      Case(
        "empty workload is optimal without spending a search node",
        fn () ->
          {
            let people = rota.people(rota.tiny())
            let cleared =
              list.map(
                people,
                fn (
                  person,
                ) ->
                  RotaStaff(
                    rota.staff-id(person),
                    rota.staff-name(person),
                    [GeneralSkill],
                    [],
                    4,
                    [],
                  ),
              )
            rota.check-optimal(RotaProblem(cleared, [], 8, 2), 0, 0)
          },
      ),
      Case(
        "preference and balance objectives agree with hand calculations",
        fn () ->
          {
            rota.check-optimal(rota.configure(rota.tiny(), 8, 0, -1), 200, 40)
            rota.check-optimal(rota.tiny(), 200, 20)
            rota.check-optimal(rota.configure(rota.tiny(), 8, 2, 0), 200, 0)
          },
      ),
      Case(
        "rest checks are symmetric and include the exact boundary",
        fn () ->
          {
            let first = RotaShift(0, "first", 0, 8, GeneralSkill)
            let exact = RotaShift(1, "exact", 20, 28, GeneralSkill)
            let short = RotaShift(2, "short", 19, 27, GeneralSkill)
            let overlapping = RotaShift(3, "overlap", 7, 15, GeneralSkill)
            check.true(rota.rested?(first, exact, 12), "twelve hours is enough")
            check.true(rota.rested?(exact, first, 12), "same result in reverse order")
            check.true(bool.not(rota.rested?(first, short, 12)), "eleven hours is too short")
            check.true(
              bool.not(rota.rested?(first, overlapping, 0)),
              "zero rest still forbids overlapping shifts",
            )
          },
      ),
      Case(
        "nominally covered shifts can still be jointly infeasible",
        fn () ->
          {
            let problem = rota.rest-conflict()
            check.true(
              rota.every(
                rota.shifts(problem),
                fn (shift) -> int.gt?(list.length(rota.candidates(problem, shift, Nil)), 0),
              ),
              "every shift has a root candidate",
            )
            match rota.solve(problem, 200) {
              | Ok(RotaReport(status: ProvenImpossible, best: None, expanded: count)) ->
                check.true(int.gt?(count, 0), "joint conflict required search")
              | _ -> check.true(False, "rest conflict was not proved infeasible")
            }
            rota.check-optimal(rota.configure(problem, 4, 2, -1), 200, -8)
          },
      ),
      Case(
        "budget zero and budget with incumbent have distinct honest outcomes",
        fn () ->
          {
            match rota.solve(rota.tiny(), 0) {
              | Ok(RotaReport(status: BudgetStopped, best: None, expanded: 0)) ->
                check.true(True, "no search means unknown")
              | _ -> check.true(False, "zero budget claimed too much")
            }
            match rota.solve(rota.tiny(), 5) {
              | Ok(
                  RotaReport(
                    status: BudgetStopped,
                    best: Some(solution),
                    expanded: 5,
                    upper: Some(bound),
                  ),
                ) -> {
                check.true(
                  rota.verify(rota.tiny(), rota.solution-assignments(solution)),
                  "valid incumbent",
                )
                check.true(int.gte?(bound, 20), "upper bound covers true optimum")
                check.true(
                  int.lte?(rota.solution-score(solution), 20),
                  "incumbent is a lower bound",
                )
              }
              | _ -> check.true(False, "expected a stopped search with an incumbent")
            }
          },
      ),
      Case(
        "full verifier rejects missing, duplicate, unknown, and forged assignments",
        fn () ->
          {
            let problem = rota.tiny()
            let assignments = list.map(rota.shifts(problem), fn (shift) -> RotaAssignment(shift, 0))
            check.true(rota.verify(problem, assignments), "reference schedule is feasible")
            check.true(bool.not(rota.verify(problem, Nil)), "missing shifts")
            match assignments {
              | Cons(first, Cons(_, rest)) ->
                check.true(
                  bool.not(rota.verify(problem, Cons(first, Cons(first, rest)))),
                  "duplicate shift",
                )
              | _ -> check.true(False, "fixture needs at least two assignments")
            }
            check.true(
              bool.not(
                rota.verify(
                  problem,
                  list.map(rota.shifts(problem), fn (shift) -> RotaAssignment(shift, 99)),
                ),
              ),
              "unknown staff",
            )
            let forged =
              list.map(
                assignments,
                fn (
                  assignment,
                ) ->
                  match assignment {
                    | RotaAssignment(shift, id) ->
                      match shift {
                        | RotaShift(
                            id: key,
                            label: label,
                            start: start,
                            finish: finish,
                            skill: skill,
                          ) ->
                          RotaAssignment(
                            RotaShift(key, label, add(start, 1), add(finish, 1), skill),
                            id,
                          )}
                  },
              )
            check.true(
              bool.not(rota.verify(problem, forged)),
              "same ID cannot substitute different shift data",
            )
            check.true(
              bool.not(rota.verify(rota.configure(problem, 8, 2, 0), assignments)),
              "unavailable staff",
            )
            let conflict = rota.rest-conflict()
            check.true(
              bool.not(
                rota.verify(
                  conflict,
                  list.map(rota.shifts(conflict), fn (shift) -> RotaAssignment(shift, 1)),
                ),
              ),
              "unqualified staff",
            )
            check.true(
              bool.not(
                rota.verify(
                  conflict,
                  list.map(rota.shifts(conflict), fn (shift) -> RotaAssignment(shift, 0)),
                ),
              ),
              "insufficient rest",
            )
          },
      ),
      Case(
        "malformed problems and budgets return input errors",
        fn () ->
          {
            let shifts = rota.shifts(rota.tiny())
            let good = RotaStaff(0, "good", [GeneralSkill], [0, 1, 2, 3], 4, [])
            let bad-availability = RotaStaff(0, "bad", [GeneralSkill], [99], 4, [])
            let bad-preference = RotaStaff(0, "bad", [GeneralSkill], [0], 4, [MkPair(0, 11)])
            let bad-limit = RotaStaff(0, "bad", [GeneralSkill], [0], -1, [])
            list.each(
              [
                RotaProblem([good, good], shifts, 8, 2),
                RotaProblem([bad-availability], shifts, 8, 2),
                RotaProblem([bad-preference], shifts, 8, 2),
                RotaProblem([bad-limit], shifts, 8, 2),
                RotaProblem([good], shifts, -1, 2),
                RotaProblem([good], shifts, 8, 11),
                RotaProblem([good], [RotaShift(0, "bad", 0, 9, GeneralSkill)], 8, 2),
                RotaProblem(
                  [good],
                  [
                    RotaShift(
                      0,
                      "wrapping interval",
                      4611686018427387900,
                      -4611686018427387900,
                      GeneralSkill,
                    ),
                  ],
                  8,
                  2,
                ),
              ],
              fn (
                problem,
              ) ->
                match rota.solve(problem, 200) {
                  | Err(Cons(_, _)) -> check.true(True, "input refused")
                  | _ -> check.true(False, "invalid problem accepted")
                },
            )
            list.each(
              [-1, 20001],
              fn (
                budget,
              ) ->
                match rota.solve(rota.tiny(), budget) {
                  | Err(Cons(_, _)) -> check.true(True, "budget refused")
                  | _ -> check.true(False, "invalid budget accepted")
                },
            )
          },
      ),
      Case(
        "capacity shortage is proved even when individual shifts are covered",
        fn () ->
          {
            let original = rota.tiny()
            let people =
              list.map(
                rota.people(original),
                fn (
                  person,
                ) ->
                  RotaStaff(
                    rota.staff-id(person),
                    rota.staff-name(person),
                    [GeneralSkill],
                    [0, 1, 2, 3],
                    1,
                    [],
                  ),
              )
            let problem = RotaProblem(people, rota.shifts(original), 8, 2)
            check.true(
              rota.every(
                rota.shifts(problem),
                fn (shift) -> int.gt?(list.length(rota.candidates(problem, shift, Nil)), 0),
              ),
              "every shift has candidates",
            )
            match rota.solve(problem, 0) {
              | Ok(RotaReport(status: ProvenImpossible, best: None)) ->
                check.true(True, "capacity relaxation proves impossibility without search")
              | _ -> check.true(False, "capacity shortage not detected")
            }
            let assignments =
              list.map(rota.shifts(original), fn (shift) -> RotaAssignment(shift, 0))
            check.true(
              bool.not(rota.verify(problem, assignments)),
              "verifier checks final workload limits",
            )
          },
      ),
      Case(
        "baseline eight-person fourteen-shift fixture is optimized and rechecked",
        fn () -> rota.check-optimal(rota.week(), 2000, 73),
      ),
      Prop(
        "optimized search agrees with a separate exhaustive oracle",
        fn () ->
          {
            let seed = sample(UniformInt(0, 31))
            let fairness = sample(UniformInt(0, 2))
            let problem = rota.generated(seed, fairness)
            let oracle = rota.oracle(problem, rota.shifts(problem), Nil)
            match rota.solve(problem, 200) {
              | Ok(RotaReport(status: status, best: best, expanded: expanded)) -> {
                check.true(rota.same-best?(best, oracle), "same feasibility and optimal score")
                check.true(int.lte?(expanded, 200), "budget respected")
                match (status, oracle) {
                  | (ProvenOptimal, Some(solution)) ->
                    check.true(
                      rota.verify(problem, rota.solution-assignments(solution)),
                      "oracle winner is valid",
                    )
                  | (ProvenImpossible, None) -> check.true(True, "both prove impossible")
                  | _ -> check.true(False, "small complete search was mislabeled")
                }
              }
              | Err(_) -> check.true(False, "generated valid input rejected")
            }
          },
      ),
      Prop(
        "partial-node upper bounds never cut off a better completion",
        fn () ->
          {
            let seed = sample(UniformInt(0, 31))
            let fairness = sample(UniformInt(0, 2))
            let problem = rota.generated(seed, fairness)
            match rota.shifts(problem) {
              | Cons(first, remaining) ->
                list.each(
                  rota.people(problem),
                  fn (
                    person,
                  ) ->
                    if rota.allowed?(problem, person, first, Nil) then
                      {
                        let prefix = [RotaAssignment(first, rota.staff-id(person))]
                        let partial-score = rota.solution-score(rota.solution(problem, prefix))
                        let oracle = rota.oracle(problem, remaining, prefix)
                        match (rota.analyze(problem, remaining, prefix, partial-score), oracle) {
                          | (None, None) -> check.true(True, "pruned prefix has no completion")
                          | (Some((_, _, bound)), Some(solution)) ->
                            check.true(
                              int.gte?(bound, rota.solution-score(solution)),
                              "bound is optimistic",
                            )
                          | (Some(_), None) ->
                            check.true(True, "relaxation may keep an infeasible node")
                          | (None, Some(_)) -> check.true(False, "feasible completion was pruned")
                        }}
                    else check.true(True, "ineligible prefix is not searched"),
                )
              | Nil -> check.true(False, "generator must supply shifts")
            }
          },
      ),
      Prop(
        "larger deterministic budgets preserve or improve the incumbent",
        fn () ->
          {
            let budget = sample(UniformInt(0, 20))
            match (rota.solve(rota.tiny(), budget), rota.solve(rota.tiny(), add(budget, 1))) {
              | (
                  Ok(RotaReport(best: before, expanded: used)),
                  Ok(RotaReport(best: after, expanded: more-used)),
                ) -> {
                check.true(
                  bool.and(int.lte?(used, budget), int.lte?(more-used, add(budget, 1))),
                  "both budgets respected",
                )
                match (before, after) {
                  | (Some(a), Some(b)) ->
                    check.true(
                      int.gte?(rota.solution-score(b), rota.solution-score(a)),
                      "incumbent cannot worsen",
                    )
                  | (None, _) -> check.true(True, "no previous incumbent")
                  | _ -> check.true(False, "incumbent was lost")
                }
              }
              | _ -> check.true(False, "valid budget rejected")
            }
          },
      ),
    ],
  )
