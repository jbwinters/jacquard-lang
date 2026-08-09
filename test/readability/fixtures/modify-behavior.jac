discount(total) = match int.gt?(total, 100) {
  | True -> sub(total, 20)
  | False -> total
}

discount(120)
