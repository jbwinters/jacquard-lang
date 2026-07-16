broken = match True {
  | True -> quote { Ship }
  | False -> quote { Hold }
later-bad = if 1 then 2 else 3
later-good = 42
