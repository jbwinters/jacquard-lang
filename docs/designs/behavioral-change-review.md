# DES.1 Behavioral Change Review

- Status: this is a design proposal with a follow-up backlog. It implements
  nothing and approves nothing as a language, runtime, or report contract.
- Date: 2026-09-24
- Base: `main`.
- Pending planning inputs, not yet on `main` when this was written:
  - API.1 `interface-v1` (jacquard-lang:216, PR #130)
  - INF.1 typed inference outcomes (jacquard-lang:223, PR #134)
- The owner decisions required before dependent implementation are listed in
  §10.

## 1. Question

A reviewer is handed a change to a decision rule. It might be an eligibility
check, a routing rule, or a scheduling policy. Structural review already works:
`jacquard diff` says which subtrees changed, and renames and reformatting are
not changes. What the reviewer cannot yet get is *behavioral* review:

- On which declared inputs and worlds do the two versions decide differently?
- Which external operations would the new version perform that the old did not?
- If the worlds carry probabilities, how likely is a changed decision?
- What is one small, replayable case that shows the difference?
- What, exactly, was checked? What was not checked?

This design specifies how two compatible checked versions are run over
declared inputs and worlds, how the results are compared, and how the answer is
presented. The engine is RW.8 (jacquard-lang:228), which is planned but not yet
built. This design fixes the reviewer-facing contract on top of it. It never
claims that two programs are behaviorally equivalent outside the declared
support.

## 2. Inventory Of Shipped Behaviour

| mechanism | where | what it gives | gap for review |
|---|---|---|---|
| semantic diff | `jacquard diff` (`bin/main.ml`) | structural change between two files or stores: renames are renames, reformatting is nothing, and edits localize to the smallest changed subtrees | structure, not behavior |
| posterior divergence | `jacquard dist-diff` (TL.1) | per-outcome probability deltas between two model versions, support gained/lost, sweeps, enumeration cached by content hash | only for models whose *result* is a distribution; no decision/effect comparison |
| relational lanes | `jacquard relate --vary schedule/secret/grant`, `docs/relational-warp.md` | one program under a controlled variation; `run-transcript-v1` equality; first-divergence rendering | one program, not two versions |
| relational Warp cases | `docs/warp-testing.md` §5: `SameUnder(label, VarySchedule \| VaryWorld \| VaryValue)` | hermetic, cached "unchanged across a variation" cases | same-program variations; no version pair, no report of *where* results differ |
| exhaustive Warp properties with budgets | `jacquard test --exhaustive --budget` | complete bounded search, reported as complete or not | pass/fail per property, not a comparison report |
| schedule traces and policies | `--schedule-record`, `--schedules`, `src/scope_policy.ml` | deterministic schedules and strict replay | not tied to comparing two policy versions |
| checked identities | `Frontend.Checked` (RF.1); `interface-v1` pending (API.1) | program identity, and soon the interface identity used for compatibility | — |
| typed inference outcomes | INF.1, pending | exact versus sampled, complete versus exhausted, impossible, numerical failure | — |

## 3. User Scenarios

1. **Rule rollout.** An eligibility rule is tightened. The reviewer wants every
   declared applicant profile where the decision flips, grouped by the
   condition that explains the flip.
2. **Same answer, different effects.** A router returns the same route but now
   calls an audit service first. The review must show the new operation even
   though the results are equal.
3. **Rare-world disagreement.** A scheduling policy changes. The versions
   agree unless two of three workers are unavailable. The reviewer must see
   that case, how likely it is under the availability model, and a replay
   command. §6 is this scenario end to end.
4. **Sampled domain.** The input space is too large to enumerate. The review
   runs a seeded sample and must say so, in the report and in any summary.

## 4. Proposal

### 4.1 Inputs to a review

A review is fully determined by a **review request**:

```text
(behavior-review-request-v1
  (old <checked-artifact-hash> <entry-term-hash>)
  (new <checked-artifact-hash> <entry-term-hash>)
  (interface <interface-v1-identity>)           -- the shared entry signature
  (inputs <finite-domain-or-sampler>)           -- declared, never inferred
  (worlds <handler-identity>... | <world-model-identity>)
  (policy <obs-1-policy-identity>)              -- what is observed and how it is compared
  (budget (fuel <n>) (cases <n>))
  (seed <n>))                                   -- sampled domains only
```

- **Compatible interfaces.** Both versions' entries must have the same
  `interface-v1` export signature, as determined by `jacquard interface diff`
  (API.1). The diff must be `compatible` or `identical`. Otherwise the review
  is refused before anything runs, unless an explicit **adapter** term is named
  in the request, and the adapter's identity is reported. Program identity (the
  artifact) and interface identity are reported separately. This is RW.8's
  rule.
- **Declared inputs.** An input domain is one of:
  - a finite list, or a product of finite lists
  - a finite `Distribution` of inputs, enumerated exhaustively with its weights
  - a `Distribution` sampled with a seed

  There is no default domain, and nothing is inferred from types. A plain finite
  list carries **no probability**: it is enumerated for counts and witnesses,
  and it never receives an assumed uniform weight. When the review reports a
  probability, every input and world dimension must come from a declared
  `Distribution`. Otherwise the probability section reports probabilities per
  input value instead of one aggregate.
- **Case numbering.** Cases are numbered from 0 in the canonical order (§4.5).
  The readable report also prints the 1-based ordinal ("case 12 of 16" is case
  11).
- **Worlds.** A world is either a set of hermetic handlers (scripted and dry
  twins) or a finite world model. A world model is a `Distribution` over world
  values, for example which workers are available. Live handlers are never
  installed.

### 4.2 Observation equality

What counts as "the same behavior" is an **OBS.1 policy** (jacquard-lang:225),
named in the request and the report. It selects:

- the result value and its equality, either `run-transcript-v1` value equality
  or a named `Eq`
- which operations are observed, by operation identity, not display name
- which arguments and results of those operations are compared
- redaction rules applied before anything is persisted

A review therefore distinguishes *decision differences* (results differ) from
*effect differences* (results equal, observed operations differ), as scenario 2
requires. With the default policy the result and the ordered list of observed
operation identities and arguments are compared.

### 4.3 Status taxonomy

Every review, and every case within it, carries exactly one status:

| status | meaning | claim allowed |
|---|---|---|
| `exhaustive-complete` | every declared case ran to completion within budget | "on the declared domain and worlds, the versions agree except for these cases" |
| `exhaustive-incomplete` | the finite domain was not finished (case budget or fuel) | "on the cases run …"; the unrun remainder is counted |
| `sampled` | a seeded sample of a distribution domain | "in N sampled cases …" with the seed; never "agree" without qualification |
| `failed` | a case raised a runtime failure in either version | the failure is a finding, attributed to the version that failed |

A case in which one version fails and the other does not is a difference of
kind `failure`. It is never skipped.

### 4.4 Probability and cost comparison

When the worlds come from a world model, the review also reports the
probabilities below. If the inputs come from a declared finite distribution,
they are aggregated over the inputs too. If the inputs are a plain list, they
are reported for each input value (§4.1).

- the probability that the decision differs
- the probability of each changed effect

Both are computed by exact enumeration, as INF.1 outcomes with their metadata.
If the model assigns a cost to outcomes (a `(input, world, result) -> Real`
function named in the request), the review adds the expected cost under each
version and the difference. These are `dist-diff` generalized from result
distributions to paired decisions. Sampled worlds make these estimates, and
they are labeled.

### 4.5 The report: `behavior-review-report-v1`

The report is data. The text rendering and the Host view are both views of it.

```text
(behavior-review-report-v1
  (request <review-request-hash>) (status exhaustive-complete)
  (identities (old ...) (new ...) (interface ...) (worlds ...) (policy ...) (budget ...))
  (counts (cases 16) (agree 13) (differ 3) (failed 0) (unrun 0))
  (differences
    (group (condition <code>) (kind decision) (cases 3)
           (witness (case 11) (input <code>) (world <code>)
                    (old (result <code>) (effects ...))
                    (new (result <code>) (effects ...))
                    (replay "jacquard review replay <report> --case 11"))))
  (probability (differ 0.0135) (method exact) (complete true))
  (claims declared-support-only))
```

- **Grouping.** Differing cases are grouped by a **condition**, a conjunction
  of input and world field values that holds for every case in the group and
  for no agreeing case. Conditions are computed only over declared finite
  fields. When no such conjunction exists, the group is "ungrouped" rather than
  an invented explanation.
- **Deterministic witness selection.** The witness of a group is the first
  differing case in the declared canonical order. Inputs and worlds are
  enumerated in declaration order, and constructors in declaration order. The
  same request always yields the same witness.
- **Optional minimization.** Minimization is DEBUG.1 (jacquard-lang:229). When
  requested, the review calls it with the request's declared intervention
  space and distance function. The result is labeled `globally-minimal` (in an
  exhausted finite domain), `locally-minimal`, or `best-found`. Minimization
  never changes the reported counts.
- `(claims declared-support-only)` is a fixed field. The rendered report
  repeats it in words.

### 4.6 Export and replay

- `jacquard review replay REPORT --case N` reruns one case under both versions
  and prints the two executions side by side. It uses the recorded identities,
  so it refuses if either artifact is missing from the store or has a
  different hash.
- `jacquard review export REPORT --case N -o case.jac` writes a Warp `Case`
  that pins the case against the **new** version's behavior (the intended
  change), with the old result recorded in a comment. The case is hermetic
  and cached like any Warp test. A reviewer who wants "unchanged" regression
  coverage exports an agreeing case instead.

