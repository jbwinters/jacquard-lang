# DES.2 Understandable Uncertainty APIs

- Status: design proposal with a follow-up backlog. Nothing here is implemented
  or approved as a language or library contract by this document.
- Date: 2026-09-24
- Base: `main`. Typed inference outcomes (INF.1, jacquard-lang:223,
  PR #134) are a pending planning input that this design builds on. It was not
  yet merged when this was written.
- Owner decisions required before dependent implementation are listed in §10.

## 1. Question

Jacquard's discrete inference is exact and small, and it already answers real
decision questions. `demos/inference/clarifying-question.jac` computes whether
asking the user a question is worth an interruption, and
`demos/inference/ambiguity-pipeline.jac` keeps alternative readings of an
extracted date alive until a click resolves them. Both work. Both are also hard
to read and easy to get subtly wrong.

The clarification demo is 89 lines. It writes `expectation` by hand, and
repeats the model body five times (`eu-fast-answer`, `eu-audit-first`,
`informed-utility`, and two distributions). Every one of them re-samples
`intent-dist()` independently. That is correct only because each repetition is
a separate expectation. A model that sampled the same quantity twice *inside
one expectation* would silently get two independent draws, and nothing in the
code or the output would say so.

This design proposes a small library for everyday decisions under uncertainty:

- named uncertain quantities sampled once and shared
- assumptions kept apart from observations
- alternative actions with expected utility and downside summaries
- sensitivity across explicit assumption sets
- the value of obtaining information

It also proposes a readable report, and uses INF.1's outcomes and metadata for
every failure and every exact-versus-sampled distinction. It proposes no
kernel change (§4.8).

## 2. Inventory Of Shipped Behaviour

| capability | where | status |
|---|---|---|
| discrete distributions `Bernoulli`, `Categorical`, `UniformInt`; multi-shot `Dist` with `sample`/`observe` | `prelude/06-dist.jqd`, `docs/stdlib.md` §Dist | shipped |
| exact enumeration `dist.enumerate`, tally with explicit `Eq`, dictionary-honest `dist.pmf` | `prelude/13-dist-lib.jqd` | shipped; `dist.enumerate` yields NaN weights on impossible evidence (stdlib §12 errata) |
| seeded likelihood weighting `dist.sample-lw`; `jacquard infer enumerate/lw` | prelude builtin, `src/infer_dist.ml` | shipped |
| typed outcomes: posterior, impossible, exhausted, numerical failure, with method, completeness, seed, bound and explored-count metadata; `dist.enumerate-v1(model, budget)`, `dist.sample-lw-v1` | INF.1, PR #134 | pending, not yet on `main` |
| value of information | `demos/inference/clarifying-question.jac`: hand-written `expectation`, act-now versus informed utility, `question-value = informed - act-now` | demo code, not library |
| alternative interpretations kept until evidence | `demos/inference/ambiguity-pipeline.jac`: `observe` on a click conditions the extracted date | demo code |
| world record sampled once; expected score and downside per alternative; forecast value; sensitivity reruns | `demos/applications/picnic-planner/` (`PicnicWorld(weather, attendance)`; `EXAMPLE.txt` "Attendance depends on the same weather used to score every venue"; reruns at rain 5 %, 30 %, 90 %) | application code |
| expected value and bust risk per policy | `demos/applications/dice-coach/model.jac` | application code |
| exact bounded risk posterior with positive-support and underflow accounting | `prelude/29-posterior-risk.jqd` (GM.21) | shipped, governance-specific |

Current clarification output, which the rewrite must reproduce exactly:

```text
(3.1000000000000005, 6.1, 6.1)          -- EU fast-answer, EU audit-first, act now
(8.7, 2.5999999999999996)               -- informed utility, question value
("ask-user", "audit-first", 7.699999999999999, 5.699999999999999)
```

The ambiguity demo prints `schedule-followup` at `0.9999999999999999`, with
the impossible routes listed at `0.0`. The information is correct but hard to
read, and a reader cannot tell a rounding artifact from a real residual.

## 3. User Scenarios

1. **Should I ask?** An assistant must decide whether to interrupt the user
   with a clarifying question, given the probability that the request needs an
   audit and the cost of an interruption (the clarification demo).
2. **Which venue, and is the forecast worth buying?** Weather drives both
   attendance and enjoyment, and every venue must be scored against the *same*
   weather (the picnic planner).
3. **How robust is the recommendation?** When the rain chance is 5 %, 30 %
   or 90 %, does the recommendation change, and where?
4. **What does this evidence change?** A user clicks "Apr 3". The routing
   posterior should update, and an observation that contradicts every
   possibility should be reported as impossible evidence, not as NaN.

## 4. Proposal

All proposals are prelude library code in ring 2 under a new `decision.`
prefix, versioned `-v1`, over `dist.enumerate-v1` (INF.1).

### 4.1 Named uncertain quantities and shared worlds

The world is sampled once per execution path, and every question is asked of
that one sample. The unit of modelling is a **world**: a value, usually a
constructor with labeled fields, drawn by one thunk.

```jacquard
type Weather = | Dry | Wet
type World = | World(weather: Weather, audit: Bool)

world(rain) = {
  let weather = dist.named("weather", dist.bernoulli-of(rain, Wet, Dry))
  let audit = dist.named("audit", Bernoulli(0.35))
  World(weather, audit)
}
```

- A field is a **named uncertain quantity**. Its name, via `dist.named`, is
  DES.0's addressable choice (jacquard-lang:254). The name labels reports and
  makes exploration forks possible. The field label gives typed access
  (generated accessors, SX.27).
- **Correlation is structural.** Anything that depends on `weather` reads the
  field, so attendance and enjoyment see the same weather. Two draws of the
  same quantity require two fields with two names. Nothing re-samples
  implicitly.
- **Independence is explicit.** `independent` quantities are simply separate
  fields drawn by separate `dist.named` calls.
- `dist.bernoulli-of(p, yes, no)` is a proposed convenience, a `Categorical`
  over two named outcomes.

Every analysis function takes the world thunk, enumerates it exactly **once**,
and evaluates each action's utility on each world in the support. Every action
is therefore compared on identical worlds, the exact analogue of common random
numbers.

### 4.2 Assumptions versus observations

- An **assumption** is an explicit, named argument of the world thunk (`rain`
  above), or a record of them (`Assumptions(rain: 0.3, accuracy: 0.8)`).
  Changing an assumption changes the model. Assumptions appear in the report
  header and drive sensitivity (§4.5).
- An **observation** is evidence about this situation, applied as `observe`
  inside a conditioning function:
  - `decision.given(world, fn (w) -> observe(...))` returns a conditioned world
    thunk.
  - Observations appear in the report as "given" lines.
  - Contradictory evidence yields `InferenceImpossibleV1`, never a NaN
    posterior.

Assumptions are never written as observations, and observations never as
assumption edits. The report keeps them in separate sections, so a reader can
see what was believed and what was seen.

### 4.3 Actions, expected utility and downside

```text
decision.analyze-v1 :
  (() ->{Dist} w, List a, (a, w) ->{} Real, Int) ->{}
    Result InferenceFailureV1 (DecisionReportV1 a)

DecisionReportV1 a = DecisionReportV1(
  actions: List (ActionSummaryV1 a),   -- in the order given
  best: a,                             -- highest expected utility; ties -> first listed
  metadata: InferenceMetadataV1)

ActionSummaryV1 a = ActionSummaryV1(
  action: a,
  expected: Real,
  worst: Real,                         -- minimum utility over positive-probability worlds
  below-zero: Real)                    -- P(utility < 0.0)
```

The downside summaries are deliberately two simple numbers: the worst case over
worlds with positive probability, and the probability of a loss. The probability of a loss matches what the picnic and dice applications compute
by hand ("chance of negative enjoyment", "bust probability"). The worst case is
new, and is the cheapest summary that names the bad outcome itself. A caller that needs another threshold uses
`decision.probability-v1(world, fn (w) -> pred)` (§4.6).

### 4.4 Value of information

```text
decision.value-of-information-v1 :
  (() ->{Dist} w, (w) ->{Dist} s, List a, (a, w) ->{} Real, Eq s, Int) ->{}
    Result InferenceFailureV1 (InformationReportV1 a s)

InformationReportV1 a s = InformationReportV1(
  act-now: DecisionReportV1 a,
  signals: List (SignalSummaryV1 a s),  -- per signal value: probability, best action, EU
  informed-expected: Real,
  value: Real,                          -- informed-expected - act-now best expected
  metadata: InferenceMetadataV1)
```

- The signal is a possibly noisy function of the world. A perfect question is
  `fn (w) -> world.audit(w)`. A forecast with accuracy 0.8 samples a
  `Categorical` conditioned on the world's weather.
- The informed branch conditions on each signal value by enumerating
  `(world, signal)` pairs once. It never re-samples the world separately per
  branch.
- `value` is the expected gain before the cost of obtaining the information.
  The recommendation "ask" versus "act now" compares `value` with a caller's
  cost. The library reports the number and the crossing point; it does not
  hard-code a cost.

### 4.5 Sensitivity across explicit assumptions

```text
decision.sensitivity-v1 :
  (List (Text, p), (p) -> () ->{Dist} w, List a, (a, w) ->{} Real, Int) ->{}
    List (Text, Result InferenceFailureV1 (DecisionReportV1 a))
```

Each named assumption set is analysed as its own model. The result lists, per
set, the recommendation and expected utilities. `decision.render-v1` marks
every point where the best action differs from the previous set. The picnic
planner's rain 5 %, 30 % and 90 % reruns become one call. Continuous sweeps,
root finding for crossover points, and caching across assumption edits are not
part of v1; MODEL.1 (jacquard-lang:230) owns the dependency tracking that makes
reevaluation incremental.

### 4.6 Supporting functions

- `decision.expect-v1(world, f, budget)`: the expectation of a real function
  of the world, with the typed outcome. It replaces the hand-written
  `expectation`.
- `decision.probability-v1(world, pred, budget)`: the probability of a
  predicate.
- `decision.posterior-v1(world, f, eq, budget)`: the merged posterior of a
  projection, with rows of exactly zero probability dropped and a stated
  normalization check (§4.7).

### 4.7 Readable presentation

`decision.render-v1 : DecisionReportV1 a -> (a -> Text) -> Text` and its
information and sensitivity counterparts produce a fixed layout:

```text
Decision under: rain 30% (assumption)
Given: none
Exact enumeration, complete, 4 worlds.
  audit-first   expected  6.100   worst  4.000   P(loss)  0.0%
  fast-answer   expected  3.100   worst -6.000   P(loss) 35.0%
Best now: audit-first.
Asking first: expected 8.700 (+2.600 before its cost).
  answer needs-audit  (35.0%): audit-first
  answer quick-answer (65.0%): fast-answer
Ask when the interruption costs less than 2.600.
```

Presentation rules:

- Probabilities print to one decimal place as percentages. The normalization is
  checked, not rounded away: `|sum - 1| ≤ 1e-12` or the report fails with a
  numerical-failure outcome.
- Rows of exactly zero probability are omitted and counted ("2 impossible
  routes omitted").
- Utilities print to three decimals.
- The header always states exact or sampled, complete or not, and the bound.
- A sampled report additionally prints its seed and sample count, and labels
  every recommendation "estimated".
- The same report would be available as a `Code` value for machine-readable output
  (the Host APP.3 consumer, §11).

### 4.8 Failure and metadata

Every `decision.*` function returns INF.1's `result InferenceFailureV1 …`:

- **Impossible evidence.** `InferenceImpossibleV1`: no world survives the
  observations. The report says which observation set was given.
- **Numerical failure.** Underflow, non-finite or negative mass,
  `InferenceNumericFailureV1`. In addition, a utility that evaluates to NaN or
  infinity is reported as non-finite, not averaged.
- **Incomplete exploration.** `InferenceExhaustedV1` when the world has more
  terminal paths than the budget. No partial expected utilities are returned.
- **Exact versus sampled.** Each function has a `…-sampled-v1` twin over
  `dist.sample-lw-v1(samples, seed)`. Its metadata is never complete, and its
  report labels recommendations as estimates.

**No kernel addition** is proposed. Everything above is prelude code over
`sample`, `observe`, `dist.enumerate-v1`, labeled constructors, and explicit
`Eq` dictionaries. The one thing a kernel or checker feature could add is
*enforcing* single sampling of a named quantity, for example by making
`dist.named` affine per name. The world-record idiom gets the same guarantee by
construction, so that is deferred (§10 item 1).

## 5. Worked Examples: Correlated And Independent

### 5.1 The silent re-sampling bug

Take an umbrella decision with rain `Bernoulli(0.3)` and a perfect forecast.
The policy is "carry if the forecast says rain". Utility is 5 for carrying in
rain, −1 for carrying in dry weather, and 0 otherwise.

**Wrong** (two independent draws of one quantity):

```jacquard
expected(fn () -> {
  let forecast-rain = sample(Bernoulli(0.3))   -- "the forecast"
  let rain = sample(Bernoulli(0.3))            -- "the weather": a second, independent draw
  utility(forecast-rain, rain)
})
-- 0.3*0.3*5 + 0.3*0.7*(-1) = 0.45 - 0.21 = 0.24
```

**Right** (one named quantity; the forecast reads it):

```jacquard
world() = World(rain: dist.named("rain", Bernoulli(0.3)))
decision.expect-v1(world, fn (w) -> utility(world.rain(w), world.rain(w)), 16)
-- 0.3*5 + 0.7*0 = 1.5
```

The wrong version makes a perfect forecast look almost worthless: 0.24 instead
of 1.5. The world record makes the second draw impossible to write by
accident, because the forecast is a function of `w`.

### 5.2 Intentionally independent quantities

Two customers each need an audit with probability 0.35, independently:

```jacquard
world() = MkPair(
  dist.named("audit-a", Bernoulli(0.35)),
  dist.named("audit-b", Bernoulli(0.35)))
-- P(both) = 0.1225, P(neither) = 0.4225, P(exactly one) = 0.455
```

Independence is visible as two names. A single customer asked about twice is
one name, read twice, with P(both) = 0.35.

These examples are §12 checks: exact, and pinned to the numbers above.

## 6. End-To-End Example: The Clarifying Question, Before And After

**Before** (89 lines; excerpt): see §2 and
`demos/inference/clarifying-question.jac`. It has a hand-written `expectation`,
the model body repeated in five places, and hand-written `max`/argmax twice.

**After** (proposed):

```jacquard
type Action = | FastAnswer | AuditFirst
type World = | World(audit: Bool)

world() = World(dist.named("audit", Bernoulli(0.35)))

utility(action, w) = match action {
  | FastAnswer -> if world.audit(w) then -6.0 else 8.0
  | AuditFirst -> if world.audit(w) then 10.0 else 4.0
}

actions() = [FastAnswer, AuditFirst]

clarify() =
  decision.value-of-information-v1(
    world, fn (w) -> world.audit(w), actions(), utility, bool.eq, 16)

decision.render-information-v1(clarify(), action.show)
```

The rendered report is the §4.7 example. The check values, pinned by tests
(§12), are:

- act-now expected utilities: fast-answer 3.1 and audit-first 6.1 (the demo's
  `3.1000000000000005` is its own summation order; the library must equal 3.1
  within 1e-12, with the tolerance stated in the test)
- best now: `AuditFirst`
- informed expected 8.7, value 2.6
- per-signal recommendations: audit → `AuditFirst`, no audit → `FastAnswer`
- recommendation change: ask when the cost is below 2.6. So `policy(1.0)` asks
  and `policy(3.0)` acts now with `AuditFirst`, as the demo prints.
- normalization: the signal probabilities 0.35 and 0.65 sum to 1 within 1e-12

## 7. Alternatives Considered

| alternative | why not |
|---|---|
| A memoizing `Uncertain` effect whose handler caches each named quantity per path | It needs a heterogeneous map from names to differently typed values, so either an unsafe cast or `Code` round-trips. The world record gives the same sharing with ordinary types |
| Sampling-based analysis by default | It hides incompleteness and makes small questions nondeterministic. Exact is the default, and sampling is an explicit twin with visible metadata |
| A continuous distribution library first | The applications and demos are all finite and discrete. Continuous support needs new numeric contracts and is out of scope |
| Rich risk measures (CVaR, quantiles) in v1 | Two numbers, worst case and probability of loss, cover every shipped use. Others are follow-ups when a user needs them |
| Automatic crossover search in sensitivity | It requires root finding over real parameters. v1 lists explicit sets and marks changes |

## 8. Bounded First Release, Non-Goals, Compatibility

**First release:** UNC.1 to UNC.4 in §11, which are world thunks,
`analyze`, `value-of-information`, `sensitivity`, the supporting functions,
exact and sampled twins, and rendering. The clarification and picnic demos are
rewritten onto them.

**Non-goals.** v1 does not include:

- continuous distributions, general Bayesian networks or causal graphs
- automatic elicitation of utilities
- optimization over action spaces larger than an explicit list
- incremental reevaluation, which belongs to MODEL.1
- a Host user interface, which is Host APP.3's job
- any kernel change

**Compatibility and identity:**

- The released `dist.*` identities are unchanged.
- The `decision.*-v1` names are new ring-2 prelude identities and will appear
  in the prelude hash golden as additions.
- The demos keep their files, and a rewrite changes their hashes intentionally,
  the same as any edit.
- The report types are versioned, so a new summary field is a `-v2`.

## 9. Failure Behaviour

| situation | result |
|---|---|
| observations contradict every world | `err(InferenceImpossibleV1 …)`; `render` prints "no world is consistent with: …" |
| world exceeds the budget | `err(InferenceExhaustedV1 …)`, with the bound named; nothing partial |
| a utility is NaN or infinite | `err(InferenceNumericFailureV1(InferenceNonFiniteV1, …))` |
| probabilities fail the 1e-12 normalization check | numerical failure, never rounded silently |
| empty action list | the analysis fails with a documented error value, not an arbitrary "best" |
| tie in expected utility | first listed action wins, and the report prints "tie" |

## 10. Decisions Requiring Owner Direction

1. **The world-record idiom** (§4.1) rather than a memoizing effect, or an
   affine `dist.named` checked per name. The recommendation is the world
   record, with enforcement deferred.
2. **Downside summaries fixed to worst case and probability of loss** (§4.3).
3. **The `decision.` prefix** and `-v1` report types, placed in ring 2.
4. **Reliance on INF.1's result types** (§4.8). This gates UNC.1 on INF.1
   merging.
5. **Whether sampled recommendations may be rendered as recommendations at
   all**, or only as estimates. Recommended: the latter, labeled.

## 11. Follow-Up Backlog And Reconciliation

### Existing tasks reused

| task | relationship |
|---|---|
| jacquard-lang:223 INF.1 typed inference outcomes | **Reused.** Every `decision.*` result is an INF.1 outcome with its metadata. All UNC tasks depend on it |
| jacquard-lang:230 MODEL.1 model dependencies and cache reevaluation | **Reused.** Assumption edits, freshness and caching belong to MODEL.1. UNC.3 lists assumption sets, and MODEL.1 makes their reevaluation incremental. No UNC task duplicates it |
| jacquard-lang:254 EXP.2 `dist.named` (from DES.0) | **Reused** for named quantities. UNC.1 depends on it |
| jacquard-host:13 APP.3 decision documents | **Reused as the Host presentation.** It consumes the report `Code` form. Its cross-repository gate should add jacquard-lang:260 when next unblocked (§10). This design does not edit the Host plan |

### New tasks (jacquard-lang master tag)

| id | title | depends on | priority |
|---|---|---|---|
| jacquard-lang:260 UNC.1 | World thunks, `decision.analyze-v1`, `expect/probability/posterior-v1`, report types and rendering | 223, 254 | medium |
| jacquard-lang:261 UNC.2 | `decision.value-of-information-v1` with perfect and noisy signals | 260 | medium |
| jacquard-lang:262 UNC.3 | `decision.sensitivity-v1` over named assumption sets with recommendation-change marking | 260 | medium |
| jacquard-lang:263 UNC.4 | Sampled twins over `dist.sample-lw-v1` with estimate labeling | 260 | low |
| jacquard-lang:264 UNC.5 | Rewrite the clarification and picnic demos onto the library, with before/after crams and the §12 checks | 261, 262 | medium |

Each task's details carry its acceptance criteria and test strategy (§12).

## 12. Validation And Measurable Acceptance

- **Clarification numbers.** The rewritten clarification demo reproduces
  every number in §6 within 1e-12:
  - expected utilities 3.1 and 6.1, informed 8.7, value 2.6
  - `policy(1.0)` = ask and `policy(3.0)` = `AuditFirst`
  - The line count drops from 89 to at most 30, excluding comments.
- **Worked examples.** §5.1 evaluates to 0.24 for the wrong model and 1.5 for
  the world-record model. §5.2 gives 0.1225, 0.4225 and 0.455. All are pinned.
- **Normalization.** Every rendered distribution sums to 1 within 1e-12. A
  forced violation, from a crafted non-normalized categorical, fails as a
  numerical failure.
- **Recommendation changes.** The picnic sensitivity at rain 5 %, 30 % and
  90 % reproduces `EXAMPLE.txt`'s recommendations (park, covered pavilion,
  indoors) and marks the two changes.
- **Failure cases.** Impossible evidence, an exhausted budget and a
  non-finite utility each produce their typed outcome, with an exact rendered
  message.
- **Sampled twins.** A sampled twin with a fixed seed is reproducible, never
  complete, and labeled "estimated".
- **Unchanged identities.** The prelude hash golden gains lines only.
