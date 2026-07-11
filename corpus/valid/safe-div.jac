safe-div(n, d) = match eq(d, 0) {
                   | True -> `op:abort`()
                   | False -> div(n, d)}