## 5. Bounded First Release

The first release is RW.8 (jacquard-lang:228) with this design's report
contract (§4.3, §4.5), plus REV.1–REV.3 (§11):

- finite domains and finite world models only
- exact probability comparison
- decision and effect differences under one OBS.1 policy
- deterministic witnesses and condition grouping over finite fields
- replay and export

Sampled domains ship in RW.8 as specified there, and are labeled `sampled`.
Minimization (DEBUG.1) and the Host reviewer (jacquard-host:11) consume the
report and are sequenced after it.

## 6. End-To-End Example: A Scheduling Policy Change

Three workers, each `Up` or `Down`; a job is `High` or `Low` priority. The old
policy sends every job to the first available worker. The new policy keeps the
last available worker for high-priority work.

```jacquard
-- proposed example; `review` commands are proposed in §4.6
type Worker = | W1 | W2 | W3
type State = | Up | Down
type Availability = | Availability(w1: State, w2: State, w3: State)
type Priority = | High | Low
type Assignment = | Dispatch(Worker) | Hold | Queue

up?(a, w) = match w {
  | W1 -> match availability.w1(a) { | Up -> True | Down -> False }
  | W2 -> match availability.w2(a) { | Up -> True | Down -> False }
  | W3 -> match availability.w3(a) { | Up -> True | Down -> False }
}

available(a) = list.filter([W1, W2, W3], fn (w) -> up?(a, w))

old-assign(job, a) = match available(a) {
  | Nil -> Queue
  | Cons(w, _) -> Dispatch(w)
}

new-assign(job, a) = match available(a) {
  | Nil -> Queue
  | Cons(w, Nil) -> match job { | High -> Dispatch(w) | Low -> Hold }
  | Cons(w, _) -> Dispatch(w)
}
```

