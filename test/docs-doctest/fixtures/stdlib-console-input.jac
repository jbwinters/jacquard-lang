echo-lines() = match next-line() {
  | None -> println("<end>")
  | Some(line) -> { println($"[{line}]"); echo-lines() }
}
capture(thunk, inputs) =
  state.run(
    fn () ->
      handle thunk() {
        | return _ -> ()
        | print(message) resume k -> {
          let (remaining, output) = get()
          put((remaining, Cons(message, output)))
          k(())
        }
        | next-line() resume k -> {
          let (remaining, output) = get()
          match remaining {
            | Cons(line, more) -> { put((more, output)); k(Some(line)) }
            | Nil -> k(None)
          }
        }
      },
    (inputs, Nil),
  )
(capture(echo-lines, ["a", "", "b"]), console.scripted-input(fn () -> (next-line(), read-line(), next-line()), ["x"]))
