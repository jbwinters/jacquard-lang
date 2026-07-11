first-child-head(value) = match value {
  | Some((head, children)) -> head
  | None -> 0
}

first-child-head(Some((7, [8, 9])))
