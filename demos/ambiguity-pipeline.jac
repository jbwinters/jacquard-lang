extracted-date() =
  Categorical(
    Cons(MkPair("Mar 4, 2025", 0.56),
      Cons(MkPair("Apr 3, 2025", 0.41), Cons(MkPair("Unknown", 0.03), Nil))))

same-text-prob(a, b) = match eq.fn(text.eq)(a, b) {
                         | True -> 1.0
                         | False -> 0.0}

route-for-date(date) =
  match eq.fn(text.eq)(date, "Unknown") {
    | True -> "ask-human"
    | False ->
      match eq.fn(text.eq)(date, "Mar 4, 2025") {
        | True -> "escalate-overdue"
        | False -> "schedule-followup"}}

date-posterior() = dist.tally(dist.enumerate(fn () -> `op:sample`(extracted-date())), text.eq)

routing-posterior() =
  dist.tally(
    dist.enumerate(fn () -> {
                              let date = `op:sample`(extracted-date())
                              route-for-date(date)}), text.eq)

after-click-apr3() =
  dist.tally(
    dist.enumerate(
      fn () ->
        {
          let date = `op:sample`(extracted-date())
          `op:observe`(Bernoulli(same-text-prob(date, "Apr 3, 2025")), True)
          route-for-date(date)}), text.eq)

date-posterior()

routing-posterior()

after-click-apr3()
