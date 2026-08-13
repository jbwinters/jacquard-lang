# Relational Warp lanes: testable hyperproperties

Status: **RW.0 frozen for v0 (2026-08-12); RW.1-RW.4 schedule and Secret tooling
shipped.** This document fixes the observation and variation contract for
implementation tasks RW.1 through RW.7. `run-transcript-v1`, its canonical
comparator, and `jacquard relate FILE --vary schedule=N|secret=NAME --seed S`
now ship. `SameUnder` and the other variation kinds remain future work.

Read this document with [Warp testing](warp-testing.md),
[structured concurrency](concurrency.md), and the
[effect taxonomy](effect-taxonomy.md). The first describes hermetic lanes and
their cache, the second defines deterministic schedules and replay traces, and
the third states the limits of secret opacity.

## Problem

Several Jacquard properties compare two executions rather than inspect one:

- Secret noninterference asks whether changing a secret payload changes an
  observable result or output. Secret opacity prevents ordinary rendering and
  conversion, but it is not taint tracking and does not prove this property.
- Schedule independence asks whether changing scheduler choices changes an
  observable result or output. The scheduled Warp lane proves that checks pass
  under each selected schedule; it does not compare the answers.
- World invariance asks whether two handlers intended to model the same
  outward interface produce the same answer. The type system checks the
  interface, not behavioral equivalence between handler implementations.

Relational lanes run a computation under a controlled variation, record a
defined observation from each run, and compare the observations. A passing
lane is evidence about that program and variation. It is not a language-wide
noninterference or equivalence proof.

## Frozen for v0

The six decisions in this section are the normative v0 contract.

### 1. Observation scope

A completed run is represented by an ordered sequence of observations, one
for each successfully evaluated top-level expression. Each observation has:

1. `value`: the exact bytes ordinary `jacquard run` writes for that result,
   namely the existing `Value.show` rendering followed by LF; and
2. `trace`: the routed operations reached while evaluating that expression,
   in evaluation order. Each trace event records the operation member's
   canonical hash. A Console event also records the exact bytes its handler
   emits; other routed events carry no output bytes. Operation arguments and
   handler return values are not observations.

The layer-2 `relate` command always compares both components. Trace inclusion
catches outward effect-order changes even when final values agree. It also
makes a program that prints a value obtained from `secret.expose` diverge when
the payload changes. Merely reading two different secret payloads does not
diverge: the secret operation identity is the same and its argument and result
are not recorded.

