# GM.20 Posterior-Risk Semantics

- Decision date: 2026-07-23
- Status: owner-approved design; not implemented or shipped
- Applies to: a future, separately versioned G5 exact-posterior adapter
- Does not change: deterministic Workspace v0 governance

## Decision

Jacquard may project an exact finite posterior over the existing risk order
into one conservative `GovernanceAssessmentV0`. The projection may raise the
baseline risk and may never lower it. The existing policy and gate then consume
that effective assessment without reinterpretation.

The first version admits exactly two projection rules:

```text
WorstCase
UpperTail(max-mass)
```

`AlwaysAskBelow` is rejected from this version. Approximate inference is
non-authorizing evidence only.

This boundary follows the product architecture already chosen for governed
membranes: probabilistic judgment is replaceable evidence outside the small
deterministic identity, authority, consent, ordering, and execution boundary.

## Vocabulary

The schemas below specify future versioned values. They are not new kernel
forms, current prelude declarations, or permission to reinterpret an existing
carrier.

```text
type RiskWeightsV1 =
  | RiskWeightsV1(
      low: Real,
      medium: Real,
      high: Real,
      forbidden: Real)

type RiskBeliefV1 =
  | RiskBeliefV1(
      low: Real,
      medium: Real,
      high: Real,
      forbidden: Real)

type PosteriorRuleV1 =
  | WorstCase
  | UpperTail(max-mass: Real)
```

The order is the existing order:

```text
Low < Medium < High < Forbidden
```

`RiskWeightsV1` is the exact four-class result collected from finite exhaustive
inference. `RiskBeliefV1` is its canonical normalized projection. A seeded or
otherwise approximate result must use a visibly different
`non-authorizing-approximate-evidence-v1` carrier and cannot be substituted for
either value.

## Numeric contract

All calculations use IEEE-754 binary64 values in round-to-nearest,
ties-to-even mode. Implementations must not contract the specified operations
into fused operations.

Each raw weight must be finite and nonnegative. Canonical identity turns
`-0.0` into `+0.0`, consistently with `HASH_V0`. At least one weight must be
strictly positive. A negative value, NaN, either infinity, or four zeroes is an
invalid posterior.

Normalization is evaluated in this exact order:

```text
M  = max(wLow, wMedium, wHigh, wForbidden)

qLow       = fl(wLow       / M)
qMedium    = fl(wMedium    / M)
qHigh      = fl(wHigh      / M)
qForbidden = fl(wForbidden / M)

S = fl(fl(fl(qLow + qMedium) + qHigh) + qForbidden)

pLow       = fl(qLow       / S)
pMedium    = fl(qMedium    / S)
pHigh      = fl(qHigh      / S)
pForbidden = fl(qForbidden / S)
```

The maximum and additions follow risk order. Scaling by `M` prevents a finite
raw sum from overflowing before normalization. Every intermediate and result
must remain finite and within its expected nonnegative domain.

If a raw weight is strictly positive but its normalized probability is zero,
normalization fails. Underflow must not erase possible support, especially a
higher-risk class.

There is no hidden comparison epsilon. `max-mass` is the only accepted
uncertainty tolerance. It must be finite and satisfy:

```text
0.0 <= max-mass < 1.0
```

Boundary comparisons use exact binary64 `<=`. The raw and normalized tuples
are both identity-bearing evidence.

## Projection rules

### WorstCase

`WorstCase` returns the highest risk whose raw weight is strictly positive.
It inspects raw support, not rounded normalized support.

```text
posterior-risk =
  max { r | raw-weight(r) > 0.0 }
```

### UpperTail

`Forbidden` is not tolerance-discardable. Any strictly positive raw
`Forbidden` weight returns `Forbidden`, regardless of `max-mass`.

Otherwise calculate:

```text
tail(Low)    = fl(pMedium + pHigh)
tail(Medium) = pHigh
tail(High)   = 0.0
```

`UpperTail(max-mass)` returns the lowest risk in
`[Low, Medium, High]` whose tail is at most `max-mass`.

Consequences:

- `UpperTail(0.0)` is equivalent to `WorstCase`.
- Equality is accepted. A tail exactly equal to `max-mass` remains below the
  higher class.
