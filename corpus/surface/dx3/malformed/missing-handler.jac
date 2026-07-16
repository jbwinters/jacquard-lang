broken(body) = handle body() {
  | return value -> Some(value)
  | `op:abort`() resume _ -> None
later-bad = if 1 then 2 else 3
later-good = 42
