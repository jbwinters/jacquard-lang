{
  let c1 = `op:sample`(Bernoulli(0.5))
  let c2 = `op:sample`(Bernoulli(0.5))
  `op:observe`(Bernoulli(1.0), bool.or(c1, c2))
  c1
}
