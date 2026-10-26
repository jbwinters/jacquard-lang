report(result) =
  match result {
    | Ok(value) -> {
        println("ok")
        value
      }
    | Err(message) -> {
        println(message)
        0
      }
  }
