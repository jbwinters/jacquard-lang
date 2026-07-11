candidates() =
  `op:sample`(
    Categorical(
      Cons(MkPair(quote { fn (x) -> add(x, 1) }, 0.4),
        Cons(MkPair(quote { fn (x) -> add(x, 2) }, 0.3),
          Cons(MkPair(quote { fn (x) -> sub(x, 1) }, 0.2),
            Cons(MkPair(quote { fn (x) -> 1 }, 0.1), Nil))))))

passes?(code, spec) =
  {
    let f = `op:eval-code`(code)
    list.fold(spec, True,
      fn (acc, example) ->
        match example {
          | (input, expected) -> bool.and(acc, eq(f(input), expected))})}

synthesize(spec) =
  {
    let code = candidates()
    `op:observe`(Bernoulli(match passes?(code, spec) {
                             | True -> 1.0
                             | False -> 0.0}), True)
    code}

posterior-over-programs(spec) =
  dist.tally(dist.enumerate(fn () -> synthesize(spec)), MkEq(code.eq?))

weak-spec() = Cons((0, 1), Nil)

sharp-spec() = Cons((0, 1), Cons((3, 4), Nil))
