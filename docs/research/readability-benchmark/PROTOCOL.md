# Human-first readability benchmark protocol v1

Status: preregistered design; no human or model outcomes have been collected.
Protocol ID: `readability-protocol-v1`.

This protocol asks what readers can actually understand and change. It keeps a
subjective perceived-readability rating separate from correctness, completion
time, confidence, and diagnostic recovery. Human evidence is primary. Model
evidence is supplementary, cohort-specific, and cannot support a readability
claim by itself.

## Questions and outcome families

Each participant sees five fixed reviewer jobs in one source carrier:

1. **Comprehension:** predict observable output.
2. **Review:** spot an authority escalation caused by dynamic evaluation.
3. **Defect detection:** find a seeded bug in a factorial program.
4. **Modification/debugging:** identify the edit required by a changed
   behavioral requirement.
5. **Diagnostic recovery:** choose the repair for a stable not-callable
   diagnostic.

After each timed answer and before feedback, the participant rates perceived
readability from 1 (very hard) through 7 (very easy). A rating measures
preference or ease, not semantic transparency, debugging readability, or
actual understandability. Those constructs are reported separately by outcome
family. Confidence from 0 through 100 measures calibration and never replaces
correctness.

The confirmatory comparison is canonical `.jac` versus bootstrap `.jqd`.
Correctness and completion time are co-primary within each outcome family.
Perceived readability, confidence, calibration, and the frozen error taxonomy
are secondary. Python is a descriptive task-equivalent control. A result for
one family is not generalized to another.

Python does not share Jacquard's HASH_V0 identity, 27-form kernel, effect rows,
capability refusal, integer rules, evaluator, or runtime. Valid `.jac` and
`.jqd` fixtures must retain byte-identical semantic hashes and observable
behavior. The diagnostic-recovery pair is intentionally invalid and instead
pins the same stable Jacquard diagnostic code, `E0802`; its Python control pins
the task-equivalent `TypeError` class.

## Human design, assignment, and sample size

The study is randomized, between-subject, and balanced. A participant sees one
carrier and all five jobs, so nobody sees the same semantic problem in two
syntaxes. Ten Williams sequences counterbalance the five jobs. Across one
carrier's ten sequences, every job appears twice in every position and every
ordered adjacent pair appears twice. One assignment block contains all 30
carrier/sequence cells.

After eligibility and consent, the operator allocates the next monotonically
increasing enrollment ordinal. The checked-in planner sorts each block by
SHA-256 of the public seed, block, carrier, and order. The confirmatory seed is
`jacquard-readability-v1`. Operators may not skip an ordinal after learning its
assignment or selectively replace an excluded participant.

The frozen full-scale reference plan contains 480 adults who self-attest that
they can read small Python-like programs and have at least one year of
programming or review experience. It assigns 160 enrollment ordinals to each
carrier and has no optional-stopping rule. The schedule is a reproducibility
and harness-completeness artifact, not a required recruitment target. No
language idea, implementation task, or release decision waits for this study
or for any minimum participant count. A smaller future collection requires a
separately reviewed schedule/admission version and reports its actual sample
size rather than borrowing the full-scale plan's power assumptions.

The original power-planning calculation used two-sided alpha 0.025. It
estimated that 128 analyzable participants per Jacquard carrier would give
about 80% power for a standardized log-time effect of 0.386, approximately a
20% time change at coefficient of variation 0.5. The accuracy premise was 80%
power to distinguish 70% from 90% accuracy between two independent carriers.
For five functional outcomes, the conservative Bonferroni bound uses
two-sided alpha `0.025 / 5 = 0.005`; the standard two-proportion normal
approximation gives about 105 per carrier. The historical target of 141 covered
those premises plus exclusion headroom. It is a power-planning reference, not
a minimum, claim threshold, or product gate. Python remains balanced in the
reference schedule but does not enter the `.jac`/`.jqd` comparison.

Before assignment, record only these de-identified reader covariates with the
result rows: years of programming experience, years of code-review experience,
prior Jacquard familiarity from 0 through 4, and functional-programming/domain
familiarity from 0 through 4. Analysis must report these strata or include them
as prespecified covariates. Names, contact details, IP addresses, free text, and
compensation identifiers are prohibited in result rows.

