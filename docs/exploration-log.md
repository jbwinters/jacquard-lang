# Exploration Recording (EXP.1): `exploration-log-v1`

- Status: implemented (`src/exploration_log.ml`, `jacquard run --record`,
  `test/cli/exploration-log.t`, `test/test_exploration_log.ml`).
- Design: `docs/designs/execution-exploration.md` (DES.0) §4.1. Owner decisions
  of 2026-10-19: DES.0 §10 decisions 1–4 as recommended (named choices as a
  prelude function, forks replay from the start, `observe` is never forked,
  recording is interpreter-only in v1), and a line-based, length-framed log
  format matching `observation-transcript-v1` and the behavior-review report.
- Later work reads these logs: named choices (EXP.2), the fork engine (EXP.3),
  exploration reports (EXP.4).

## 1. Recording a run

```console
jacquard run FILE [--allow ...] [--seed S] --record LOG
    [--record-policy POLICY] [--record-output] [--max-steps N] [--max-bytes N]
```

`--record LOG` runs the program exactly as `jacquard run` does (same output,
values and exit status) and also writes `LOG`. Like OBS.1, the recorder
projects arguments and results on the run's own computation fuel, so a run
with a tight `--fuel` budget can exhaust it sooner when recorded; a projection
that runs out of fuel is kept as `unfinished`, and the operation is still
recorded.

- **What is recorded.** One step per operation that reaches the root (crosses
  every language handler), in order: its identity, display name, the source span
  of the application that performed it, its arguments and its result. A prelude
  `sample` is a `choice` step and `observe` an `observe` step; every other
  operation is an `operation` step. Operations a program handles itself are not
  steps.
- **Policy.** An OBS.1 observation policy (`docs/observation-policies.md`)
  decides which operations are recorded, which arguments, whether results and
  output are kept, the per-field byte limit, and the data-v1 rendering with its
  redaction. `--record-policy POLICY` selects one; the default records every
  operation with all its arguments and its result (4096 bytes per field).
  Console output bytes are recorded only with `--record-output`, and only for
  operations whose rule keeps output; like every field, output keeps at most
  the policy's field limit (`truncated total=T` beyond it). A policy given with
  `--record-policy` must apply to the program exactly as for `relate --policy`:
  every operation it lists exists, and an interface pin matches (E1005 before
  the run). That check reads the source on its own, so a source that only
  checks against definitions a `--store` already holds is refused with E1005
  when a `--record-policy` is given; record it with the default policy.
- **Choices inside inference.** A `sample` that an inference driver captures
  (likelihood weighting, enumeration) is recorded as a `choice` step with its
  distribution, and its result is `missing`, as in OBS.1: the driver, not the
  root, resumes it (enumeration resumes it once per support value), so there is
  no single outcome to record. A choice made under a root `dist` grant records
  its outcome.
- **Values, not codecs.** Recorded arguments and results are the policy's
  data-v1 projections, possibly truncated, not codec round-trips of
  `net.record`. They show what happened; a fork that replays a recorded value
  (EXP.3) needs a policy whose fields are not truncated, and refuses a step
  whose value is truncated or unsupported.
- **Seed.** The log names the run's seed: a run without `--seed` draws one and
  records it.
- **File.** The log path is reserved before the run (created empty, owner-only
  0600, exclusively: an existing path is refused with E1016 and never replaced)
  and written once after the run through the same descriptor, so nothing at the
  path can be substituted in between.

## 2. Positions

The evaluator carries the source span of each application (`Meta.span` of the
kernel `App` node) on its application frames and hands it to the root
operation event (RF.3 `Observation.Operation.site`). Spans are metadata: they
are never part of a value, a hash, output or an exit status. A recording run
serves declarations it installed from source in place of their reloaded store
objects (`Store.retain_source_declarations`, session-only, never persisted), so
sites name the user's file, line and column. A definition group the store
already holds with its members in another order is served in the stored order
(members and group references renumbered, checked to hash to the stored
object), so its sites still name the current source. A site the evaluator cannot know
(an operation applied by a builtin or host callback) is `site unknown`. An
operation performed inside a prelude function, or inside a declaration this
session reached only by hash from an earlier store, names that declaration's
own source or store object, not the user's call site. Hash-equal declarations
(two identical definitions, which canonical identity does not distinguish)
share one body, so a step's site names one of them (whichever the evaluator
loaded first); sites cannot tell such twins apart.

