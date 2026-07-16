-- Bayesian release-risk advisor.
-- The policy is written once against Telemetry, then interpreted either from a
-- concrete snapshot or as a probabilistic world model for incident diagnosis.

type Health =
  | Healthy
  | Degraded
  | Down

type Decision =
  | Ship
  | Canary(percent: Int)
  | Hold(reason: Text)

type Assessment =
  | Assessment(
      inventory: Health,
      payments: Health,
      spike: Bool,
      decision: Decision)

multi effect Telemetry where {
  inventory-health : () -> Health
  payments-health : () -> Health
  error-spike? : () -> Bool
}

-- A pure, reviewable release policy.
decide : (Health, Health, Bool) ->{} Decision
decide(inventory, payments, spike) =
  match (inventory, payments, spike) {
    | (_, Down, _) -> Hold("payments-down")
    | (_, Degraded, _) -> Canary(5)
    | (Down, Healthy, _) -> Hold("inventory-down")
    | (Degraded, Healthy, _) -> Canary(10)
    | (Healthy, Healthy, True) -> Canary(5)
    | (Healthy, Healthy, False) -> Ship
  }

release-assessment : () ->{Telemetry} Assessment
release-assessment() = {
  let inventory = inventory-health()
  let payments = payments-health()
  let spike = error-spike?()
  Assessment(inventory, payments, spike, decide(inventory, payments, spike))
}

-- Deterministic interpretation: production snapshot, fixture, or replay.
with-snapshot(inventory, payments, spike, body) =
  handle body() {
    | return value -> value
    | inventory-health() resume continue -> continue(inventory)
    | payments-health() resume continue -> continue(payments)
    | error-spike?() resume continue -> continue(spike)
  }

health-dist(healthy-weight, degraded-weight, down-weight) =
  Categorical([
    MkPair(Healthy, healthy-weight),
    MkPair(Degraded, degraded-weight),
    MkPair(Down, down-weight)
  ])

-- Probabilistic interpretation: uncertain telemetry becomes Dist choices.
with-risk-model(body) =
  handle body() {
    | return value -> value
    | inventory-health() resume continue ->
        continue(`op:sample`(health-dist(0.85, 0.10, 0.05)))
    | payments-health() resume continue ->
        continue(`op:sample`(health-dist(0.90, 0.08, 0.02)))
    | error-spike?() resume continue ->
        continue(`op:sample`(Bernoulli(0.06)))
  }

checkout-failure-prob(snapshot) =
  match snapshot {
    | Assessment(_, Down, _, _) -> 0.95
    | Assessment(_, Degraded, _, _) -> 0.35
    | Assessment(Down, Healthy, _, _) -> 0.80
    | Assessment(Degraded, Healthy, _, _) -> 0.25
    | Assessment(Healthy, Healthy, True, _) -> 0.20
    | Assessment(Healthy, Healthy, False, _) -> 0.01
  }

current-snapshot() =
  with-snapshot(
    Healthy,
    Degraded,
    False,
    fn () -> release-assessment())

-- Condition the world model on a failed checkout and infer the likely action.
conditioned-release-risk : () ->{Dist} Decision
conditioned-release-risk() = {
  let snapshot = with-risk-model(fn () -> release-assessment())
  `op:observe`(Bernoulli(checkout-failure-prob(snapshot)), True)
  match snapshot {
    | Assessment(_, _, _, decision) -> decision
  }
}

-- --- demo driver ---

conditioned-release-risk()
