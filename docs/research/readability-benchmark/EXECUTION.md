# Readability protocol v1 execution gate

Status: deterministic planning, fail-closed result admission, analyzability,
and descriptive-table tools are implemented. The checked manifests do not
authorize real collection, and no human or model outcomes exist.

The [protocol](PROTOCOL.md) defines the study. This document separates a
reproducible plan from external authority. A generated schedule proves that
planned cells are complete and balanced. It is not consent, ethics or privacy
approval, funded compensation, a model attestation, quota, or permission to
collect data.

## Fail-closed authority boundary

The operator must create a reviewed authority manifest outside the public
result rows. It must record all nine approved areas in
`authority-manifest.template.json`, identify the approving authority and date,
pin an evidence digest, and set `collection_authorized` only after the evidence
exists. Do not commit names, contact data, consent records, secrets, or private
approval documents.

For model collection, the selected cohort manifest must also record available
access, an attested pre-publication training cutoff, confirmed quota/rate
limits, and explicit collection authorization. The checked M0 Fable 5 manifest
has each of those states pending. `collection-gate` accepts only a separately
reviewed authority manifest whose nine areas are approved; a model gate also
requires available access, an attested cutoff, confirmed quota covering the
whole schedule, and explicit cohort collection authorization. It reads and
checks those files but cannot create an approval or contact a provider:

```text
python3 test/readability/readability_benchmark.py collection-gate \
  --manifest test/readability/fixture-manifest.json \
  --schema test/readability/result.schema.json \
  --authority AUTHORITY.json
python3 test/readability/readability_benchmark.py collection-gate \
  --manifest test/readability/fixture-manifest.json \
  --schema test/readability/result.schema.json \
  --authority AUTHORITY.json --cohort COHORT.json
```

The gate prints the exact fixture-manifest, schema, authority, and optional
cohort digests that admitted rows must carry. The pending checked templates
fail these commands. Model availability never delays or substitutes for the
primary human study.

Do not weaken the gate to start a study. A required change to protocol,
fixtures, schema, answer key, exclusions, presentation, consent, or data terms
creates a new reviewed version before collection.

## Human assignment plan

Generate the full plan before recruitment:

```text
python3 test/readability/readability_benchmark.py human-schedule \
  > .scratch/readability/human-schedule.jsonl
```

The output has 480 zero-based enrollment ordinals and no identity, contact,
consent, compensation, or outcome data. The seed assigns 160 enrollments to
each carrier. Every complete block of 30 contains three carriers by ten
Williams job orders. Within each carrier, every job appears twice in every
position and every ordered adjacent job pair appears twice.

Reviewed JSONL SHA-256:
`356f000ba5af0421ef6eaaf246bbb78527ff9ffb97f61d84f5f795d96b114178`.

The operator allocates the next ordinal only after eligibility and consent and
may not skip it after seeing the assignment. Private enrollment and payment
records never enter the schedule or published results.

The `assign --seed ... --ordinal ...` command is a debugging aid for inspecting
the balancing algorithm. It is not an alternate schedule: every admitted real
row is re-derived with the frozen `jacquard-readability-v1` seed.

## Model cohort plan

Generate a plan for exactly one reviewed cohort without contacting its
provider:

```text
python3 test/readability/readability_benchmark.py model-schedule \
  --manifest test/readability/fixture-manifest.json \
  --cohort test/readability/cohorts/m0-fable5.json \
  > .scratch/readability/model-schedule-m0.jsonl
```

M0 currently plans 450 trials: three carriers by five jobs by 30 repetitions.
Each row pins the cohort-manifest digest, model/client/control, prompt and
fixture digests, seed, isolation controls, attestation/quota status, and
collection-authorization state. The pending states are visible in every row;
the schedule is not executable study authority.

Dispatch order is ascending SHA-256 of this exact UTF-8 sequence:

```text
jacquard-readability-v1\0cohort=M0\0carrier=<carrier>\0job=<job>\0repetition=<1..30>
```

Here `\0` means one NUL byte. A real dispatcher uses ordinal order, a fresh
session for each row, disabled tools and memory, and no retry after parse
failure. The repository deliberately has no provider dispatcher, so local
verification cannot silently spend quota or create unauthorized outcomes.

