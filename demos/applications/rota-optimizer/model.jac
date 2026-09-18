-- One employee per shift. All times are integer hours on the same timeline.
type RotaSkill = | GeneralSkill | LeadSkill

type RotaStaff =
  | RotaStaff(
      id: Int,
      name: Text,
      skills: List RotaSkill,
      available: List Int,
      limit: Int,
      preferences: List (Pair Int Int),
    )

type RotaShift = | RotaShift(id: Int, label: Text, start: Int, finish: Int, skill: RotaSkill)

type RotaAssignment = | RotaAssignment(shift: RotaShift, person: Int)

type RotaProblem =
  | RotaProblem(staff: List RotaStaff, shifts: List RotaShift, rest: Int, fairness: Int)

type RotaSolution =
  | RotaSolution(assignments: List RotaAssignment, preference: Int, penalty: Int, score: Int)

type RotaStatus = | ProvenOptimal | ProvenImpossible | BudgetStopped

type RotaReport =
  | RotaReport(
      status: RotaStatus,
      best: Option RotaSolution,
      expanded: Int,
      pruned: Int,
      upper: Option Int,
    )

type RotaNode = | RotaNode(todo: List RotaShift, assignments: List RotaAssignment, score: Int)

rota.staff-id(person) = match person {
                          | RotaStaff(id: id) -> id}

rota.staff-name(person) = match person {
                            | RotaStaff(name: name) -> name}

rota.staff-limit(person) = match person {
                             | RotaStaff(limit: limit) -> limit}

rota.shift-id(shift) = match shift {
                         | RotaShift(id: id) -> id}

rota.shift-label(shift) = match shift {
                            | RotaShift(label: label) -> label}

rota.people(problem) = match problem {
                         | RotaProblem(staff: people) -> people}

rota.shifts(problem) = match problem {
                         | RotaProblem(shifts: shifts) -> shifts}

rota.rest(problem) = match problem {
                       | RotaProblem(rest: hours) -> hours}

rota.weight(problem) = match problem {
                         | RotaProblem(fairness: weight) -> weight}

rota.solution-score(solution) = match solution {
                                  | RotaSolution(score: score) -> score}

rota.solution-assignments(
  solution,
) =
  match solution {
    | RotaSolution(assignments: assignments) -> assignments
  }

rota.every(
  xs,
  predicate,
) =
  match xs {
    | Nil -> True
    | Cons(x, rest) -> if predicate(x) then rota.every(rest, predicate) else False
  }

rota.any(
  xs,
  predicate,
) =
  match xs {
    | Nil -> False
    | Cons(x, rest) -> if predicate(x) then True else rota.any(rest, predicate)
  }

rota.member?(id, ids) = rota.any(ids, fn (other) -> eq(id, other))

rota.distinct?(
  ids,
) =
  match ids {
    | Nil -> True
    | Cons(id, rest) -> if rota.member?(id, rest) then False else rota.distinct?(rest)
  }

rota.find-person(people, id) = list.find(people, fn (person) -> eq(rota.staff-id(person), id))

rota.find-shift(shifts, id) = list.find(shifts, fn (shift) -> eq(rota.shift-id(shift), id))

rota.skill-same?(
  a,
  b,
) =
  match (a, b) {
    | (GeneralSkill, GeneralSkill) -> True
    | (LeadSkill, LeadSkill) -> True
    | _ -> False
  }

rota.qualified?(
  person,
  shift,
) =
  match (person, shift) {
    | (RotaStaff(skills: skills), RotaShift(skill: required)) ->
      rota.any(skills, fn (skill) -> rota.skill-same?(skill, required))
  }

rota.available?(
  person,
  shift,
) =
  match person {
    | RotaStaff(available: ids) -> rota.member?(rota.shift-id(shift), ids)
  }

rota.preference(
  person,
  shift,
) =
  match person {
    | RotaStaff(preferences: preferences) -> {
      let selected =
        list.find(
          preferences,
          fn (entry) -> match entry {
                          | MkPair(id, _) -> eq(id, rota.shift-id(shift))},
        )
      match selected {
        | None -> 0
        | Some(MkPair(_, points)) -> points
      }
    }
  }

