response-worlds() =
  Categorical(
    Cons(MkPair(MkResponse(200, "refund"), 0.55),
      Cons(MkPair(MkResponse(200, "question"), 0.25),
        Cons(MkPair(MkResponse(503, "down"), 0.2), Nil))))

support-policy() =
  match `op:fetch`(MkRequest("http://ticket/context", "")) {
    | MkResponse(status, body) ->
      match eq(status, 200) {
        | False -> "fallback-human"
        | True ->
          match text.contains?(body, "refund") {
            | True -> "issue-refund"
            | False -> "ask-more"}}}

net.dream(thunk, world-model) = {
  let response = `op:sample`(world-model)
  handle thunk() {
    | return x -> x
    | fetch(_) resume k -> k(response)}
}

scripted-refund() =
  throw.catch(
    fn () -> net.scripted(fn () -> support-policy(), Cons(MkResponse(200, "refund"), Nil)),
    fn (e) -> e)

scripted-outage() =
  throw.catch(fn () -> net.scripted(fn () -> support-policy(), Cons(MkResponse(503, "down"), Nil)),
    fn (e) -> e)

dream-outcomes() =
  dist.tally(dist.enumerate(fn () -> net.dream(fn () -> support-policy(), response-worlds())),
    text.eq)

scripted-refund()

scripted-outage()

dream-outcomes()