Procedure:

1. Show the approved information sheet and keep the consent decision, contact
   record, and signed evidence outside the answer data. Each de-identified
   result row carries only the reviewed `consent_version` identifier.
2. Record eligibility, the de-identified expertise fields, prior fixture
   exposure, duplicate enrollment, and the no-tools agreement.
3. Allocate the next ordinal and render its carrier and Williams job order.
4. Start a monotonic timer when the complete prompt and source are visible.
5. Accept one answer ID and confidence; stop the task timer on submission.
6. Ask the 1-7 perceived-readability rating before feedback or the next task.
7. At 300,000 ms, record `__timeout__`, zero correctness, and the full timeout.
8. Ask once about prior exposure and tool use, then apply only frozen
   exclusions.

## Fixtures and accessible presentation

The reviewed answer key, source paths, SHA-256 digests, expected behavior, and
diagnostic pins live in `test/readability/fixture-manifest.json`. Paired
`.jac`/`.jqd` files are conformance fixtures, not ordinary publishing twins.
Fixtures and tooling are Apache-2.0; participant data is not automatically
licensed under Apache-2.0.

Every trial is accessible UTF-8 plain text with no syntax highlighting, ANSI
styling, language-tagged fence, HTML span, hover aid, editor service, or
automatic formatting. All carriers use the same font, size, contrast, line
height, viewport, prompt placement, and controls. Line wrapping is off and
horizontal scrolling is available. Screen-reader participants receive the
same bytes and labels in reading order. Zoom and operating-system accessibility
tools are allowed. Running code, search, assistants, external documentation,
and editor tooling are prohibited.

The answer key is never rendered. A five-minute practice explains controls and
notation with examples that are not fixtures. Practice outcomes are not
recorded.

## Model-family neutral cohorts

Each model cohort has its own checked versioned cohort manifest. It records the
provider, exact model ID, client name and version, effort or temperature
control, prompt digest, repetitions, access state, training-cutoff attestation,
quota constraints, tool and memory controls, and collection authorization.
Schedules and results carry the cohort manifest digest. Cohorts are never
silently substituted, pooled, or used to repair missing human evidence.

Fable 5 is reference cohort `M0` when access permits. Its checked manifest is
deliberately pending: access, training-cutoff attestation, and quota are not yet
confirmed, so it cannot produce accepted real rows. Sol xhigh may support
non-evidentiary synthetic harness work under `.scratch/`, or later run as its
own attested exploratory cohort. It must never be labeled as `M0` or pooled
with Fable.

Every model trial uses a fresh session with tools and session memory disabled.
The exact prompt requests only an answer ID, confidence, and 1-7 rating. A
parse failure is not retried. Provider/model/client/control/prompt drift is not
interchangeable. A reference cohort uses `confirmatory`; an exploratory cohort
uses `exploratory`. Human and model tables and inferences remain separate.

## Authority, consent, privacy, and licensing

No real collection starts until one authority manifest records approval for:

- accountable owner and operator;
- the applicable ethics and privacy route;
- information sheet, consent flow, recruitment, and eligibility wording;
- funded compensation, payment process, and withdrawal window;
- accessibility review of the live plain-text host;
- retention, access control, deletion, and incident response;
- the de-identified publication license; and
- data governance and publication authority.

The checked `authority-manifest.template.json` is intentionally unapproved and
cannot admit a real result row. The validator accepts a real row only when the
operator supplies a separately reviewed, fully approved authority manifest and
the row carries the SHA-256 of those exact manifest bytes. A model row also
requires an available, attested, quota-sufficient, collection-authorized cohort
manifest and its exact digest. The repository creates neither approval. An
approval-driven protocol, fixture, schema, answer-key, exclusion, presentation,
or data-term change requires a new reviewed version before collection.

Rows use salted pseudonymous subject IDs and carry only answers, timing,
ratings, confidence, covariates, assignment/fixture/authority digests,
schema digest, exclusions, and cohort metadata. The salt and
consent/contact/compensation data stay outside the results. Linkage is deleted
after payment and withdrawal periods. Publication and retention must match the
approved consent and publication license.

