first-child-head(value) = match value {
                            | Some((head, children)) -> head
                            | _ -> 0}
