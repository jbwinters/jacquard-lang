-- Replace these declarations with your own data. There is no separate config
-- parser: the fixture itself is checked Jacquard source.
my-rota() =
  {
    let people =
      [
        RotaStaff(0, "Sam", [GeneralSkill], [0, 1], 2, [MkPair(0, 10), MkPair(1, 0)]),
        RotaStaff(1, "Rae", [GeneralSkill], [0, 1], 2, [MkPair(0, 0), MkPair(1, 10)]),
      ]
    let shifts =
      [RotaShift(0, "Mon AM", 8, 16, GeneralSkill), RotaShift(1, "Tue AM", 32, 40, GeneralSkill)]
    RotaProblem(staff: people, shifts: shifts, rest: 12, fairness: 1)
  }

rota.show(my-rota(), 200)
