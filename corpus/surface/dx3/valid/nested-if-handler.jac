guarded-run(body, condition) =
  handle {
    if condition then {
      body()
    } else {
      `op:abort`()
    }
  } {
    | return value -> Some(value)
    | `op:abort`() resume unused -> None
  }