The request declares:

- **inputs:** `Categorical([MkPair(High, 0.5), MkPair(Low, 0.5)])`, a declared
  finite input distribution, enumerated exhaustively. As a plain list
  `[High, Low]`, the counts and witness would be the same, but the probability
  section would report each priority separately (§4.1).
- **worlds:** all 8 availabilities, as a finite domain, plus a world model in
  which each worker is `Down` independently with probability 0.1
- **policy:** the default policy, observing the result and the `dispatch`/`hold`
  operations that the effectful wrapper performs

**Readable report:**

```text
Behavior review: old 3f2a…e1 → new 9c07…4b   interface assign-v1 (compatible)
Worlds: availability, 8 declared; model "independent-outage 0.1"
Observation policy: decision+effects (obs-policy 51d0…)
Exhaustive over the declared support: 16 cases, all complete.

  13 cases agree.
   3 cases differ — decision:
     when priority = Low and exactly one worker is Up
     witness (case 12 of 16): Low job, only W1 Up
       old: Dispatch(W1)   effects: dispatch(W1, job)
       new: Hold           effects: hold(job)
     replay: jacquard review replay review.report --case 11

Under the world model, a decision differs with probability 1.35% (exact):
  P(exactly one worker Up) = 3 × 0.9 × 0.1 × 0.1 = 2.7%, times P(Low) = 50% (declared).
Minimal: the witness is at distance 2 (two workers Down) from all-Up, and no
differing case is closer (globally minimal within the exhausted domain).

This review covers only the declared inputs and worlds. It does not show that
the versions are equivalent anywhere else.
```

