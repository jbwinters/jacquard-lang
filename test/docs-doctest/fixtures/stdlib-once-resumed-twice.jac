handle next-line() {
  | return line -> [line]
  | next-line() resume k -> list.append(k(None), k(Some("again")))
}
