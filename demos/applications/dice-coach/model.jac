-- A finite-horizon, fair-die decision model. No root randomness is needed:
-- dist.enumerate handles every possible roll inside Jacquard.
type DicePolicy = | Cautious | Bold | Optimal

type DiceAction = | Bank | Roll

type DiceOutcome = | Banked Int | Busted

dice.real(n) = match text.to-real(text.from-int(n)) {
                 | Some(value) -> value
                 | None -> 0.0}

dice.valid?(
  pot,
  rolls,
) =
  bool.and(
    bool.and(int.gte?(pot, 0), int.lte?(pot, 60)),
    bool.and(int.gte?(rolls, 0), int.lte?(rolls, 3)),
  )

-- Bellman recurrence: compare banking now with all six next-roll outcomes.
-- A bust contributes zero; surviving faces allow a fresh optimal decision.
dice.optimal-value(
  pot,
  rolls,
) =
  if int.lte?(rolls, 0) then dice.real(pot)
  else {
         let rolling =
           real.div(
             list.fold(
               [2, 3, 4, 5, 6],
               0.0,
               fn (
                 total,
                 face,
               ) ->
                 real.add(total, dice.optimal-value(add(pot, face), sub(rolls, 1))),
             ),
             6.0,
           )
         if real.gt?(rolling, dice.real(pot)) then rolling else dice.real(pot)
  }

dice.roll-value(
  pot,
  rolls,
) =
  real.div(
    list.fold(
      [2, 3, 4, 5, 6],
      0.0,
      fn (total, face) -> real.add(total, dice.optimal-value(add(pot, face), sub(rolls, 1))),
    ),
    6.0,
  )

dice.choose(
  policy,
  pot,
  rolls,
) =
  if int.lte?(rolls, 0) then Bank
  else match policy {
         | Cautious -> if int.gte?(pot, 12) then Bank else Roll
         | Bold -> if int.gte?(pot, 24) then Bank else Roll
         | Optimal -> if real.gt?(dice.roll-value(pot, rolls), dice.real(pot)) then Roll else Bank
  }

dice.play(
  policy,
  pot,
  rolls,
) =
  match dice.choose(policy, pot, rolls) {
    | Bank -> Banked(pot)
    | Roll -> {
      let face = sample(UniformInt(1, 6))
      if eq(face, 1) then Busted else dice.play(policy, add(pot, face), sub(rolls, 1))
    }
  }

dice.outcome-same?(
  a,
  b,
) =
  match (a, b) {
    | (Busted, Busted) -> True
    | (Banked(x), Banked(y)) -> eq(x, y)
    | _ -> False
  }

dice.outcome-eq = MkEq(dice.outcome-same?)

dice.distribution(
  policy,
  pot,
  rolls,
) =
  dist.enumerate(fn () -> dice.play(policy, pot, rolls)) |> dist.tally(dice.outcome-eq)

dice.mass(
  table,
) =
  list.fold(
    table,
    0.0,
    fn (total, entry) -> match entry {
                           | MkPair(_, probability) -> real.add(total, probability)},
  )

dice.expected(
  table,
) =
  list.fold(
    table,
    0.0,
    fn (
      total,
      entry,
    ) ->
      match entry {
        | MkPair(Banked(points), probability) ->
          real.add(total, real.mul(dice.real(points), probability))
        | MkPair(Busted, _) -> total
      },
  )

dice.bust-risk(
  table,
) =
  list.fold(
    table,
    0.0,
    fn (
      total,
      entry,
    ) ->
      match entry {
        | MkPair(Busted, probability) -> real.add(total, probability)
        | _ -> total
      },
  )

dice.policy-name(
  policy,
) =
  match policy {
    | Cautious -> "cautious (bank at 12)"
    | Bold -> "bold (bank at 24)"
    | Optimal -> "optimal expected score"
  }

dice.action-name(action) = match action {
                             | Bank -> "BANK"
                             | Roll -> "ROLL"}

dice.advice(
  pot,
  rolls,
) =
  if dice.valid?(pot, rolls) then Ok(dice.choose(Optimal, pot, rolls))
  else Err("Use a pot from 0 to 60 and remaining rolls from 0 to 3.")

dice.show-policy(
  policy,
  pot,
  rolls,
) =
  {
    let table = dice.distribution(policy, pot, rolls)
    println($"  {dice.policy-name(policy)}: {dice.action-name(dice.choose(policy, pot, rolls))}")
    println(
      $"    expected banked points = {display.fixed3(dice.expected(table))}; bust probability = {display.percent(dice.bust-risk(table))}",
    )
  }

dice.show(
  pot,
  rolls,
) =
  match dice.advice(pot, rolls) {
    | Err(message) -> println(message)
    | Ok(action) -> {
      println(
        $"Pot {text.from-int(pot)}, at most {text.from-int(rolls)} more rolls: {dice.action-name(action)}",
      )
      list.each([Cautious, Bold, Optimal], fn (policy) -> dice.show-policy(policy, pot, rolls))
    }
  }

dice.demo() =
  {
    println("PUSH-YOUR-LUCK DICE COACH")
    println("Fair d6: 1 loses the unbanked pot; 2..6 add points. Bank after the final roll.")
    println("Optimal means maximum expected points, not minimum chance of losing.")
    println("All finite paths are enumerated; displayed values are rounded to three decimals.")
    list.each([0, 10, 19, 20, 24, 30], fn (pot) -> dice.show(pot, 3))
    println("With one roll left, rolling is worth (5 * pot + 20) / 6.")
    println("At pot 20 this equals banking; the coach banks on ties.")
  }

dice.interactive() =
  {
    println("PUSH-YOUR-LUCK DICE COACH")
    println("A 1 busts; 2..6 add points. The final surviving roll banks automatically.")
    let pot-text = console.ask("Unbanked points (0..60)?")
    let rolls-text = console.ask("Remaining rolls (0..3)?")
    match (text.to-int(text.trim(pot-text)), text.to-int(text.trim(rolls-text))) {
      | (Some(pot), Some(rolls)) -> dice.show(pot, rolls)
      | _ -> println("Please enter whole numbers. Run again to try another position.")
    }
  }