**Machine-readable data**, the same report, abridged:

```text
(behavior-review-report-v1
  (status exhaustive-complete)
  (counts (cases 16) (agree 13) (differ 3) (failed 0) (unrun 0))
  (differences
    (group (condition (and (eq priority Low) (eq (count-up) 1))) (kind decision) (cases 3)
      (witness (case 11) (input Low) (world (Availability Up Down Down))
        (old (result (Dispatch W1)) (effects ((op dispatch (W1 job)))))
        (new (result Hold) (effects ((op hold (job)))))
        (minimality globally-minimal 2))))
  (probability (differ 0.0135) (method exact-enumeration) (complete true))
  (claims declared-support-only))
```

Check values:

- 16 cases: 2 priorities × 8 availabilities.
- The differing cases are the Low job under availabilities with exactly one `Up`
  worker, (U,D,D), (D,U,D) and (D,D,U). That is 3 cases.
- The canonical order is `High` before `Low`, then availabilities
  lexicographic with `Up` before `Down`. So the first differing case is
  `Low × (U,D,D)`: index 11, the 12th of 16.
- P(differ) = 3 × 0.9 × 0.1² × 0.5 = 0.0135, where 0.5 is the declared
  input weight of `Low`.
- `count-up` in the condition is a declared derived field. Conditions over
  derived fields must be named in the request, so the grouping never invents
  them.

## 7. Alternatives Considered

| alternative | why not |
|---|---|
| Report equivalence when no difference is found | Unsound outside the declared support. Only `exhaustive-complete` over a declared domain earns "agree on this domain" |
| Random testing as the default | Hides the rare-world disagreement: at 1.35 %, a 100-case sample misses it about a quarter of the time. Exhaustive finite review is the default, and sampling is explicit |
| Build on `relate` directly | `relate` varies one program. A version pair needs two artifacts, interface compatibility, and grouping. The report shares `run-transcript-v1` equality instead |
| Compare structural diffs and infer behavior | Structure cannot show world-dependent disagreement. `jacquard diff` stays the structural companion in the report header |
| Rich automatic explanations (decision trees over all fields) | Invented explanations mislead. Conditions are exact conjunctions over declared fields, or "ungrouped" |

## 8. Non-Goals, Compatibility, Failure

**Non-goals:**

