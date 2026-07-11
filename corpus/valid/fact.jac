fact(n) = match n {
            | 0 -> 1
            | m -> mul(m, fact(sub(m, 1)))}
