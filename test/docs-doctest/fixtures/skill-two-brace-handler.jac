type Direction =
  | Up
  | Down

risky() = abort()

safe() = 1

attempt(direction) =
  handle { match direction { | Up -> risky() | Down -> safe() } } {
    | return value -> Some(value)
    | abort() resume _ -> None
  }

attempt(Up)

attempt(Down)