- behavioral equivalence proofs
- symbolic or SMT-based comparison
- comparison across incompatible interfaces without an explicit adapter
- live-world execution
- unbounded or type-derived input domains
- causal explanation of *why* a version decides as it does, beyond the
  condition over declared fields
- a Host user interface, which is jacquard-host:11

**Compatibility.** There are no kernel, `.jqd`, `HASH_V0`, or store changes.
`relate`, `diff`, `dist-diff` and Warp keep their behavior. The report and
request formats are new and versioned (`-v1`). The CLI is a new `jacquard
review` group.

**Failure behavior:**

| situation | result |
|---|---|
| incompatible interfaces, no adapter | refused before running, with the `interface diff` explanation |
| an artifact missing from the store, or its hash mismatched | refused |
| a case fails in one version | a `failure` difference, attributed to that version |
| the budget is reached | status `exhaustive-incomplete`, with the unrun count |
| a world model probability fails INF.1 classification | the probability section carries that outcome (impossible, numeric, exhausted); counts are unaffected |
| an OBS.1 policy selects a redacted field for equality | refused at request validation (policy error) |

## 9. Validation And Measurable Acceptance

- **The §6 example.** It runs as a cram and produces byte-identical text and
  data reports:
  - 16 cases, 13 agree, 3 differ
  - witness case 11
  - P(differ) = 0.0135 within 1e-12
- **Effect-only differences** (scenario 2) are detected with equal results.
- **Each failure behavior** in §8 has a negative test with its exact message.
- **Determinism.** The same request gives a byte-identical report, the same
  witness, and the same grouping.
- **Sampled review.** It is reproducible for a fixed seed and never renders
  "agree" without "in N sampled cases".
- **Replay and export.** `review replay` reproduces the witness under both
  versions. The exported Warp case passes on the new version and fails on
  the old.
- **The Host reviewer (jacquard-host:11)** renders the same counts,
  statuses and witness as the text report for the §6 request. This is checked
  in that repository.

## 10. Decisions Requiring Owner Direction

1. **The report contract belongs to RW.8.** The recommendation is to refine
   jacquard-lang:228 to adopt §4.3/§4.5 as its "stable machine-readable
   report", rather than a second engine.
2. **Exact conjunction grouping only** (§4.5). There are no heuristic
   explanations.
3. **Exports pin the new behavior by default** (§4.6).
4. **Adapters** are explicit named terms whose identity joins the review
   identity.
5. **The CLI group name** `jacquard review`.

## 11. Follow-Up Backlog And Reconciliation

### Existing tasks reused or refined

| task | relationship |
|---|---|
| jacquard-lang:228 RW.8 compare two program versions | **Reused, and refined** to adopt this design's request, status taxonomy and report (§4.1–§4.5). It is the engine, and no new engine task is created |
| jacquard-lang:225 OBS.1 observation and comparison policies | **Reused** for observation equality and redaction (§4.2) |
| jacquard-lang:229 DEBUG.1 counterfactual search and minimization | **Reused** for optional minimization. It consumes the review's intervention space and returns minimality labels (§4.5) |
| jacquard-host:11 APP.1 Python-hosted decision-change reviewer | **Reused as the Host presentation** of `behavior-review-report-v1`. It is already gated on jacquard-lang:228, and this design does not edit the Host plan |
| jacquard-lang:223 INF.1, jacquard-lang:216 API.1 | **Reused** for probability outcomes and interface compatibility |

### New tasks (jacquard-lang master tag)

| id | title | depends on | priority |
|---|---|---|---|
| jacquard-lang:265 REV.1 | Probability and cost comparison in behavior reviews over finite world models | 228, 223 | medium |
| jacquard-lang:266 REV.2 | `jacquard review replay` and `review export` to a hermetic Warp case | 228 | medium |
| jacquard-lang:267 REV.3 | Scheduling-policy review example (§6) with readable and machine-readable transcripts | 265, 266 | medium |

Each task's details and test strategy carry its acceptance criteria from §9.
