opaque type Percent = Percent(value: Int)

percent.of-int(n) =
  if int.between?(n, 0, 100) then Ok(Percent(n)) else Err("out of range")
