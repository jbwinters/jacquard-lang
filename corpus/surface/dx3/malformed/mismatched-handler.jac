broken(body) = Some(handle body() {
  | return value -> value
])
later-bad = if 1 then 2 else 3
later-good = 42
