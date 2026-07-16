broken(value) = quote {
  match value {
    | _ -> quote { value }
  }