Reviewed M0 JSONL SHA-256:
`69178f914457cbe0cf6081f10fa6b018267ec0876175ddc7b44bc8f92c735e4e`.

A Sol or other model run requires a different attested cohort ID and manifest.
It is never substituted for M0 and its rows and analysis remain separate.

## Result validation and preservation

`validate-results` validates one complete single-kind JSONL store. Human stores
require the exact fixture, schema, and approved authority manifest. Model stores
also require their exact collectible cohort manifest. The digest written in a
real row is SHA-256 over the exact supplied manifest bytes, so reformatting or
editing a manifest cannot silently reclassify old evidence.

```text
python3 test/readability/readability_benchmark.py validate-results \
  --manifest test/readability/fixture-manifest.json \
  --schema test/readability/result.schema.json \
  --authority AUTHORITY.json \
  --input HUMAN-RESULTS.jsonl

python3 test/readability/readability_benchmark.py validate-results \
  --manifest test/readability/fixture-manifest.json \
  --schema test/readability/result.schema.json \
  --authority AUTHORITY.json --cohort COHORT.json \
  --input MODEL-RESULTS.jsonl
```

Human JSONL is chronological: all 480 ordinals appear once in order, each with
five first attempts in its frozen Williams order. Exactly one failed first
attempt must have one final attempt-2 row for the same job; the failed row stays
in the file. More than one first-attempt system failure excludes the subject
and permits no retry. Model JSONL contains every cohort cell once in dispatch
ordinal order, uses a unique pseudonymous session ID for every row, and never
retries. An observed pinned-client/model/prompt drift may be preserved only as
an excluded `model-version-drift` row under the intended cohort digest; another
cohort ID or digest is rejected as substitution.

The validator rejects empty, partial, mixed, duplicated, reordered, wrong-seed,
wrong-fixture, wrong-authority, cross-cohort, and schedule-drifted stores. It
evaluates the checked Draft 2020-12 `oneOf`, `allOf`, and `if`/`then` branches,
then enforces cross-row rules. Synthetic stores remain allowed with the pending
checked manifests only because they are `dry-run`, contain all 15 conditions,
and carry no real-study metadata. `consent_version` is only the reviewed flow
identifier; consent decisions and contact records remain outside result data.
No-consent and failed-eligibility records stay in the separate enrollment flow
and are rejected if placed in answer JSONL.

Preserve, under the approved data controls:

- de-identified result rows and enrollment/exclusion flow;
- human and model schedules, public seeds, and every cohort manifest;
- consent/publication authority digests, not private source documents;
- presentation and model failures, including non-retried parse failures;
- preregistered analysis code and generated tables; and
- the blinded independent rescoring record.

No human-identifying data, provider secrets, raw model conversations, or
synthetic rows represented as outcomes may be committed.

## Deterministic analysis input

After `validate-results` accepts a complete store, prepare its versioned row
selection and provenance bundle with the same exact admission context:

```text
python3 test/readability/readability_benchmark.py prepare-analysis \
  --manifest test/readability/fixture-manifest.json \
  --schema test/readability/result.schema.json \
  --authority AUTHORITY.json \
  --input HUMAN-RESULTS.jsonl \
  > .scratch/readability/human-analysis-input.json

python3 test/readability/readability_benchmark.py prepare-analysis \
  --manifest test/readability/fixture-manifest.json \
  --schema test/readability/result.schema.json \
  --authority AUTHORITY.json --cohort COHORT.json \
  --input MODEL-RESULTS.jsonl \
  > .scratch/readability/model-analysis-input.json
```

The command validates the complete store before emitting anything. Its
canonical `readability-analysis-input-v1` JSON binds the exact source-file
SHA-256, ordered row identity, reviewed pins, per-subject decisions, and total
and per-carrier flow. A successful human retry replaces only its failed first
attempt; successful here means the retry itself did not have a system failure,
not that its answer was correct. More than one verified system failure,
including a failed retry, or
any stable non-system exclusion removes the whole human subject from effective
rows. Model sessions remain row-local. Source, effective, and excluded row-ID
lists partition the input so every count can be recomputed.

