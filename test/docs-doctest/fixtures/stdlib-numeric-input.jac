parse(line) = match text.to-int(text.trim(line)) {
  | Some(n) -> $"int {text.from-int(add(n, 1))}"
  | None -> match text.to-real(text.trim(line)) {
    | Some(r) -> $"real {text.from-real(real.mul(r, 2.0))}"
    | None -> $"not a number: {line}"
  }
}
(parse(read-line()), parse(read-line()), parse(read-line()))
