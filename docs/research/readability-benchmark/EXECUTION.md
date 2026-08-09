# Readability protocol v1 execution gate

Status: deterministic planning and validation tools are implemented. Real
collection is not authorized and no human or model outcomes exist.

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
has each of those states pending. The planning harness deliberately rejects
every real human or model row, even if a caller edits those states. A separately
reviewed result-admission gate must land before collection. Model availability
never delays or substitutes for the primary human study.

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

`validate-results` requires the exact fixture, cohort, authority, and schema
manifests. Synthetic rows validate with the checked pending manifests because
they are explicitly `dry-run`; this planning slice rejects every human or model
row. The v1 schema reserves schedule ordinals and authority/cohort digests so
the result-admission slice can prevent a later manifest edit from silently
reclassifying evidence.

Preserve, under the approved data controls:

- de-identified result rows and enrollment/exclusion flow;
- human and model schedules, public seeds, and every cohort manifest;
- consent/publication authority digests, not private source documents;
- presentation and model failures, including non-retried parse failures;
- preregistered analysis code and generated tables; and
- the blinded independent rescoring record.

No human-identifying data, provider secrets, raw model conversations, or
synthetic rows represented as outcomes may be committed.

## What the checked gate proves

`dune build @readability-protocol` verifies:

- the five outcome families, answer keys, source digests, behavior, and stable
  diagnostic pin;
- all 480 human ordinals, 160-per-carrier balance, Williams positions, and
  first-order carryover;
- all 450 M0 carrier/job/repetition cells and cohort-specific dispatch keys;
- exact prompt, client, control, fixture, cohort, isolation, attestation, and
  quota pins;
- v1 schema shape, canonical synthetic row IDs, invalid ratings/profiles, and
  unconditional rejection of real rows in the planning harness; and
- byte-identical schedule and dry-run generation.

It does not prove that approvals exist, the live host is accessible,
participants followed instructions, M0 is available or uncontaminated, quota
exists, or any readability claim is true. Those require real external
authority, collection, checked evidence, and reproducible analysis.