rota.load(
  id,
  assignments,
) =
  list.fold(
    assignments,
    0,
    fn (
      count,
      assignment,
    ) ->
      match assignment {
        | RotaAssignment(person: owner) -> if eq(id, owner) then add(count, 1) else count
      },
  )

rota.rested?(
  left,
  right,
  hours,
) =
  match (left, right) {
    | (RotaShift(start: a, finish: b), RotaShift(start: c, finish: d)) ->
      if int.lte?(b, c) then int.gte?(sub(c, b), hours)
      else if int.lte?(d, a) then int.gte?(sub(a, d), hours)
      else False
  }

rota.allowed?(
  problem,
  person,
  shift,
  assignments,
) =
  if bool.not(rota.available?(person, shift)) then False
  else if bool.not(rota.qualified?(person, shift)) then False
  else if int.gte?(rota.load(rota.staff-id(person), assignments), rota.staff-limit(person)) then
         False
  else rota.every(
         assignments,
         fn (
           assignment,
         ) ->
           match assignment {
             | RotaAssignment(other, id) ->
               if eq(id, rota.staff-id(person)) then rota.rested?(shift, other, rota.rest(problem))
               else True
           },
       )

rota.candidates(
  problem,
  shift,
  assignments,
) =
  list.filter(
    rota.people(problem),
    fn (person) -> rota.allowed?(problem, person, shift, assignments),
  )

rota.valid-input(
  problem,
) =
  {
    let people = rota.people(problem)
    let shifts = rota.shifts(problem)
    let person-ids = list.map(people, fn (person) -> rota.staff-id(person))
    let shift-ids = list.map(shifts, fn (shift) -> rota.shift-id(shift))
    let issues =
      [
        (
          bool.and(int.gt?(list.length(people), 0), int.lte?(list.length(people), 8)),
          "Provide 1..8 staff.",
        ),
        (int.lte?(list.length(shifts), 14), "Provide at most 14 shifts."),
        (rota.distinct?(person-ids), "Staff IDs must be unique."),
        (rota.distinct?(shift-ids), "Shift IDs must be unique."),
        (
          bool.and(int.gte?(rota.rest(problem), 0), int.lte?(rota.rest(problem), 48)),
          "Rest must be 0..48 hours.",
        ),
        (
          bool.and(int.gte?(rota.weight(problem), 0), int.lte?(rota.weight(problem), 10)),
          "Fairness weight must be 0..10.",
        ),
        (
          rota.every(
            shifts,
            fn (
              shift,
            ) ->
              match shift {
                | RotaShift(id: id, label: label, start: start, finish: finish) ->
                  bool.and(
                    bool.and(int.gte?(id, 0), int.lte?(id, 99)),
                    bool.and(
                      bool.not(text.empty?(text.trim(label))),
                      bool.and(
                        bool.and(int.gte?(start, 0), int.lte?(start, 160)),
                        bool.and(
                          bool.and(int.gte?(finish, 8), int.lte?(finish, 168)),
                          eq(sub(finish, start), 8),
                        ),
                      ),
                    ),
                  )
              },
          ),
          "Shifts need IDs 0..99, nonempty labels, and eight-hour intervals within hours 0..168.",
        ),
        (
          rota.every(
            people,
            fn (
              person,
            ) ->
              match person {
                | RotaStaff(
                    id: id,
                    name: name,
                    available: available,
                    limit: limit,
                    preferences: preferences,
                  ) -> {
                  let preference-ids =
                    list.map(preferences, fn (entry) -> match entry {
                                                          | MkPair(key, _) -> key})
                  bool.and(
                    bool.and(int.gte?(id, 0), int.lte?(id, 99)),
                    bool.and(
                      bool.not(text.empty?(text.trim(name))),
                      bool.and(
                        bool.and(int.gte?(limit, 0), int.lte?(limit, 14)),
                        bool.and(
                          bool.and(rota.distinct?(available), rota.distinct?(preference-ids)),
                          bool.and(
                            rota.every(available, fn (key) -> rota.member?(key, shift-ids)),
                            rota.every(
                              preferences,
                              fn (
                                entry,
                              ) ->
                                match entry {
                                  | MkPair(key, points) ->
                                    bool.and(
                                      rota.member?(key, shift-ids),
                                      bool.and(int.gte?(points, 0), int.lte?(points, 10)),
                                    )
                                },
                            ),
                          ),
                        ),
                      ),
                    ),
                  )
                }
              },
          ),
          "Staff need IDs 0..99, nonempty names, limits 0..14, unique known availability/preference IDs, and preference points 0..10.",
        ),
      ]
    list.fold(
      issues,
      Nil,
      fn (
        errors,
        issue,
      ) ->
        match issue {
          | (valid, message) -> if valid then errors else list.append(errors, [message])
        },
    )
  }

