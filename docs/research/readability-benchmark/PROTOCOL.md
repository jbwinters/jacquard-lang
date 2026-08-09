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

Recruit 480 adults who self-attest that they can read small Python-like
programs and have at least one year of programming or review experience. The
plan assigns 160 enrollments to each carrier. There is no optional stopping.
Fewer than 141 analyzable humans in either Jacquard carrier makes every
confirmatory `.jac`/`.jqd` readability claim inconclusive.

At two-sided alpha 0.025, 128 analyzable participants per Jacquard carrier give
about 80% power for a standardized log-time effect of 0.386, approximately a
20% time change at coefficient of variation 0.5. The target of 141 covers that
calculation and the prior accuracy calculation; enrolling 160 allows about 10%
exclusion. Python remains balanced but does not enter the confirmatory power
claim.

Before assignment, record only these de-identified reader covariates with the
result rows: years of programming experience, years of code-review experience,
prior Jacquard familiarity from 0 through 4, and functional-programming/domain
familiarity from 0 through 4. Analysis must report these strata or include them
as prespecified covariates. Names, contact details, IP addresses, free text, and
compensation identifiers are prohibited in result rows.

Procedure:

1. Show the approved information sheet and record its consent version outside
   the answer data.
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
the planning harness rejects every real result row. An approval-driven protocol,
fixture, schema, answer-key, exclusion, or data-term change requires a new
reviewed version before collection.

Rows use salted pseudonymous subject IDs and carry only answers, timing,
ratings, confidence, covariates, assignment/fixture/authority digests,
exclusions, and cohort metadata. The salt and consent/contact/compensation data
stay outside the results. Linkage is deleted after payment and withdrawal
periods. Publication and retention must match the approved consent and
publication license.

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

## Preregistered analysis and claim gate

Produce separate deterministic tables for perceived ratings, comprehension,
review, defect detection, modification/debugging, and diagnostic recovery.
Within each job/carrier report accuracy with Wilson uncertainty, completion
median and log-mean, rating and confidence distributions, calibration, error
counts, exclusions, and missingness. Report effect sizes and intervals, not
only p-values. Model presentation order, expertise, prior Jacquard/domain
knowledge, and learning/familiarity effects. Explain Python's control-language
limitations.

Pairwise `.jac`/`.jqd` accuracy uses Newcombe-Wilson difference intervals with
Holm correction across functional outcomes. Time uses each human's geometric
mean and Welch intervals on log milliseconds, then reports the exponentiated
ratio. Allocate family-wise alpha 0.025 to accuracy and 0.025 to time. Ratings
are secondary and cannot establish task success.

No measured readability claim may be published unless the approved protocol
and consent flow exist, both Jacquard carriers have at least 141 analyzable
humans, checked evidence validates, the preregistered analysis reproduces
byte-for-byte modulo declared timestamps, and every cited model cohort is
attested. Human evidence is always required.

- **Pass for a specific outcome claim:** the corrected interval supports the
  stated direction and the paired co-primary measure shows no material harm
  (accuracy lower bound above -5 points and completion-ratio upper bound below
  1.10). State the exact job or aggregate; do not say “readable” in general.
- **Fail:** fixture identity/behavior drift, authority/schema failure, an
  adjusted accuracy upper bound below -5 points, or a completion-ratio lower
  bound above 1.10.
- **Inconclusive:** every other result, including mixed measures, insufficient
  humans, protocol drift, contamination, or intervals crossing thresholds.

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
```

The dry run emits one synthetic, non-citable row for each of 15 conditions and
makes no readability or performance claim. Schedules, renderings, logs, and
stores remain under `.scratch/`. Generating a schedule is planning evidence,
not permission to collect outcomes. The [execution gate](EXECUTION.md) records
the exact fail-closed boundary.
