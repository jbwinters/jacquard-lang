# Surface-readability benchmark protocol v0

Status: preregistered; no human or model outcomes collected. Protocol ID:
`readability-protocol-v0`.

This benchmark replaces preference polling with review work. It asks whether a
reviewer can find a seeded bug, predict observable output, and spot an authority
escalation in canonical `.jac`, bootstrap `.jqd`, or a matched Python control.
UX.0 freezes the method and synthetic evidence only. A separately reviewed
execution phase may collect results.

## Questions and hypotheses

The three reviewer jobs are fixed:

1. Find a seeded bug in a factorial program that returns zero.
2. Predict observable output from a branching program.
3. Spot an authority escalation caused by dynamic evaluation.

The confirmatory comparison is `.jac` versus `.jqd`; its null is no change in
correctness or completion time. Those measures are co-primary. Python is a
descriptive calibration control. Confidence and the deterministic error
taxonomy are secondary. A result about one job is not generalized to another.

Python is a task-equivalent calibration control, not a semantic twin. It does
not share Jacquard's HASH_V0 identity, 27-form kernel, effect rows, capability
refusal, integer rules, evaluator, or runtime. Only the question and pinned
stdout are matched. The `.jac` and `.jqd` carriers must retain byte-identical
semantic-hash output and observable behavior before any trial.

## Design and assignment

The human study is randomized, between-subject, and balanced. Each participant
sees one carrier and all three jobs, so nobody sees the same semantic problem in
two syntaxes. The six possible job orders are counterbalanced within every
carrier. One block contains the 18 carrier/order cells exactly once.

After eligibility and consent, an operator assigns a monotonically increasing
enrollment ordinal. The checked-in tool sorts each 18-cell block by SHA-256 of
the public seed, block, carrier, and order. The confirmatory seed is
`jacquard-readability-v0`. Operators may not skip an ordinal after learning its
assignment or selectively replace excluded participants.

The model study uses the same nine carrier/job conditions, but each trial runs
in a fresh session. Dispatch order is SHA-256 ordered by condition and
repetition under the same seed. Human and model results are reported and
analyzed separately; model subjects do not substitute for human evidence.

## Fixtures and presentation

The reviewed answer key, source paths, SHA-256 digests, expected stdout, and
Jacquard hashes live in `test/readability/fixture-manifest.json`. The paired
`.jac`/`.jqd` files are conformance fixtures, not a requirement to publish
bootstrap twins for ordinary programs. They are Apache-2.0 with the repository.
Python's matching limits are part of the manifest and verifier.

Every trial is accessible UTF-8 plain text (`text/plain`) with no syntax highlighting, ANSI styling,
language-tagged fence, HTML span, hover aid, editor service, or automatic
formatting. All carriers use the same font, size, contrast, line height,
viewport, prompt placement, and controls. Line wrapping is off; horizontal
scrolling is available. Screen-reader participants receive the same bytes and
labels in reading order. Zoom and operating-system accessibility tools are
allowed. Running code, search, assistants, external documentation, and editor
tooling are prohibited.

The answer key is never rendered. A five-minute practice explains the answer
controls and call, match, quotation, and dynamic-evaluation notation using
examples that are not fixtures. Practice outcomes are not recorded.

## Human sample size and procedure

Recruit 480 adults who self-attest that they can read small Python-like programs
and have at least one year of programming or review experience. Jacquard
experience is neither required nor screened. Assignment yields 160 enrolled
participants per carrier before exclusions. There is no optional stopping.

Split family-wise alpha 0.05 equally between the two co-primary outcome
families. At two-sided alpha 0.025, 128 analyzable participants per Jacquard
carrier provide about 80% power for a standardized log-time effect of 0.386—
roughly a 20% time change at coefficient of variation 0.5. Holm correction of
the three job-specific accuracy comparisons still needs fewer than 100 per
carrier to distinguish 70% from 90% accuracy. The target of 141 analyzable per
carrier covers both calculations; recruiting 160 allows about 10% exclusion.
Fewer than 141 analyzable participants in either Jacquard carrier makes the
confirmatory comparison inconclusive. Python sample size remains balanced but
does not enter the confirmatory power claim.

Procedure:

1. Show the approved information sheet and record consent version outside the
   answer dataset.
2. Record eligibility, prior fixture exposure, duplicate enrollment, and the
   no-tools agreement.
3. Allocate the next ordinal and render its carrier/order.
4. Start a monotonic timer when the prompt and complete source are visible.
5. Accept one answer ID and confidence from 0 through 100; stop on submission.
6. At 300,000 ms, record `__timeout__`, zero correctness, and the full timeout.
7. Ask once about prior exposure and tool use, then apply only frozen exclusions.

## Model condition and contamination control

