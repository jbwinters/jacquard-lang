effect Choice a where {
  choose : () -> Bool
}

append(xs, ys) = match xs {
                   | Nil -> ys
                   | Cons(x, rest) -> Cons(x, append(rest, ys))}

handle {
  match `op:choose`() {
    | True -> 1
    | False -> 2
  }
} {
  | return x -> Cons(x, Nil)
  | choose() resume k -> append(k(True), k(False))
}
