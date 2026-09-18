type Shift = | Shift(day: Text, start: Int, hours: Int)
span(s) = match s {
  | Shift(start: from, hours: h) -> (from, add(from, h))
}
(span(Shift(hours: 8, day: "mon", start: 9)), span(Shift("tue", 14, 4)))