The output deliberately omits timestamps and measured outcomes. Running the
command twice on byte-identical input therefore produces byte-identical output.
Human pre-assignment consent and eligibility flow is `external-required`
because those approved records remain outside answer JSONL. This tool neither
creates that flow nor authorizes collection. Synthetic output is explicitly
non-citable; human and model output remains candidate evidence with no claim
evaluated.

## Deterministic descriptive tables

Produce the first measured-outcome stage directly from the same validated
store and admission context:

```text
python3 test/readability/readability_benchmark.py analyze-descriptive \
  --manifest test/readability/fixture-manifest.json \
  --schema test/readability/result.schema.json \
  --authority AUTHORITY.json \
  --input HUMAN-RESULTS.jsonl \
  > .scratch/readability/human-descriptive.json

python3 test/readability/readability_benchmark.py analyze-descriptive \
  --manifest test/readability/fixture-manifest.json \
  --schema test/readability/result.schema.json \
  --authority AUTHORITY.json --cohort COHORT.json \
  --input MODEL-RESULTS.jsonl \
  > .scratch/readability/model-descriptive.json
```

The command repeats complete result-store validation, prepares the exact
`readability-analysis-input-v1` selection in memory, and emits one canonical
`readability-descriptive-v1` object. Its provenance binds the exact source
JSONL, ordered source and effective row IDs, and SHA-256 of the canonical
analysis-input bytes. Only effective rows contribute outcomes; failed or
otherwise excluded rows remain visible through copied flow and per-condition
source/effective/excluded counts.

Perceived readability has its own table. Each of comprehension, review, defect
detection, modification/debugging, and diagnostic recovery has a separate
table with accuracy and 97.5% Wilson uncertainty, completion median and
log/geometric mean, confidence distribution and exact-level calibration,
error counts, and timeouts. Human output also reports presentation-order and
the four frozen expertise/familiarity strata within each functional outcome.
These are descriptive strata, not post-hoc subgroups or a fitted effect model.

Every derived decimal is a fixed 12-place string. The object has no timestamp,
raw subject identifier, free text, or checked-in output path. A zero-ms row is
retained and reported but makes log/geometric mean null; it is never silently
dropped or shifted. Running twice from byte-identical stores produces
byte-identical output. Synthetic output exercises all table shapes but remains
`synthetic-non-citable`; real human/model output remains candidate evidence
with claim status `not-evaluated`. Pairwise effects, multiplicity correction,
claim thresholds, blinded rescoring, and publication-number lineage are later
gates and cannot be inferred from this file.

## What the checked gate proves

`dune build @readability-protocol` verifies:

- the five outcome families, answer keys, source digests, behavior, and stable
  diagnostic pin;
- all 480 human ordinals, 160-per-carrier balance, Williams positions, and
  first-order carryover;
- all 450 M0 carrier/job/repetition cells and cohort-specific dispatch keys;
- exact prompt, client, control, fixture, cohort, isolation, attestation, and
  quota pins;
- the full v1 schema branches, canonical row IDs, reserved failure IDs, and
  deterministic scoring;
- authorized in-memory human/model admission fixtures plus adversarial
  authority, digest, assignment, cohort, repetition, retry, completeness,
  ordering, and fresh-session mutations; the fixtures are synthetic tests and
  are not collection authority or outcomes;
- deterministic analyzability provenance for clean stores, a successful retry,
  a failed retry, multiple first-attempt failures, stable subject exclusions,
  and an excluded model session, including exact-source digest sensitivity;
- deterministic descriptive tables for all six reporting families, exact
  effective-row selection, human expertise/presentation-order strata, model
  separation, timestamp omission, and byte-identical dual generation;
- unconditional rejection of real rows with the checked pending authority and
  M0 cohort manifests; and
- byte-identical schedule and dry-run generation.

It does not prove that approvals exist, the live host is accessible,
participants followed instructions, M0 is available or uncontaminated, quota
exists, or any readability claim is true. Those require real external
authority, collection, checked evidence, and reproducible analysis.