The manifest pins Anthropic `claude-fable-5`, Claude Code 2.1.212, temperature
0.0, 30 fresh repetitions per condition, exact prompt digest, disabled tools,
disabled session memory, and no implementation conversation. Output must be
only the specified JSON object. A parse failure is not retried.

Before collection, the provider or deployment owner must attest that training
cutoff predates fixture publication. Otherwise rows receive
`model-training-contamination` and cannot support confirmatory claims. Returned
model/client drift, prompt drift, temperature drift, tool use, or memory use is
not interchangeable. Post-publication models are exploratory only and cannot
repair missing human evidence.

## Scoring, timing, and exclusions

Answers are opaque option IDs. The manifest maps one correct ID and every wrong
ID to an error category. Unknown IDs are `invalid-answer`; timeouts are
`timeout`. Correctness and error code are computed, never operator-entered.
Completion time is integer monotonic milliseconds capped at five minutes. No
winsorization or post-hoc speed cutoff is allowed.

Human exclusions are exactly: no consent, failed eligibility, prior frozen
fixture exposure, prohibited tool use, duplicate enrollment, or more than one
verified presentation/system failure. One system failure excludes that trial
only and reruns it last. Incorrect answers, low confidence, timeouts, surprising
results, and ordinary accessibility tools are not exclusions.

Model exclusions are exactly: unverified pre-publication training cutoff,
pinned model/client drift, prompt parse failure, or more than one system
failure. Exclusion counts and reasons are published by carrier and cohort before
outcomes are unblinded.

## Data, consent, privacy, and licensing

UX.0 collects no real data. Before UX.1, the information sheet, recruitment,
compensation, retention, publication license, and consent flow require the
applicable owner and ethics/privacy approval. A mandated change creates a new
protocol version before collection.

Rows contain a salted pseudonymous ID, answer ID, timing, confidence, assignment
and fixture digests, exclusions, and protocol/model metadata. They contain no
name, email, IP, free text, raw model conversation, compensation ID, or salt.
Contact/compensation data stays separate; linkage is deleted after payment and
withdrawal periods. Consent records are separate and rows carry only the
version. De-identified publication and licensing must match that consent;
Apache-2.0 covers fixtures/tooling, not participant data automatically.

`test/readability/result.schema.json` is the machine-readable JSON Schema
2020-12 contract. Results are JSONL. Canonical row IDs hash the row without
`row_id`. Unknown fields, free-form notes, highlighting, inconsistent scoring,
wrong fixture digests, and cohort drift are rejected.

## Analysis and syntax-amendment rule

Publish enrolled/excluded/analyzable/timeout flow first. Human and model tables
stay separate. By job/carrier, report accuracy with Wilson interval, completion
median and log-mean, confidence distribution, and error counts. Pairwise
`.jac`/`.jqd` accuracy uses Newcombe-Wilson difference intervals with Holm
correction across jobs. Time uses each participant's geometric mean across jobs,
a Welch interval on log milliseconds, and the exponentiated ratio. Allocate
alpha 0.025 to each co-primary family. Python is descriptive context, never
semantic or confirmatory evidence.

A later syntax amendment uses new participants, identical assignment and
presentation rules, a preregistered seed, and fixtures with the same bootstrap
identity and behavior. Compare it directly with current `.jac`:

- **Pass:** every adjusted lower accuracy-difference bound is above -5 points,
  the authority-escalation bound is above -2 points, and the adjusted upper
  pooled completion-time ratio is below 0.90 (at least 10% faster).
- **Fail:** unintended identity/behavior drift; any adjusted upper accuracy
  bound below -5 points; the authority bound below -2; or an adjusted lower
  time-ratio bound above 1.10.
- **Inconclusive:** every other result, including mixed benefits, insufficient
  sample, protocol drift, contamination, or intervals crossing thresholds.

Pass supports but does not automatically merge an amendment. Inconclusive
authorizes neither acceptance nor rejection and cannot be relabeled after
subgrouping.

## Reproduction

From the repository root:

```text
eval "$(opam env)"
mkdir -p "$PWD/.scratch/tmp" "$PWD/.scratch/readability"
export TMPDIR="$PWD/.scratch/tmp"
opam exec -- dune build @readability-protocol
python3 test/readability/readability_benchmark.py dry-run --seed ux0-review \
  --manifest test/readability/fixture-manifest.json \
  --schema test/readability/result.schema.json \
  > .scratch/readability/dry-run.jsonl
python3 test/readability/readability_benchmark.py validate-results \
  --manifest test/readability/fixture-manifest.json \
  --schema test/readability/result.schema.json \
  --input .scratch/readability/dry-run.jsonl
```

The dry run emits exactly one synthetic valid row for each of nine conditions
and makes no performance claim. Disposable assignments, renderings, logs, and
execution stores remain under `.scratch/`. Protocol, fixture bytes, answer key,
schema, model pin, exclusions, scoring, or threshold changes require a new
version and review before further collection.