- The adjacent representable `max-mass` below that boundary raises the
  selected risk.
- A model that intends a severe but tolerance-discardable outcome must call it
  `High`; `Forbidden` means non-discardable.

Only one rule is accepted. Missing, duplicate, combined, or unknown rules fail
closed rather than receiving an order-dependent interpretation.

## Conservative join with v0

Posterior projection requires an independently computed, already validated v0
baseline assessment. Let its risk and confidence be `(r0, c0)`.

```text
effective-risk       = max(r0, posterior-risk)
effective-confidence = c0
```

The projection does not infer, raise, lower, or reinterpret confidence. The
effective assessment is an ordinary `GovernanceAssessmentV0` whose evidence
contains the versioned posterior record. The existing v0 policy and gate
consume it.

For one unchanged policy:

```text
baseline-verdict = live-v0(policy, r0,             c0)
final-verdict    = live-v0(policy, effective-risk, c0)
```

Using the security order `Allow < Ask < Block`, the final verdict is never
below the baseline verdict. This follows from:

1. `effective-risk >= r0`;
2. confidence is unchanged; and
3. the released v0 policy is monotone in risk.

This is a join, not a replacement judgment. A posterior that selects a lower
risk cannot lower the deterministic baseline.

Invalid or unsupported posterior processing produces no effective assessment,
gate invocation, approval request, or action. Once v1 processing is selected,
there is no fallback to the unmodified baseline after a v1 failure.

Dry behavior remains the released behavior: a non-`Forbidden` effective risk
may be simulated, `Forbidden` blocks, and no path falls back to live
execution.

## Why `AlwaysAskBelow` is rejected

The earlier sketch included:

```text
AlwaysAskBelow(confidence)
```

That spelling promises behavior the unchanged v0 gate cannot enforce. The gate
compares assessment confidence only with `LivePolicyV0.min-confidence`. An
independent threshold cannot force `Ask`; in particular, a policy whose
minimum confidence is `0.0` accepts every valid confidence, including `0.0`.

Putting a second threshold only in evidence would not make the gate enforce
it. Raising the reported risk merely to manufacture `Ask` would make an
assessment's risk depend on policy routing rather than judgment and could
change one assessment across policies.

Callers wanting the released confidence behavior must configure the existing
`min-confidence`. A future always-review rule requires an additive, versioned
policy, gate, proposal, and Audit contract. Until that exists,
`AlwaysAskBelow` is an unsupported rule and fails before the gate.

## Approximate inference

Only deterministic finite exhaustive enumeration may produce a
decision-bearing `RiskBeliefV1`.

Likelihood weighting, MCMC, externally sampled results, and every other
approximate posterior may be recorded and displayed, but must be labeled:

```text
non-authorizing-approximate-evidence-v1
```

Approximate evidence:

- cannot produce an effective assessment or verdict;
- cannot reach `gate-live`;
- cannot authorize an action or strengthen existing consent; and
- cannot be passed where exact posterior evidence is required.

A seed, sample count, effective sample size, or byte-identical replay proves
reproducibility, not calibration or a statistical bound. The non-authorizing
rule also prevents seed-shopping from turning a sampled result into
auto-authorization.

## Identity binding

A decision-bearing posterior ID binds:

```text
HASH_V0(
  posterior-risk-result-v1,
  call-id,
  model-id,
  exact-inference-handler-semantics-id,
  handler-config-hash,
  evidence-hash,
  raw-belief,
  normalized-belief)
```

`model-id` selects the resolved model and its content-addressed dependencies.
The handler semantics ID selects the exact finite enumeration implementation,
not a display name such as `"enumerate"`. Configuration and evidence are
canonical Code values selected by their hashes.

The projection ID additionally binds:

```text
HASH_V0(
  posterior-risk-projection-v1,
  baseline-assessment-id,
  posterior-id,
  projection-rule,
  effective-risk)
```

The effective `GovernanceAssessmentV0.evidence` contains canonical
`posterior-risk-evidence-v1` carrying those IDs and their exact values. Its
existing assessment ID therefore binds the baseline, model, handler, evidence,
raw and normalized posterior, rule, and result. The existing Proposal ID and
Audit v2 `Evaluated` entry transitively bind that assessment without changing
their schemas or `HASH_V0`.

