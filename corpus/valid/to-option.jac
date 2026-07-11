to-option(body) = handle body() {
                    | return x -> Some(x)
                    | abort() resume k -> None}
