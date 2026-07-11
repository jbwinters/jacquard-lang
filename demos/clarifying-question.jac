expectation(model) =
  list.fold(dist.enumerate(model), 0.0,
    fn (acc, e) -> match e {
                     | MkPair(u, p) -> add-real(acc, mul-real(u, p))})

intent-dist() = Bernoulli(0.35)

answer-label(needs-audit) = match needs-audit {
                              | True -> "needs-audit"
                              | False -> "quick-answer"}

fast-answer-utility(needs-audit) = match needs-audit {
                                     | True -> -6.0
                                     | False -> 8.0}

audit-first-utility(needs-audit) = match needs-audit {
                                     | True -> 10.0
                                     | False -> 4.0}

best-action-for-answer(needs-audit) =
  match lt-real(fast-answer-utility(needs-audit), audit-first-utility(needs-audit)) {
    | True -> "audit-first"
    | False -> "fast-answer"}

best-utility-for-answer(needs-audit) =
  match lt-real(fast-answer-utility(needs-audit), audit-first-utility(needs-audit)) {
    | True -> audit-first-utility(needs-audit)
    | False -> fast-answer-utility(needs-audit)}

eu-fast-answer() =
  expectation(
    fn () -> {
               let needs-audit = `op:sample`(intent-dist())
               fast-answer-utility(needs-audit)})

eu-audit-first() =
  expectation(
    fn () -> {
               let needs-audit = `op:sample`(intent-dist())
               audit-first-utility(needs-audit)})

act-now-utility() =
  match lt-real(eu-fast-answer(), eu-audit-first()) {
    | True -> eu-audit-first()
    | False -> eu-fast-answer()}

act-now-action() =
  match lt-real(eu-fast-answer(), eu-audit-first()) {
    | True -> "audit-first"
    | False -> "fast-answer"}

informed-utility() =
  expectation(
    fn () -> {
               let needs-audit = `op:sample`(intent-dist())
               best-utility-for-answer(needs-audit)})

question-value() = sub-real(informed-utility(), act-now-utility())

ask-utility(interruption-cost) = sub-real(informed-utility(), interruption-cost)

policy(interruption-cost) =
  match lt-real(interruption-cost, question-value()) {
    | True -> "ask-user"
    | False -> act-now-action()}

answer-distribution() =
  dist.tally(
    dist.enumerate(
      fn () -> {
                 let needs-audit = `op:sample`(intent-dist())
                 answer-label(needs-audit)}), text.eq)

informed-action-distribution() =
  dist.tally(
    dist.enumerate(
      fn () -> {
                 let needs-audit = `op:sample`(intent-dist())
                 best-action-for-answer(needs-audit)}), text.eq)

(eu-fast-answer(), eu-audit-first(), act-now-utility())

(informed-utility(), question-value())

answer-distribution()

informed-action-distribution()

(policy(1.0), policy(3.0), ask-utility(1.0), ask-utility(3.0))