Hashes establish identity and linkage. They do not establish that a model,
handler, evidence source, or assessment is correct.

## Replay

A v1-aware replay checker must:

1. validate every versioned carrier and recompute every carried hash;
2. resolve the exact Call, baseline assessment, model and dependencies,
   inference-handler semantics, configuration, and evidence;
3. rerun exhaustive inference;
4. reproduce raw weights and normalized probabilities bit for bit;
5. recompute the posterior ID, rule result, conservative join, projection ID,
   and effective assessment ID;
6. recompute the unchanged v0 verdict; and
7. require exact equality with the committed assessment and Audit evidence.

Missing artifacts, wrong versions, model or handler substitution, changed
configuration, evidence drift, numerical drift, impossible observations, or
any ID/result mismatch fails verification. A mismatch found before action
prevents action. A mismatch discovered after an external action is a
reconciliation failure; it does not imply rollback.

The existing v0 verifier may continue to establish v0 linkage for an effective
assessment. It must not claim posterior replay unless the seven v1 checks
above completed.

## Exact examples

Unless a row says otherwise:

```text
policy   = LivePolicyV0(
  auto-up-to=Low,
  ask-up-to=High,
  min-confidence=0.80)

baseline = GovernanceAssessmentV0(
  risk=Low,
  confidence=0.90,
  ...)
```

| Exact raw weights `(Low, Medium, High, Forbidden)` | Rule | Effective risk | Existing v0 verdict |
| --- | --- | --- | --- |
| `(1, 0, 0, 0)` | `WorstCase` | `Low` | `Allow` |
| `(0.875, 0.125, 0, 0)` | `WorstCase` | `Medium` | `Ask` |
| `(0.875, 0.125, 0, 0)` | `UpperTail(0.125)` | `Low` | `Allow` |
| `(0.875, 0.125, 0, 0)` | `UpperTail(nextDown(0.125))` | `Medium` | `Ask` |
| `(0.875, 0, 0, 0.125)` | `UpperTail(0.125)` | `Forbidden` | `Block` |
| `(1, 0, 0, 0)`, baseline `Medium` | `WorstCase` | `Medium` | `Ask` |

The following inputs produce no effective assessment, verdict, approval
request, or action:

| Input | Result |
| --- | --- |
| `(0, 0, 0, 0)` | impossible posterior |
| any negative, NaN, infinite, or support-losing weight | invalid posterior |
| `UpperTail(-0.01)` or `UpperTail(1.0)` | invalid rule |
| `AlwaysAskBelow(0.95)` | unsupported rule |
| approximate posterior, including an all-`Low` sample | evidence only |

## Security review

The approved boundary fails closed on the principal semantic hazards:

- a tiny positive `Forbidden` mass cannot be rounded or tolerated away;
- normalization cannot silently erase positive support;
- a posterior cannot lower the independently computed baseline risk;
- approximate or seed-selected evidence cannot auto-authorize;
- a handler, model, evidence, configuration, rule, or replay substitution
  changes a bound identity; and
- an unsupported review promise cannot hide inside unexamined evidence.

The trusted model, evidence source, exact inference handler, projection
implementation, checker, canonical serializer, verifier, and host remain in
the trusted computing base. Enumeration can consume unbounded time or memory
without separate budgets. Evidence may be malicious, poisoned, stale, or
sensitive. This decision adds no calibration theorem, model-truth guarantee,
authenticated evidence source, external-state freshness, simulator-fidelity
claim, sandbox, production security claim, or new consent authority.

## Compatibility and implementation boundary

GM.20 freezes a docs-and-fixtures contract only. It does not:

- add or change any of the 27 kernel forms;
- change surface syntax or bootstrap `.jqd`;
- change canonical serialization or reinterpret `HASH_V0`;
- change `GovernanceAssessmentV0`, `LivePolicyV0`, `gate-live`, Proposal,
  Audit v2, or any released effect identity;
- make posterior judgment part of the deterministic GM.22 release claim; or
- authorize implementation of an always-review gate.

A future implementation must be additive, versioned, and preserve the exact
failure and non-authorizing boundaries above.
