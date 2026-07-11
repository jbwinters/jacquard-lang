recover-abort(body) = handle body() {
                        | return value -> Some(value)
                        | abort() resume k -> None}
