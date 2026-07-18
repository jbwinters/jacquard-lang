adjust(n) = match int.gt?(n, 4) {
  | True -> sub(n, 2)
  | False -> add(n, 3)
}

(adjust(2), adjust(7))
