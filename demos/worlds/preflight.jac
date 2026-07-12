-- PREFLIGHT: a gate between a generated plan and the real world.
--
-- Distinct from agent-dream (one fixed policy, many worlds) and from
-- repair/synthesis (candidates scored on pure unit tests): here the candidates
-- ARE agent policies, the evidence IS alternate worlds, and the live policy
-- still refuses without a Net grant after the dreams pass.
--
-- Steps the transcript proves:
--   1. Three quoted plans form a discrete prior (code is data).
--   2. Weak world evidence (outage only) leaves every plan alive.
--   3. Sharp world evidence (refund / outage / question) proves the cautious
--      plan at probability 1; eager and hold are pruned.
--   4. code.diff renders what a reviewer should read about the rejects.
--   5. live-policy needs Net at the root — dreams never granted it.

cautious-plan = quote {
  fn () ->
    match `op:fetch`(MkRequest("http://ticket/context", "")) {
      | MkResponse(status, body) ->
        match eq(status, 200) {
          | False -> "fallback-human"
          | True ->
            match text.contains?(body, "refund") {
              | True -> "issue-refund"
              | False -> "ask-more"}}}}

eager-plan = quote {
  fn () ->
    match `op:fetch`(MkRequest("http://ticket/context", "")) {
      | MkResponse(status, body) ->
        match eq(status, 200) {
          | False -> "fallback-human"
          | True -> "issue-refund"}}}

hold-plan = quote {
  fn () ->
    match `op:fetch`(MkRequest("http://ticket/context", "")) {
      | MkResponse(status, body) ->
        match eq(status, 200) {
          | False -> "fallback-human"
          | True -> "ask-more"}}}

plan-prior() =
  Categorical(
    Cons(MkPair(cautious-plan, 0.5),
      Cons(MkPair(eager-plan, 0.3),
        Cons(MkPair(hold-plan, 0.2), Nil))))

run-plan(code) =
  {
    let f = `op:eval-code`(code)
    f()}

scripted(code, response) =
  throw.catch(
    fn () -> net.scripted(fn () -> run-plan(code), Cons(response, Nil)),
    fn (e) -> e)

text-eq?(a, b) = eq.fn(text.eq)(a, b)

-- Sharp preflight: refunds only when the body says refund, falls back on
-- outage, and asks instead of refunding ambiguous 200s.
passes-sharp?(code) =
  bool.and(text-eq?(scripted(code, MkResponse(200, "refund")), "issue-refund"),
    bool.and(text-eq?(scripted(code, MkResponse(503, "down")), "fallback-human"),
      text-eq?(scripted(code, MkResponse(200, "question")), "ask-more")))

-- Weak preflight: only the outage world. Every shipped candidate handles it.
passes-weak?(code) =
  text-eq?(scripted(code, MkResponse(503, "down")), "fallback-human")

preflight-weak() =
  {
    let plan = `op:sample`(plan-prior())
    `op:observe`(Bernoulli(match passes-weak?(plan) {
                             | True -> 1.0
                             | False -> 0.0}), True)
    plan}

preflight-sharp() =
  {
    let plan = `op:sample`(plan-prior())
    `op:observe`(Bernoulli(match passes-sharp?(plan) {
                             | True -> 1.0
                             | False -> 0.0}), True)
    plan}

posterior-weak() =
  dist.tally(dist.enumerate(fn () -> preflight-weak()), MkEq(code.eq?))

posterior-sharp() =
  dist.tally(dist.enumerate(fn () -> preflight-sharp()), MkEq(code.eq?))

surviving(table) =
  list.filter(table, fn (entry) -> match entry {
                                     | MkPair(_, p) -> real.lt?(0.0, p)})

plan-label(code) =
  match code.eq?(code, cautious-plan) {
    | True -> "cautious"
    | False ->
      match code.eq?(code, eager-plan) {
        | True -> "eager"
        | False -> "hold"}}

labeled-posterior(table) =
  list.map(surviving(table),
    fn (entry) -> match entry {
                    | MkPair(code, p) -> MkPair(plan-label(code), p)})

map-plan(table) =
  {
    let best =
      list.fold(table, MkPair(cautious-plan, 0.0),
        fn (acc, entry) -> match (acc, entry) {
                             | (MkPair(_, bp), MkPair(_, ep)) -> match real.lt?(bp, ep) {
                                                                  | True -> entry
                                                                  | False -> acc}})
    match best {
      | MkPair(code, _) -> code}}

-- The approved policy as an ordinary root function: its row is {Net}, so a
-- real run still needs --allow net even after preflight dreams used scripted
-- handlers and eval only.
live-policy() =
  match `op:fetch`(MkRequest("http://ticket/context", "")) {
    | MkResponse(status, body) ->
      match eq(status, 200) {
        | False -> "fallback-human"
        | True ->
          match text.contains?(body, "refund") {
            | True -> "issue-refund"
            | False -> "ask-more"}}}

list.length(Cons(cautious-plan, Cons(eager-plan, Cons(hold-plan, Nil))))

labeled-posterior(posterior-weak())

labeled-posterior(posterior-sharp())

code.diff(eager-plan, map-plan(posterior-sharp()))

code.diff(hold-plan, map-plan(posterior-sharp()))

live-policy()
