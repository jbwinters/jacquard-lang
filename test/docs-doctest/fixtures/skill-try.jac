parse-age(raw) =
  match text.to-int(raw) {
    | Some(n) -> if int.between?(n, 0, 150) then Ok(n) else Err($"out of range: {raw}")
    | None -> Err($"not a number: {raw}")
  }

total-age(a, b) = {
  let x = try parse-age(a)
  let y = try parse-age(b)
  Ok(add(x, y))
}

total-age("30", "12")

total-age("30", "abc")
