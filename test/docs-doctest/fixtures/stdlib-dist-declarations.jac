type Distribution a =
  | Bernoulli Real
  | Categorical(values: List (a, Real))
  | UniformInt Int Int

effect Dist a where {
  sample : (Distribution a) -> a
  observe : (Distribution a, a) -> ()
}
