-- Effects are confined to this small shell; command processing is pure.
nb.loop(
  book,
) =
  {
    let line = console.ask("nb>")
    if text.empty?(line) then println("bye (empty input or EOF)")
    else {
           let response = nb.execute(book, line)
           if text.empty?(nb.response-output(response)) then ()
           else println(nb.response-output(response))
           if nb.response-stop?(response) then () else nb.loop(nb.response-book(response))
    }
  }

nb.main() = {
              println("Reactive formula notebook. Type help for commands.")
              nb.loop(nb.empty())}

nb.script(
  book,
  lines,
) =
  match lines {
    | Nil -> book
    | Cons(line, rest) -> {
      println(text.concat("nb> ", line))
      let response = nb.execute(book, line)
      if text.empty?(nb.response-output(response)) then ()
      else println(nb.response-output(response))
      if nb.response-stop?(response) then nb.response-book(response)
      else nb.script(nb.response-book(response), rest)
    }
  }
