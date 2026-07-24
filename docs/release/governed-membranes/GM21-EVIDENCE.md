# Governed Membranes GM.21 posterior-aware Judge evidence

Status: release-hardening G5 implementation overlay on exact integrated base
`d3eaa9b92659fb595def64025a2434d6898e5274`.

## Scope

GM.21 implements the separately versioned posterior-risk contract approved in
GM.20. It adds:

- a hash-resolved exact model boundary with the closed signature
  `(GovernanceCall) ->{Dist} Risk`;
- bounded exhaustive enumeration that preserves finite support order, raw
  weights, theoretically positive support, and terminal-branch accounting;
- validated exact `RiskBeliefV1` normalization and the approved `WorstCase` and
  `UpperTail(max-mass)` projections;
- `judge.posterior-exact-v1`, which obtains an independent baseline from the
  next outer Judge and can only raise its risk;
- identity-bound exact evidence and replay;
- seeded, byte-reproducible likelihood-weighting evidence with a distinct
  non-authorizing type; and
- stable E0910--E0916 and E1543--E1549 failure families.

It changes no kernel form, public syntax, canonical serialization, `HASH_V0`,
Governance v0 carrier, policy, gate, Proposal, Approval, Audit v2, raw driver,
or action path.

## Decision-bearing boundary

There is one decision-bearing handler:

```text
judge.posterior-exact-v1 :
  (() ->{Judge, Throw | e} a,
   PosteriorRiskModelRefV1,
   PosteriorExactConfigV1,
   Code,
   PosteriorRuleV1)
  ->{Judge, Throw | e} a
```

On `Judge.assess(call)`, the handler:

1. forwards the same Call to the next outer Judge for an independently
   validated v0 baseline;
2. resolves the model by exact stored term hash and requires exactly one closed
   `Dist` effect;
3. explores finite `sample` supports depth first in their stored order and
   applies `observe` mass without collapsing duplicate support entries;
   observation equality is identity-aware and structural for transparent
   primitive, tuple, and constructor data, while closures and other opaque or
   executable values fail closed;
4. refuses the next terminal path once the positive configured branch budget
   is exhausted and returns no partial result;
5. normalizes in the GM.20 binary64 operation order while refusing impossible,
   non-finite, or support-losing posteriors;
6. applies exactly one approved projection rule and joins the result upward
   with the baseline risk while preserving baseline confidence and reasons; and
7. resumes the intercepted continuation once with the ordinary effective
   `GovernanceAssessmentV0`.

Any model-resolution, type, evaluation, arithmetic, normalization, carrier,
identity, or projection failure throws before the continuation resumes. That
failed attempt produces no effective assessment, gate invocation, approval,
Audit entry, or action and does not fall back to the unmodified baseline.

## Identity and replay

Every exact result carries the Call, model, exact-handler semantics,
configuration, source evidence, raw weights, normalized belief, positive
support, branch accounting, and their approved identities. The posterior ID
binds the GM.20 subject:

```text
HASH_V0(
  posterior-risk-result-v1,
  call-id,
  model-id,
  exact-handler-semantics-id,
  handler-config-hash,
  source-evidence-hash,
  raw-weights,
  normalized-belief)
```

The projection ID additionally binds the independent baseline assessment ID,
posterior ID, exact rule, and effective risk. The effective assessment evidence
embeds the complete baseline assessment, exact result, and projection, so the
unchanged assessment, Proposal, and Audit identities bind them transitively.

`posterior.replay-exact-v1` reruns model resolution, exact inference,
normalization, conservative projection, and assessment construction, then
requires the expected assessment identity. Existing v0 run-bundle verification
is unchanged and does not claim posterior replay on its own.

`Posterior_risk_verify.verify_form` is the additive posterior-aware offline
verifier. It first runs the unchanged v0 verifier, then:

1. reruns exact inference from typed model, configuration, evidence, Call,
   baseline, and rule artifacts;
2. requires exactly one `Evaluated` Audit entry for the replayed Call;
3. requires byte-exact equality between the replayed effective assessment and
   the committed assessment;
4. resolves exactly one bound live policy; and
5. recomputes the unchanged Governance v0 live-policy verdict.

