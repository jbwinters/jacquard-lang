# Readability benchmark execution gate

Status: planning tools are implemented; collection is not authorized and no
human or model outcomes have been collected.

The frozen [protocol](PROTOCOL.md) defines what the study measures. This
document defines the boundary between making a deterministic plan and starting
the study. A generated schedule is evidence that the planned conditions are
complete and balanced. It is not consent, ethics or privacy approval, a model
attestation, or permission to collect data.

## Authority required before collection

The study operator must record all of the following outside the result rows
before enrolling a person or starting a model session:

1. the accountable study owner and operator;
2. the applicable ethics and privacy route, decision, and decision date;
3. approved information-sheet and consent-form versions;
4. recruitment source, eligibility wording, and the no-tools agreement;
5. compensation terms, funded budget, payment process, and withdrawal window;
6. the data controller, access list, storage location, deletion date, and
   incident contact;
7. the de-identified publication license agreed to by participants;
8. the accessible plain-text study host and a completed presentation check;
9. for confirmatory model rows, an attestation from the provider or deployment
   owner that the pinned model's training cutoff predates fixture publication.

A required change to the protocol, fixtures, schema, answer key, exclusions,
or consent/data terms must be versioned and reviewed before collection. Missing
authority fails closed. Synthetic dry runs and generated schedules cannot fill
in an approval or attestation.

## Human assignment plan

Generate the complete plan before recruitment:

```text
python3 test/readability/readability_benchmark.py human-schedule \
  > .scratch/readability/human-schedule.jsonl
```

The command emits 480 zero-based enrollment ordinals. Each row contains only
the frozen carrier and three-job presentation order; it contains no identity,
contact, consent, compensation, or outcome data. The confirmatory seed assigns
exactly 160 enrollments to each carrier. Every complete block of 18 ordinals
contains all carrier and job-order cells once.

The reviewed JSONL SHA-256 is
`c6421e9fff78b5fd7397e8c2aaeadee434c58c01c1d1d85aec224c4e2ec1a9be`.

The operator allocates the next ordinal only after eligibility and consent.
The operator may not skip an assignment after seeing it. Private enrollment,
consent, contact, and compensation records must not be added to this schedule
or to the published result rows.

## Model dispatch plan

Generate the complete plan without calling a model:

```text
python3 test/readability/readability_benchmark.py model-schedule \
  --manifest test/readability/fixture-manifest.json \
  > .scratch/readability/model-schedule.jsonl
```

The command emits 270 trials: three carriers by three jobs by 30 repetitions.
Every trial requires a fresh session with tools and session memory disabled.
Each row pins the reviewed model, client, temperature, prompt digest, fixture
digest, confirmatory seed digest, and isolation settings.

Dispatch order is ascending SHA-256 of this exact UTF-8 byte sequence:

```text
jacquard-readability-v0\0carrier=<carrier>\0job=<job>\0repetition=<1..30>
```

Here `\0` means one NUL byte, not the two printed characters backslash and
zero. The schedule records that digest as `dispatch_key_sha256`. A dispatcher
must use the rows in ordinal order and must not retry parse failures. Model or
client drift, prompt drift, tool use, memory use, and missing training-cutoff
attestation remain exclusions under the protocol.

The reviewed JSONL SHA-256 is
`ba972dfcd0738a7f3360f54179c95dc02140e84d21320474a9e410380f8071b5`.

The repository deliberately does not include a command that contacts a model.
That prevents a local verification command from silently spending quota,
changing external state, or creating results without the required attestation.

## What the checked gate proves

`dune build @readability-protocol` verifies:

- all 480 human ordinals are present, contiguous, and balanced 160 per carrier;
- every human row exactly matches the frozen seeded assignment function;
- all 270 model carrier/job/repetition cells occur exactly once;
- model dispatch keys are unique and in SHA-256 order;
- every model row retains the reviewed fixture, prompt, model, client,
  temperature, tool, memory, and fresh-session pins;
- repeated schedule generation is byte-identical JSON Lines.

It does not prove that approvals exist, presentation was accessible in the live
host, subjects followed instructions, the pinned model was uncontaminated, or
the study results support a readability claim. Those require the separately
reviewed execution and publication evidence required by Task UX.1.
