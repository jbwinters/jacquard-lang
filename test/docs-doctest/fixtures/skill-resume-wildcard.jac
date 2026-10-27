to-option(body) =
  handle body() {
    | return value -> Some(value)
    | abort() resume _ -> None
  }
