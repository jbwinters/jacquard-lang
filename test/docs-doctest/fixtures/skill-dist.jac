coin-model : () ->{Dist} Bool
coin-model() = {
  let first = `op:sample`(Bernoulli(0.5))
  let second = `op:sample`(Bernoulli(0.5))
  `op:observe`(
    Bernoulli(if bool.or(first, second) then 1.0 else 0.0),
    True)
  first
}

coin-model()
