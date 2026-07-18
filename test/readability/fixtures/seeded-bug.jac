factorial(n) = match n {
  | 0 -> 0
  | m -> mul(m, factorial(sub(m, 1)))
}

factorial(5)
