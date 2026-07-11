count-words(s) =
  list.fold(text.split(text.trim(s), " "), map.empty(text.ord),
    fn (m, w) ->
      match text.empty?(w) {
        | True -> m
        | False -> map.update(m, w, fn (cur) -> Some(add(1, option.with-default(cur, 0))))})

top(m, n) =
  list.take(
    list.sort(map.fold(m, Nil, fn (acc, w, c) -> Cons((w, c), acc)),
      ord.reverse(ord.on-second(int.ord))), n)

show-entry((w, c)) = println(text.concat(w, text.concat(": ", text.from-int(c))))

main() = list.each(top(count-words(console.ask("text?")), 3), show-entry)

main()