## 3. Exposure

- A `Secret` value is never rendered: OBS.1 records it as `unsupported
  kind=secret`.
- The plaintext that `secret.expose` returns is not recorded either: that
  result is `unsupported kind=secret`, and the plaintext is learned from every
  `secret.expose` result whatever the policy keeps. Every later recorded field
  and output has the plaintext, in its raw and its escaped data-v1 spelling,
  replaced by `<secret redacted>`; a field is redacted on its full rendering
  before it is bounded, so no truncation can leave a fragment.
- The test transcript records random payloads, including quotes, backslashes,
  newlines and non-ASCII text, under the default policy and under one that
  ignores `secret.expose` results, and checks that none reaches a log.
- If a `secret.expose` result cannot be projected (the run's fuel ran out),
  its plaintext is unknown, so every later field is recorded as
  `unsupported kind=secret` and later output is not recorded.
- **Limitation.** Redaction matches the whole exposed plaintext. Text derived
  from it (a substring, a transformation, or pieces printed separately) is not
  recognized. A program that derives text from a secret should keep those
  operations out of the recording policy.

## 4. Bounds

`--max-steps N` (default 10,000) and `--max-bytes N` (default 16 MiB) bound the
recording. Reaching either stops the run with E1016 (exit status 2) and writes
the log recorded so far, ending `end steps=K bounded=steps|bytes`: nothing that
would pass either bound is retained (a step past `--max-steps`, or a step,
result or output chunk past `--max-bytes`). A recording is never truncated silently.
The byte bound counts every recorded payload (names, sites, fields and output)
plus a fixed allowance per line; the header is not counted. A field is redacted
before it is bounded, so it never exceeds the policy's field limit.

## 5. Format

```
jacquard-exploration-log format=1
program source=<hex> core=<version> prelude=<hex> engine=interpreter
seed <n>
grants bytes=<n>
<the --allow names as given, comma-joined>
policy <hex> record-output=yes|no
step index=<i> kind=operation|choice|observe operation=<hex> arguments=<n>
name bytes=<n>
<display name>
site bytes=<n>
<file>:<line>:<col>-<line>:<col>
argument index=<j> <field>
result <field>
output <field>
end steps=<k> exit=<status> | end steps=<k> bounded=steps|bytes
```

- `site unknown` replaces the framed site when there is none. `result` and
  `output` appear only when recorded. Steps are numbered from 0 in order.
- A field is `data bytes=N` (then N bytes and a newline), `truncated total=T
  bytes=L` (the first L bytes), `unsupported kind=K`, `failure code=C`,
  `missing` or `unfinished`, exactly as in `observation-transcript-v1`.
- `program source` is HASH_V0 of the file bytes; `prelude` is HASH_V0 of the
  store's prelude manifest.
- `Exploration_log.parse` accepts exactly the canonical bytes
  `Exploration_log.serialize` writes and refuses anything else (another format,
  trailing bytes, a wrong step count, non-canonical numbers or hashes).

The header differs from the sketch in DES.0 §4.1 by the owner's format
decision: `program source` is HASH_V0 of the file bytes (a recording is of a
source run, not a separately checked artifact), `grants` lists the root grant
names exactly as given (a framed payload), and the run's outcome is its exit status (each top-level result appears
as the output the run printed, not as a separate field).

## 6. Compatibility

- No change to the kernel, `.jqd`, HASH_V0, store objects, the observation
  transcript formats or policies, `relate`, `replay`, Warp, or the output and
  exit status of any command without `--record`.
- `Observation.Operation` gains a `site` field, and the evaluator's application
  frames carry the span that fills it. These are runtime metadata only.
- The native backend does not record (interpreter-only in v1).
- New diagnostic: E1016 (the log path exists, bounds are invalid, the log
  cannot be written, or a bound was reached).
