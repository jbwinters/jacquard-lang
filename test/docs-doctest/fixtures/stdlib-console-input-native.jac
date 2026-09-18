loop(count) = match next-line() {
  | None -> { println($"end of input after {text.from-int(count)} entries"); count }
  | Some(line) -> match text.trim(line) {
    | "" -> loop(count)
    | "quit" -> { println("bye"); count }
    | entry -> { println($"entry: {entry}"); loop(add(count, 1)) }
  }
}
loop(0)
