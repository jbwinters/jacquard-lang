-- A client of three libraries whose types are opaque. It cannot build a
-- ProbValue, NelList or ReqValid directly; it holds only values that the owning
-- library checked, and prints them through the libraries' accessors.
client.prob-line(r) =
  match prob.of-real(r) {
    | Ok(p) ->
        println(
          text.concat(
            text.concat("P = ", text.from-real-fixed(prob.value(p), 3)),
            text.concat("; not P = ", text.from-real-fixed(prob.value(prob.complement(p)), 3))))
    | Err(message) -> println(text.concat("refused: ", message))
  }

client.nel-line(xs) =
  match nel.of-list(xs) {
    | Some(n) ->
        println(
          text.concat(
            text.concat("first = ", text.from-int(nel.head(n))),
            text.concat(
              "; doubled length = ",
              text.from-int(list.length(nel.to-list(nel.map(n, fn (x) -> int.mul(x, 2))))))))
    | None -> println("refused: the list is empty")
  }

client.req-line(name, email, age) =
  match req.validate(name, email, age) {
    | Ok(r) -> println(text.concat(text.concat("welcome ", req.name(r)), text.concat(" <", text.concat(req.email(r), ">"))))
    | Err(why) -> println(text.concat("refused: ", req.reason(why)))
  }

client.demo() =
  {
    println("ABSTRACT TYPES: values a client holds were checked by their library")
    list.each([0.25, 1.0, 1.5, real.div(0.0, 0.0)], client.prob-line)
    match prob.of-real(0.5) {
      | Ok(p) -> println(text.concat("both halves: ", text.from-real-fixed(prob.value(prob.both(p, p)), 3)))
      | Err(message) -> println(message)
    }
    list.each([[3, 1, 2], []], client.nel-line)
    client.req-line(" Ada ", "ada@example.org", 36)
    client.req-line("", "nobody@example.org", 40)
    client.req-line("Grace", "grace", 40)
    client.req-line("Tim", "tim@example.org", 9)
    match prob.of-real(0.75) {
      | Ok(p) -> println(text.concat("printed opaquely: ", debug.inspect(p)))
      | Err(message) -> println(message)
    }
  }
