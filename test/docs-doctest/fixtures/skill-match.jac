type Option a =
  | None
  | Some a

head(xs) =
  match xs {
    | Nil -> None
    | Cons(x, rest) as whole -> Some((x, rest, whole))
  }