-- Full-result verification does not use incremental search eligibility.
rota.same-shift?(
  left,
  right,
) =
  match (left, right) {
    | (
        RotaShift(id: a, label: al, start: ab, finish: ae, skill: ak),
        RotaShift(id: b, label: bl, start: bb, finish: be, skill: bk),
      ) ->
      bool.and(
        eq(a, b),
        bool.and(
          text.eq?(al, bl),
          bool.and(eq(ab, bb), bool.and(eq(ae, be), rota.skill-same?(ak, bk))),
        ),
      )
  }

rota.verify(
  problem,
  assignments,
) =
  {
    let ids =
      list.map(
        assignments,
        fn (assignment) -> match assignment {
                             | RotaAssignment(shift, _) -> rota.shift-id(shift)},
      )
    bool.and(
      eq(list.length(assignments), list.length(rota.shifts(problem))),
      bool.and(
        rota.distinct?(ids),
        bool.and(
          rota.every(
            assignments,
            fn (
              assignment,
            ) ->
              match assignment {
                | RotaAssignment(shift, id) ->
                  match (
                          rota.find-person(rota.people(problem), id),
                          rota.find-shift(rota.shifts(problem), rota.shift-id(shift)),
                        ) {
                    | (Some(person), Some(original)) ->
                      bool.and(
                        rota.same-shift?(shift, original),
                        bool.and(
                          rota.available?(person, original),
                          rota.qualified?(person, original),
                        ),
                      )
                    | _ -> False}
              },
          ),
          bool.and(
            rota.every(
              rota.people(problem),
              fn (
                person,
              ) ->
                int.lte?(rota.load(rota.staff-id(person), assignments), rota.staff-limit(person)),
            ),
            rota.every(
              assignments,
              fn (
                left,
              ) ->
                rota.every(
                  assignments,
                  fn (
                    right,
                  ) ->
                    match (left, right) {
                      | (RotaAssignment(a, aid), RotaAssignment(b, bid)) ->
                        if bool.and(eq(aid, bid), bool.not(eq(rota.shift-id(a), rota.shift-id(b))))
                          then rota.rested?(a, b, rota.rest(problem))
                        else True
                    },
                ),
            ),
          ),
        ),
      ),
    )
  }

rota.solution(
  problem,
  assignments,
) =
  {
    let preference =
      list.fold(
        assignments,
        0,
        fn (
          total,
          assignment,
        ) ->
          match assignment {
            | RotaAssignment(shift, id) ->
              match rota.find-person(rota.people(problem), id) {
                | Some(person) -> add(total, rota.preference(person, shift))
                | None -> total}
          },
      )
    let squares =
      list.fold(
        rota.people(problem),
        0,
        fn (
          total,
          person,
        ) ->
          {
            let count = rota.load(rota.staff-id(person), assignments)
            add(total, mul(count, count))
          },
      )
    let penalty = mul(rota.weight(problem), squares)
    RotaSolution(assignments, preference, penalty, sub(preference, penalty))
  }

