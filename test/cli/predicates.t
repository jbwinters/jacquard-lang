List-based predicates and closed intervals (SX.30, docs/stdlib.md). They are
ordinary prelude terms, so the native compiler builds them like any other
program and the two engines agree.

  $ export JACQUARD_PRELUDE=$PWD/../../prelude
  $ export JACQUARD_RUNTIME=$PWD/../../runtime
  $ cat > predicates.jac <<'J'
  > positive(n) = int.gt?(n, 0)
  > (bool.all([]), bool.all([True, True]), bool.all([True, False, True]))
  > (bool.any([]), bool.any([False, True]), bool.any([False, False]))
  > (list.all?([1, 2, 3], positive), list.all?([1, -2, 3], positive), list.all?([], positive))
  > (list.any?([-1, 2], positive), list.any?([-1, -2], positive), list.any?([], positive))
  > (int.between?(1, 1, 5), int.between?(5, 1, 5), int.between?(0, 1, 5), int.between?(6, 1, 5))
  > (real.between?(2.0, 1.0, 2.0), real.between?(2.5, 1.0, 2.0))
  > J
  $ jacquard run predicates.jac | tee interpreted.out
  (true, true, false)
  (false, true, false)
  (true, false, true)
  (true, false, false)
  (true, true, false, false)
  (true, false)
  $ jacquard build predicates.jac -o predicates > /dev/null && ./predicates | cmp - interpreted.out && echo same
  same

The rota optimizer's input validation, shift comparison and independent
solution check are flat `bool.all` lists. The validation accepts a valid staff
record and refuses each single-field violation, one message per invalid record:

  $ R=../../demos/applications/rota-optimizer
  $ grep -c 'bool.all(' "$R/model.jac"
  5
  $ cat > variants.jac <<'J'
  > check(staff) = rota.valid-input(RotaProblem(staff: [staff], shifts: rota.week-shifts(), rest: 12, fairness: 1))
  > check(RotaStaff(0, "Ada", [GeneralSkill], [0, 1], 3, [MkPair(0, 5)]))
  > check(RotaStaff(-1, "Ada", [GeneralSkill], [0, 1], 3, [MkPair(0, 5)]))
  > check(RotaStaff(100, "Ada", [GeneralSkill], [0, 1], 3, [MkPair(0, 5)]))
  > check(RotaStaff(0, "  ", [GeneralSkill], [0, 1], 3, [MkPair(0, 5)]))
  > check(RotaStaff(0, "Ada", [GeneralSkill], [0, 1], 15, [MkPair(0, 5)]))
  > check(RotaStaff(0, "Ada", [GeneralSkill], [0, 1], -1, [MkPair(0, 5)]))
  > check(RotaStaff(0, "Ada", [GeneralSkill], [0, 0], 3, [MkPair(0, 5)]))
  > check(RotaStaff(0, "Ada", [GeneralSkill], [99], 3, [MkPair(0, 5)]))
  > check(RotaStaff(0, "Ada", [GeneralSkill], [0, 1], 3, [MkPair(0, 5), MkPair(0, 3)]))
  > check(RotaStaff(0, "Ada", [GeneralSkill], [0, 1], 3, [MkPair(99, 5)]))
  > check(RotaStaff(0, "Ada", [GeneralSkill], [0, 1], 3, [MkPair(0, 11)]))
  > check(RotaStaff(0, "Ada", [GeneralSkill], [0, 1], 3, [MkPair(0, -1)]))
  > J
  $ cat "$R/model.jac" "$R/fixtures.jac" "$R/report.jac" variants.jac > rota-variants.jac
  $ jacquard run rota-variants.jac > verdicts.out
  $ head -1 verdicts.out
  nil
  $ grep -c '^cons("Staff need IDs 0..99' verdicts.out
  11
