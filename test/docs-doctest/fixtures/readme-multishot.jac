multi effect Choice where {
  choose : () -> Bool
}

handle {
  match choose() {
    | True -> 1
    | False -> 2
  }
} {
  | return x -> x
  | choose() resume continue -> add(continue(True), continue(False))
}