-- A relaxed lower bound on extra sum-of-squares cost: distribute remaining
-- shifts into the least-loaded non-full staff, ignoring skills/rest/availability.
rota.balance-floor(
  loads,
  remaining,
) =
  if eq(remaining, 0) then Some(0)
  else {
         let selected =
           list.fold(
             loads,
             None,
             fn (
               best,
               entry,
             ) ->
               match entry {
                 | (id, count, limit) ->
                   if int.gte?(count, limit) then best
                   else match best {
                          | None -> Some((id, count))
                          | Some((_, best-count)) ->
                            if int.lt?(count, best-count) then Some((id, count)) else best
                   }
               },
           )
         match selected {
           | None -> None
           | Some((chosen, count)) -> {
             let updated =
               list.map(
                 loads,
                 fn (
                   entry,
                 ) ->
                   match entry {
                     | (id, current, limit) ->
                       (id, if eq(id, chosen) then add(current, 1) else current, limit)
                   },
               )
             match rota.balance-floor(updated, sub(remaining, 1)) {
               | None -> None
               | Some(extra) -> Some(add(add(mul(2, count), 1), extra))
             }
           }
         }
  }

-- Scan all unfilled shifts once: select the most constrained and sum their
-- best available preference scores. Candidate sets can only shrink later.
rota.analyze(
  problem,
  todo,
  assignments,
  score,
) =
  {
    let rec scan(
      remaining,
      selected,
      preference-upper,
    ) =
      match remaining {
        | Nil -> Some((selected, preference-upper))
        | Cons(shift, rest) -> {
          let candidates = rota.candidates(problem, shift, assignments)
          match candidates {
            | Nil -> None
            | Cons(_, _) -> {
              let best-preference =
                list.fold(
                  candidates,
                  0,
                  fn (
                    best,
                    person,
                  ) ->
                    {
                      let points = rota.preference(person, shift)
                      if int.gt?(points, best) then points else best
                    },
                )
              let next =
                match selected {
                  | None -> Some((shift, candidates))
                  | Some((previous, old-candidates)) ->
                    if bool.or(
                         int.lt?(list.length(candidates), list.length(old-candidates)),
                         bool.and(
                           eq(list.length(candidates), list.length(old-candidates)),
                           int.lt?(rota.shift-id(shift), rota.shift-id(previous)),
                         ),
                       ) then Some((shift, candidates))
                    else selected}
              scan(rest, next, add(preference-upper, best-preference))
            }
          }
        }
      }
    let loads =
      list.map(
        rota.people(problem),
        fn (
          person,
        ) ->
          (
            rota.staff-id(person),
            rota.load(rota.staff-id(person), assignments),
            rota.staff-limit(person),
          ),
      )
    match (scan(todo, None, 0), rota.balance-floor(loads, list.length(todo))) {
      | (Some((Some((shift, candidates)), preferences)), Some(extra)) ->
        Some((shift, candidates, sub(add(score, preferences), mul(rota.weight(problem), extra))))
      | _ -> None
    }
  }

rota.increment(
  problem,
  person,
  shift,
  assignments,
) =
  sub(
    rota.preference(person, shift),
    mul(rota.weight(problem), add(mul(2, rota.load(rota.staff-id(person), assignments)), 1)),
  )

rota.insert-candidate(
  problem,
  shift,
  assignments,
  person,
  ordered,
) =
  match ordered {
    | Nil -> [person]
    | Cons(first, rest) -> {
      let value = rota.increment(problem, person, shift, assignments)
      let first-value = rota.increment(problem, first, shift, assignments)
      if bool.or(
           int.gt?(value, first-value),
           bool.and(eq(value, first-value), int.lt?(rota.staff-id(person), rota.staff-id(first))),
         ) then Cons(person, ordered)
      else Cons(first, rota.insert-candidate(problem, shift, assignments, person, rest))
    }
  }

rota.cannot-improve?(
  upper,
  incumbent,
) =
  match incumbent {
    | None -> False
    | Some(solution) -> int.lte?(upper, rota.solution-score(solution))
  }

