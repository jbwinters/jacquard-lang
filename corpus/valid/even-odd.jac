even(n) = match n {
            | 0 -> True
            | m -> odd(sub(m, 1))}
odd(n) = match n {
           | 0 -> False
           | m -> even(sub(m, 1))}