Missing or ambiguous linkage and unsupported dry policies fail closed with
E1548. Replay, assessment, or verdict drift fails closed with E1549. Dry policy
verification is intentionally unsupported because the v0 run bundle does not
bind the simulator-availability input needed to reproduce its verdict.

The exact-result constructor is removed from public name resolution after
prelude loading. Trusted runtime code retains its internal identity. This keeps
the projector input unforgeable from ordinary checked Jacquard while the
projector still defensively validates every carried field and hash.

## Approximate evidence boundary

`posterior.sample-evidence-v1` uses the existing splitmix64 likelihood-weighting
engine and binds the model, approximate-handler descriptor, positive sample
count, seed, Call, source evidence, and empirical belief. The result type is
`NonAuthorizingApproximateRiskEvidenceV1`.

That type is not accepted by the exact projector and has no Judge handler,
assessment constructor, gate, Approval, or action route. Identical seed and
sample count establish byte reproducibility only; they do not establish
calibration, confidence, a statistical bound, or authorization. This split
prevents an all-Low sampled run or seed selection from becoming a decision.

## Executable evidence

The compiled posterior-risk suite covers:

- a hand-derived Low/High posterior and the existing `check.posterior` law;
- equivalent duplicate-support models under `check.same-dist`;
- exact equality and adjacent-lower behavior at an `UpperTail` boundary;
- non-discardable tiny positive `Forbidden` mass;
- conservative baseline joining with byte-preserved confidence and reasons;
- the exhaustive 4-by-4 baseline/posterior Risk lattice, including the
  unchanged live-policy verdict for every effective risk;
- outward Judge forwarding;
- branch-budget failure before continuation-owned state can run;
- wrong model signatures and malformed exact inference states;
- exact input determinism and source-evidence identity sensitivity;
- exact versus approximate handler-semantics identity separation;
- seeded approximate byte reproducibility and static refusal at the exact
  projector type boundary;
- language/runtime descriptor equality;
- successful replay and expected-assessment substitution refusal;
- posterior-aware bundle verification after the unchanged v0 verifier,
  including assessment, verdict, source-evidence, and configuration drift;
- ambiguous `Evaluated` linkage and unsupported dry-policy refusal;
- unchanged gate and Audit linkage; and
- public exact-constructor opacity.

The exact inference suite separately covers duplicate leaves and observations,
an adversarial pair of distinct closures with the same diagnostic rendering,
budget equality and exhaustion, negative/NaN/infinite support weights, forged
Risk identity, unexpected effects, runtime failure, and binary64 underflow that
must remain visible as theoretically positive support.

## Honest limits

GM.21 is a research-grade evidence adapter, not a production-security theorem.
The model, evidence source, exact enumerator, normalizer, projector, evaluator,
canonical serializer, and replay implementation are trusted. Hashes establish
identity and linkage, not model truth. Models and evidence can be malicious,
poisoned, stale, miscalibrated, or sensitive.

The posterior-aware verifier accepts caller-supplied typed replay artifacts; it
does not discover or authenticate the model, source evidence, baseline, or
projection rule. Exact identity comparison exposes substitutions relative to a
committed assessment, but cannot establish that the originally selected model
or evidence was appropriate. Only live-policy verdicts are reproducible from
the current bundle schema.

The explicit budget bounds completed terminal branches. It does not bound time
inside one branch, recursion, memory, support construction, or host resource
use. Exact finite enumeration is not suitable for every model. Approximate
evidence does not become authorizing when exact inference is impractical.
GM.21 adds no sandbox, authenticated evidence source, freshness guarantee,
simulator-fidelity claim, rollback, covert-channel protection, or new consent
authority.

## Reproduction

```sh
eval "$(opam env)"
mkdir -p "$PWD/.scratch/tmp"
export TMPDIR="$PWD/.scratch/tmp"

opam exec -- dune build --root "$PWD" @all
opam exec -- dune runtest --root "$PWD" --force
opam exec -- dune build --root "$PWD" @fmt
opam exec -- dune build --root "$PWD" @doc
scripts/release/check-gm21-manifest.sh
```