Final evidence stores are chronological JSONL and contain exactly one subject
kind. Human stores follow all 480 frozen ordinals in order, with five ordered
first attempts per participant and only the single preregistered final retry
after one system failure. Model stores cover every reviewed cohort schedule
cell in ordinal order and use a unique pseudonymous session ID per row. Empty,
partial, mixed, duplicated, reordered, cross-cohort, or substituted stores are
invalid. Excluded system, parse, contamination, and pinned-drift rows remain in
the store; exclusion never permits a row to change its intended cohort or
schedule cell.

## Scoring, exclusions, and missing data

Answers are opaque option IDs. The manifest maps one correct ID and every wrong
ID to an error category. Unknown IDs are `invalid-answer`; timeouts are
`timeout`. Reserved IDs `__system_failure__` and `__parse_failure__` preserve
excluded failures without storing raw content. Correctness and error code are
computed, never operator-entered.
Completion time is integer monotonic milliseconds capped at five minutes. No
winsorization or post-hoc speed cutoff is allowed.

Human exclusions are exactly: no consent, failed eligibility, prior frozen
fixture exposure, prohibited tool use, duplicate enrollment, or more than one
verified presentation/system failure. One failure excludes that trial and
reruns it last as `trial_attempt` 2; the excluded failure remains attempt 1.
Incorrect answers, low ratings or confidence, timeouts,
surprising results, and ordinary accessibility tools are not exclusions.

Model exclusions are exactly: unverified training cutoff, pinned cohort drift,
prompt parse failure, or more than one system failure. Enrollment, exclusion,
analyzable, failure, missing-data, and timeout flow is published by carrier and
cohort before outcomes are unblinded.

Analysis starts only after the complete answer store passes result validation.
The versioned `readability-analysis-input-v1` bundle binds the SHA-256 of the
exact JSONL bytes, the ordered canonical row IDs, and the existing schema,
fixture, authority, assignment, schedule, and cohort pins. It contains only
pseudonymous subject IDs, row IDs, selection decisions, and flow counts; it has
no timestamp or outcome statistic.

For a human with no system failure, all five first attempts are effective. One
failed first attempt remains excluded and its successful final retry replaces
it. Here successful means the retry itself did not have a system failure; an
incorrect answer or timeout remains an outcome. More than one verified system
failure, including a failed retry, excludes
the whole subject and makes none of that subject's rows effective. Any stable
non-system human exclusion also excludes the whole subject. Each model session
is effective exactly when its one admitted row is not excluded. Timeouts remain
outcomes, not exclusions. Human, model, and synthetic stores always produce
separate bundles; synthetic bundles are marked `synthetic-non-citable`, and
real-store bundles are candidate evidence with claim status `not-evaluated`.

Pre-assignment no-consent and eligibility counts remain in the separately
approved enrollment flow. They are reported as `external-required`, not
inferred or invented from answer rows.

## Prespecified analysis and evidence interpretation

Produce separate deterministic tables for perceived ratings, comprehension,
review, defect detection, modification/debugging, and diagnostic recovery.
Within each job/carrier report accuracy with Wilson uncertainty, completion
median and log-mean, rating and confidence distributions, calibration, error
counts, exclusions, and missingness. Report effect sizes and intervals, not
only p-values. Model presentation order, expertise, prior Jacquard/domain
knowledge, and learning/familiarity effects. Explain Python's control-language
limitations.

The first analysis stage is `readability-descriptive-v1`. It consumes only a
complete validated single-kind store and its exact
`readability-analysis-input-v1` selection. It reports 97.5% Wilson intervals,
completion median/log/geometric mean, exact confidence-level calibration,
rating and error distributions, source/effective/excluded counts, and human
presentation-order and expertise strata. Fixed 12-place decimal strings make
equal inputs byte-identical; raw collection timestamps are omitted. A zero-ms
observation is counted and leaves log/geometric means null rather than being
dropped or adjusted. These descriptive tables remain `not-evaluated`; they do
not perform the pairwise comparison.

