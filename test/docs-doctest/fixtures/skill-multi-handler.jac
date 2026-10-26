multi effect Choice where {
  choose : () -> Bool
}

all-choices(body) =
  handle body() {
    | return value -> [value]
    | choose() resume continue ->
        list.append(continue(True), continue(False))
  }

all-choices(fn () -> (choose(), choose()))
