type Bool =
  | False
  | True

type Ordering =
  | Less
  | Equal
  | Greater

type Option a =
  | None
  | Some a

type Result e a =
  | Err e
  | Ok a

type List a =
  | Nil
  | Cons a (List a)