The comparison stage is `readability-comparative-v1`. For each of the five
functional outcomes it reports `.jac` minus `.jqd` accuracy, a Newcombe method
10 Wilson-score difference interval without continuity correction, and a
supplementary two-sided pooled two-proportion score p-value. Accuracy has
family alpha 0.025. Each interval uses the conservative per-outcome alpha
`0.025 / 5 = 0.005`, giving nominal Bonferroni family coverage; Newcombe's
component interval is approximate, so the output does not call that coverage
exact. P-values receive standard Holm adjustment across the five outcomes.
Neither interval bounds nor adjusted p-values create an automatic verdict.

Time uses each human's geometric mean across the five functional jobs. A
two-sided Welch interval at alpha 0.025 compares the subject-level log
milliseconds, then exponentiates the `.jac` minus `.jqd` difference into a
`.jac`/`.jqd` ratio. Job-specific times remain descriptive. An effective
nonpositive completion time makes aggregate time inference unavailable; it is
never dropped or shifted. Python is descriptive context and model stores are
not substituted into this human comparison. Synthetic output exercises the
code as `synthetic-non-citable` and normally lacks enough subjects for a Welch
interval.

There is no automatic product or release gate and no minimum-human-count gate.
Readability ideas may be proposed, implemented, and reviewed without running
this study. Any future measured claim about people still requires real approved
human evidence, checked de-identified rows, reproducible analysis, the actual
sample and exclusion flow, effect estimates with uncertainty, deviations, and
plain limitations on generalization. Small or absent samples are not
population-level proof, but they do not become a blocker for language work.
Model or synthetic observations alone never become human evidence.

Dependency distance, referent tracking, ambiguity, nesting, identifier cueing,
canonical-format stability, diff stability, and code surprisal/naturalness may
explain results. Preference ratings, formula-like metrics, and surprisal are
not standalone gates.

## Reproduction without collection

From the repository root:

```text
eval "$(opam env)"
mkdir -p "$PWD/.scratch/tmp" "$PWD/.scratch/readability"
export TMPDIR="$PWD/.scratch/tmp"
opam exec -- dune build @readability-protocol
python3 test/readability/readability_benchmark.py dry-run --seed ux1-review \
  --manifest test/readability/fixture-manifest.json \
  --schema test/readability/result.schema.json \
  > .scratch/readability/dry-run.jsonl
python3 test/readability/readability_benchmark.py validate-results \
  --manifest test/readability/fixture-manifest.json \
  --schema test/readability/result.schema.json \
  --cohort test/readability/cohorts/m0-fable5.json \
  --authority test/readability/authority-manifest.template.json \
  --input .scratch/readability/dry-run.jsonl
python3 test/readability/readability_benchmark.py prepare-analysis \
  --manifest test/readability/fixture-manifest.json \
  --schema test/readability/result.schema.json \
  --authority test/readability/authority-manifest.template.json \
  --input .scratch/readability/dry-run.jsonl \
  > .scratch/readability/analysis-input.json
python3 test/readability/readability_benchmark.py analyze-descriptive \
  --manifest test/readability/fixture-manifest.json \
  --schema test/readability/result.schema.json \
  --authority test/readability/authority-manifest.template.json \
  --input .scratch/readability/dry-run.jsonl \
  > .scratch/readability/descriptive.json
python3 test/readability/readability_benchmark.py analyze-comparative \
  --manifest test/readability/fixture-manifest.json \
  --schema test/readability/result.schema.json \
  --authority test/readability/authority-manifest.template.json \
  --input .scratch/readability/dry-run.jsonl \
  > .scratch/readability/comparative.json
```

The dry run emits one synthetic, non-citable row for each of 15 conditions and
makes no readability or performance claim. The analysis-input file contains no
outcome analysis or claim. The descriptive file exercises every table but is
also synthetic, non-citable, and claim-free. The comparative file exercises the
five accuracy contrasts and aggregate-time availability rules, but its
synthetic source cannot support a human claim and its single observation per
carrier leaves aggregate time inference unavailable. It emits no automatic
verdict. Schedules, renderings, logs, stores, and generated bundles remain under
`.scratch/`. Generating a schedule is planning evidence, not permission to
collect outcomes. The
[execution gate](EXECUTION.md) records the exact fail-closed boundary.
