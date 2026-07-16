broken = quote {
  match True {
    | True -> quote { Hold }
    | False -> quote { Ship }
  }
later-bad = if 1 then 2 else 3
later-good = 42