The layer-1 hermetic `SameUnder` lane compares result values only. That lane
has no root world grants and is intentionally the stronger-answer form of an
ordinary Warp case, as described under [Two layers](#two-layers).

`schedule-trace-v1` is not the routed trace above. The released schedule trace
is a replay artifact that records runnable queues and chosen tasks as well as
operation identities. Embedding its bytes would make two genuinely different
schedules unequal solely because their `chosen=` fields differ, even if their
results and outward operations agree. The run transcript therefore defines an
additive routed-observation stream and reuses the canonical operation hash
identity; it neither embeds nor changes schedule-trace bytes.

If a run fails before producing a result, `relate` reports that existing
failure and does not reclassify it as relational divergence. Only completed
observations enter a transcript.

### 2. Equality and `run-transcript-v1`

The canonical encoding is named `run-transcript-v1`. It is byte-oriented and
length-framed so Console text cannot be confused with structural lines. Its
grammar is:

    jacquard-run-transcript format=1 observations=<N>\n
    observation index=<I> value-bytes=<V> trace-events=<T>\n
    <exactly V raw value bytes>
    trace index=<J> operation=<HASH> output-bytes=<B>\n
    <exactly B raw output bytes>

The observation header and its value payload repeat `N` times. Each is
followed by exactly `T` trace headers and payloads. `I` starts at zero and
increases by one; `J` starts at zero for each observation and increases by
one. `<HASH>` is the 64-character lowercase hexadecimal spelling produced by
the existing canonical hash API. `<B>` is zero except when the routed Console
handler emits bytes.

Counts and lengths are unsigned decimal ASCII with no leading zero except the
number zero itself. Structural lines and the value rendering end in LF. Raw
Console payloads have no newline requirement. The last payload is followed by
the next length-framed header or by end of input; there is no implicit padding
or terminal marker. A transcript with no completed expressions consists only
of the header with `observations=0`.

Decoding is strict. It refuses an unknown version, reordered or misspelled
fields, noncanonical numbers or hashes, noncontiguous indices, truncated
payloads, incorrect counts, and bytes after the final declared payload. Every
accepted input satisfies:

    serialize(parse(bytes)) = bytes

Two transcripts are equal exactly when their complete canonical encodings are
byte-equal. The version belongs to this additive tooling format; it does not
change `HASH_V0`, canonical program serialization, stores, or schedule traces.

### 3. First-divergence rendering

Comparison decodes both transcripts and reports the first logical difference,
not the first raw byte offset. Order is observation index, then value, then
trace-event index; within a trace event the operation identity precedes its
output. If all shared entries agree and one side ends, the first missing
observation or event is the divergence.

The result kind is `value-divergence`, `trace-divergence`, or
`length-divergence`. Paths use forms such as `observation[0].value`,
`observation[0].trace[3]`, and `observation[2]`. Rendering follows
`src/diff.ml`: one `at PATH:` line followed by indented `-` and `+` rows. All
CLI and Warp callers use this single comparator and renderer.

Secret variation adds one mandatory presentation rule: before constructing a
diagnostic, the renderer replaces either derived payload wherever it occurs
in a differing value or Console payload with `<secret redacted>`. Neither
payload may appear in stdout, stderr, or a persisted diagnostic.

### 4. User-facing names

The Warp declaration is `SameUnder`, its closed variation carrier is
`Variation`, and the CLI verb is `relate`:

    SameUnder : (Text, Variation, () ->{| e} a) -> WarpDecl
    jacquard relate FILE --vary KIND --seed S

`SameUnder` states the assertion made by the case; `Variation` names the value
that selects what changes; `relate` is the command form. These are typed
prelude and CLI surfaces. They do not add a kernel form.

### 5. `VaryWorld` handler discipline

Both `VaryWorld` handlers must have equal fully elaborated outward effect
rows. Equality is checked after normal row elaboration, not by comparing
source spelling. A mismatch is a check-time refusal, not a relational test
failure.

This keeps the varied dimension to handler behavior. Allowing different rows
would also vary the computation's available interface and could turn missing
authority or an unhandled effect into a misleading equivalence result.

### 6. CLI exit and diagnostic contract

A relational divergence is diagnostic `E1003`, written to stderr, and exits
with status 1. RW.0 reserved the code; RW.3 now ships its row in
`docs/errors.md`. Equality exits 0.

Existing classifications remain in force: invalid command syntax uses
Cmdliner's status 124, evaluation/runtime failure uses status 2, and an
unhandled effect or grant refusal uses status 3. A failed constituent run
keeps its existing diagnostic and status. `E1003` reports only a successful
pair or set of runs whose frozen observations differ.

### RW.3 shipped schedule command

The shipped layer-2 surface is:

    jacquard relate FILE --vary schedule=N --seed S [--allow EFFECT ...]

`FILE`, `--vary`, and `--seed` are required. RW.3 accepts only positive
`schedule=N`; malformed, non-positive, and future variation spellings are
Cmdliner usage errors. Run 1 uses scheduler seed `S`. Later scheduler seeds are
successive distinct `Int64.to_int` outputs from the existing SplitMix64 stream
rooted at `S`. Dist and every other input keep root seed `S`.

Each constituent gets a fresh ephemeral store, evaluator, checker, recorder,
and seeded scheduler. Declarations and all top-level expressions run in source
order. Grants are forwarded unchanged, authority is checked before each
expression, and only successful expressions commit observations. Surface and
checker warnings are emitted only for run 1. Constituent values and Console
output do not reach success stdout; equality prints exactly
`relate runs=N seed=S verdict=equal`.

Console input is made reproducible without changing ordinary `jacquard run`.
Run 1 reads the process Console and captures each `read-line` result by ordinal.
Every later run gets a fresh cursor over that exact list. A later call beyond
the captured list returns EOF (`""`) and never consumes more process input.

Runs 2 through N compare with run 1 in order and stop at the first difference.
E1003 names one-based run indices and embeds the canonical zero-based RW.2
first-divergence frame. A constituent failure retains its ordinary status and
is never reclassified as E1003.

### RW.4 shipped Secret command

The second shipped layer-2 surface is:

    jacquard relate FILE --vary secret=NAME --seed S [--allow EFFECT ...]

It executes exactly two isolated constituents with scheduler and Dist seed
`S`. The first two full-width SplitMix64 outputs rooted at `S` become printable
payloads `rw-secret-v0-a-%016Lx` and `rw-secret-v0-b-%016Lx`. Only the canonical
latest key `JACQUARD_SECRET_V0_<lowercase-name-byte-hex>_LATEST` is overridden;
unrelated and versioned environment lookups retain their ordinary process
values. The overlay is local to each fresh evaluator and never mutates the
process environment.

The command forwards grants unchanged and therefore still requires
`--allow secret` when the program reaches Secret. It compares the complete raw
transcripts before applying redaction, so two exposed payloads sent to Console
remain a real trace divergence. Only presentation replaces every exact derived
payload occurrence with `<secret redacted>`, searching raw bytes before string
or JSON escaping. The same final boundary covers warnings, constituent
diagnostics, runtime errors, and unexpected process reports.

This is an exact-byte guarantee for the two derived payloads, not taint
tracking. It does not claim detection of fragments, hashes, encodings, or
other transformations, and it does not observe arguments or return values of
non-Console operations. Passing evidence remains scoped to the selected
program, name, and seed.

## Two layers

### Layer 1: hermetic Warp cases

`SameUnder` is a typed Warp declaration with a closed `Variation` carrier.
The initial variants are:

- `VarySchedule(n)`: run the thunk under `n` deterministically derived
  schedules and require identical result renderings. This strengthens
  "checks pass under every schedule" to "the answer agrees under every
  selected schedule." An exhaustive lane covers the schedules within its
  declared bound.
- `VaryWorld(handler_a, handler_b)`: run the thunk under two caller-supplied
  discharging handlers with equal checked outward rows and require identical
  result renderings.
- `VaryValue(gen, fn)`: generate a pair, apply `fn` to each member, and require
  identical result renderings.

These cases close hermetically like ordinary Warp cases. They hold no root
grants, are refused when their effect row cannot close, and participate in
the hermetic cache. Cache identity includes the variation and seed rather
than reusing an ordinary-case entry.

### Layer 2: root-driven CLI variation

The CLI can vary inputs and authority available only at the root. Schedule
variation ships in RW.3 and Secret variation ships in RW.4; grant variation
remains planned:

    jacquard relate FILE --vary schedule=N --seed S [--allow EFFECT ...]
    jacquard relate FILE --vary secret=NAME --seed S [--allow EFFECT ...]
    jacquard relate FILE --vary grant=EFFECT --seed S

Schedule variation derives distinct schedule seeds and compares each complete
run transcript with the first. Secret variation derives two distinct payloads
for the named root secret, forwards the same grants to both runs, and compares
their complete transcripts under the redaction rule. Grant variation requires
an additional reviewed projection and effect-eligibility decision before it
ships; RW.5 owns that addendum because live and dry write-shaped effects are
not generally transcript-equivalent.

## Interactions and evidence

- The existing scheduled Warp lane remains useful for checks that must pass
  under several schedules. `VarySchedule` adds result agreement.
- Distribution-valued programs that need approximate comparison continue to
  use `dist-diff`; `SameUnder` is exact.
- A standing `VarySchedule` suite over the structured-concurrency corpus is
  the regression net for schedule-sensitive result drift.
- A secret fixture that prints `secret.expose` output must fail with `E1003`
  and a redacted trace difference. A fixture whose outputs do not depend on
  the payload must pass. These two cases prevent the noninterference
  instrument from becoming vacuous.
- A `VaryWorld` pair with unequal elaborated rows must be refused during
  checking; equal-row live and dry handlers can then be compared as values.

## Compatibility boundaries

- Transcript recording is explicit and off by default. Ordinary
  `jacquard run` stdout, stderr, evaluation count, and exit status remain
  byte-for-byte unchanged.
- `schedule-trace-v1` remains the replay carrier and retains its released
  grammar and bytes. Run transcripts are separate tooling artifacts.
- Result comparison uses the stable public `Value.show` rendering. It is an
  observational contract, not general semantic equality for runtime values.
- The design changes no kernel form, `.jac` lowering, canonical program hash,
  effect identity, store format, or release manifest.
- The recorder is initially interpreter tooling. No native `relate` behavior
  is claimed until an implementation task adds and differentially tests it.

## Non-goals

Static information-flow typing, taint labels, probabilistic relational logic,
and unbounded k-run generalization are outside v0. Passing a relational lane
is scoped evidence for the selected program, variation, seed, and bounded
schedule set.

## Open questions (resolved for v0)

1. **Resolved:** `VaryWorld` requires equal fully elaborated checked rows. See
   [decision 5](#5-varyworld-handler-discipline).
2. **Resolved:** layer 2 always compares both rendered values and the additive
   routed-observation trace. It does not compare schedule-control trace bytes.
   See [decision 1](#1-observation-scope).
3. **Resolved:** the public spellings are `SameUnder`, `Variation`, and
   `relate`. See [decision 4](#4-user-facing-names).