rota.search(
  problem,
  frontier,
  incumbent,
  expanded,
  pruned,
  budget,
  root-upper,
) =
  if rota.cannot-improve?(root-upper, incumbent) then
    RotaReport(ProvenOptimal, incumbent, expanded, pruned, Some(root-upper))
  else match frontier {
         | Nil ->
           match incumbent {
             | None -> RotaReport(ProvenImpossible, None, expanded, pruned, None)
             | Some(solution) ->
               RotaReport(
                 ProvenOptimal,
                 incumbent,
                 expanded,
                 pruned,
                 Some(rota.solution-score(solution)),
               )}
         | Cons(node, pending) ->
           if int.gte?(expanded, budget) then
             RotaReport(BudgetStopped, incumbent, expanded, pruned, Some(root-upper))
           else match node {
                  | RotaNode(Nil, assignments, _) -> {
                    let candidate = rota.solution(problem, assignments)
                    let best =
                      match incumbent {
                        | None -> Some(candidate)
                        | Some(previous) ->
                          if int.gt?(rota.solution-score(candidate), rota.solution-score(previous))
                            then Some(candidate)
                          else incumbent}
                    rota.search(
                      problem,
                      pending,
                      best,
                      add(expanded, 1),
                      pruned,
                      budget,
                      root-upper,
                    )
                  }
                  | RotaNode(todo, assignments, score) ->
                    match rota.analyze(problem, todo, assignments, score) {
                      | None ->
                        rota.search(
                          problem,
                          pending,
                          incumbent,
                          add(expanded, 1),
                          add(pruned, 1),
                          budget,
                          root-upper,
                        )
                      | Some((shift, candidates, upper)) ->
                        if rota.cannot-improve?(upper, incumbent) then
                          rota.search(
                            problem,
                            pending,
                            incumbent,
                            add(expanded, 1),
                            add(pruned, 1),
                            budget,
                            root-upper,
                          )
                        else {
                               let ordered =
                                 list.fold(
                                   candidates,
                                   Nil,
                                   fn (
                                     items,
                                     person,
                                   ) ->
                                     rota.insert-candidate(
                                       problem,
                                       shift,
                                       assignments,
                                       person,
                                       items,
                                     ),
                                 )
                               let remaining =
                                 list.filter(
                                   todo,
                                   fn (
                                     other,
                                   ) ->
                                     bool.not(eq(rota.shift-id(shift), rota.shift-id(other))),
                                 )
                               let children =
                                 list.map(
                                   ordered,
                                   fn (
                                     person,
                                   ) ->
                                     RotaNode(
                                       remaining,
                                       Cons(
                                         RotaAssignment(shift, rota.staff-id(person)),
                                         assignments,
                                       ),
                                       add(
                                         score,
                                         rota.increment(problem, person, shift, assignments),
                                       ),
                                     ),
                                 )
                               rota.search(
                                 problem,
                                 list.append(children, pending),
                                 incumbent,
                                 add(expanded, 1),
                                 pruned,
                                 budget,
                                 root-upper,
                               )
                        }}
           }
  }

rota.solve(
  problem,
  budget,
) =
  {
    let errors = rota.valid-input(problem)
    let all-errors =
      if bool.and(int.gte?(budget, 0), int.lte?(budget, 20000)) then errors
      else list.append(errors, ["Node budget must be 0..20000."])
    match all-errors {
      | Cons(_, _) -> Err(all-errors)
      | Nil -> {
        let report =
          match rota.shifts(problem) {
            | Nil -> RotaReport(ProvenOptimal, Some(rota.solution(problem, Nil)), 0, 0, Some(0))
            | todo ->
              match rota.analyze(problem, todo, Nil, 0) {
                | None -> RotaReport(ProvenImpossible, None, 0, 1, None)
                | Some((_, _, upper)) ->
                  rota.search(problem, [RotaNode(todo, Nil, 0)], None, 0, 0, budget, upper)}}
        match report {
          | RotaReport(best: Some(solution)) ->
            if rota.verify(problem, rota.solution-assignments(solution)) then Ok(report)
            else Err(
                   [
                     "Internal solver error: the completed schedule failed independent verification.",
                   ],
                 )
          | _ -> Ok(report)
        }
      }
    }
  }
