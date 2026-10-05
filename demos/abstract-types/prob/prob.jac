-- A probability as an opaque type: every ProbValue lies in [0, 1], because only
-- this project can construct one and every constructor below keeps the bound.
opaque type ProbValue = ProbValue(value: Real)

-- NaN fails both comparisons, so it is rejected with every out-of-range value.
prob.of-real(r) =
  if real.between?(r, 0.0, 1.0) then Ok(ProbValue(r)) else Err("a probability lies in [0, 1]")

prob.value(p) = match p { | ProbValue(v) -> v }

prob.complement(p) = ProbValue(real.sub(1.0, prob.value(p)))

-- the probability that two independent events both happen stays in [0, 1]
prob.both(a, b) = ProbValue(real.mul(prob.value(a), prob.value(b)))
