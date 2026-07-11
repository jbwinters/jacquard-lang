choose(x) = match x {
  | True -> {
    let y = int.add(x, 1)
    int.add(y, 2)
  }
  | False -> 0
}
