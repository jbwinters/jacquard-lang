factorial(n) = {
  let rec go(k, acc) =
    match k {
      | 0 -> acc
      | remaining -> go(sub(remaining, 1), mul(acc, remaining))
    }
  go(n, 1)
}

greet(name) = {
  println(text.concat("hello ", name))
  text.length(name)
}
