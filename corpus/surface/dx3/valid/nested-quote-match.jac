build-decision(candidate) =
  quote {
    match unquote(candidate) {
      | True -> quote { `op:eval-code`(unquote(candidate)) }
      | False -> quote { Hold }
    }
  }
