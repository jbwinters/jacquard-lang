rota.day-name(
  day,
) =
  match day {
    | 0 -> "Mon"
    | 1 -> "Tue"
    | 2 -> "Wed"
    | 3 -> "Thu"
    | 4 -> "Fri"
    | 5 -> "Sat"
    | _ -> "Sun"
  }

rota.week-shifts() =
  list.map(
    list.range(0, 14),
    fn (
      id,
    ) ->
      {
        let day = div(id, 2)
        let evening = eq(mod(id, 2), 1)
        let start = add(mul(day, 24), if evening then 16 else 8)
        RotaShift(
          id: id,
          label: text.concat(rota.day-name(day), if evening then " PM" else " AM"),
          start: start,
          finish: add(start, 8),
          skill: if evening then LeadSkill else GeneralSkill,
        )
      },
  )

rota.person-name(
  id,
) =
  match id {
    | 0 -> "Ada"
    | 1 -> "Bo"
    | 2 -> "Cleo"
    | 3 -> "Dev"
    | 4 -> "Emi"
    | 5 -> "Finn"
    | 6 -> "Gus"
    | _ -> "Hana"
  }

rota.week-staff() =
  list.map(
    list.range(0, 8),
    fn (
      id,
    ) ->
      {
        let skills = if eq(mod(id, 2), 0) then [GeneralSkill, LeadSkill] else [GeneralSkill]
        let unavailable = match id {
                            | 1 -> [8]
                            | 4 -> [3]
                            | 6 -> [13]
                            | _ -> []}
        let available =
          list.filter(list.range(0, 14), fn (shift) -> bool.not(rota.member?(shift, unavailable)))
        let preferences =
          list.map(
            list.range(0, 14),
            fn (
              shift,
            ) ->
              {
                let favorite = mod(add(shift, 1), 8)
                let distance =
                  if int.gte?(id, favorite) then sub(id, favorite) else sub(favorite, id)
                MkPair(shift, if eq(distance, 0) then 10 else sub(8, distance))
              },
          )
        RotaStaff(
          id: id,
          name: rota.person-name(id),
          skills: skills,
          available: available,
          limit: 3,
          preferences: preferences,
        )
      },
  )

rota.week() =
  RotaProblem(staff: rota.week-staff(), shifts: rota.week-shifts(), rest: 12, fairness: 2)

rota.tiny() =
  {
    let shifts =
      list.map(
        list.range(0, 4),
        fn (
          id,
        ) ->
          RotaShift(
            id: id,
            label: $"Day {text.from-int(add(id, 1))}",
            start: mul(id, 24),
            finish: add(mul(id, 24), 8),
            skill: GeneralSkill,
          ),
      )
    let people =
      [
        RotaStaff(
          0,
          "Alex",
          [GeneralSkill],
          [0, 1, 2, 3],
          4,
          [MkPair(0, 10), MkPair(1, 10), MkPair(2, 10), MkPair(3, 10)],
        ),
        RotaStaff(
          1,
          "Blair",
          [GeneralSkill],
          [0, 1, 2, 3],
          4,
          [MkPair(0, 8), MkPair(1, 8), MkPair(2, 8), MkPair(3, 8)],
        ),
      ]
    RotaProblem(staff: people, shifts: shifts, rest: 8, fairness: 2)
  }

-- Every shift has a qualified available candidate and enough nominal capacity,
-- but the only lead cannot legally cover both intervals with eight hours' rest.
rota.rest-conflict() =
  RotaProblem(
    [
      RotaStaff(0, "Only lead", [LeadSkill], [0, 1], 2, []),
      RotaStaff(1, "General staff", [GeneralSkill], [0, 1], 2, []),
    ],
    [
      RotaShift(id: 0, label: "First lead shift", start: 8, finish: 16, skill: LeadSkill),
      RotaShift(id: 1, label: "Second lead shift", start: 20, finish: 28, skill: LeadSkill),
    ],
    8,
    2,
  )

rota.configure(
  problem,
  rest,
  fairness,
  excluded,
) =
  match problem {
    | RotaProblem(staff: people, shifts: shifts) -> {
      let updated =
        list.map(
          people,
          fn (
            person,
          ) ->
            match person {
              | RotaStaff(
                  id: id,
                  name: name,
                  skills: skills,
                  available: available,
                  limit: limit,
                  preferences: preferences,
                ) ->
                RotaStaff(
                  id: id,
                  name: name,
                  skills: skills,
                  available: if eq(id, excluded) then Nil else available,
                  limit: limit,
                  preferences: preferences,
                )
            },
        )
      RotaProblem(staff: updated, shifts: shifts, rest: rest, fairness: fairness)
    }
  }
