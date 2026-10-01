# Observation Policies And Observation Transcripts (OBS.1)

- Status: implemented (`Observation_policy`, `Observation_transcript`) and
  selectable in `jacquard relate --policy` (§5).
- Builds on: the typed observation boundary (`docs/observation-boundary.md`).
- Unchanged: `run-transcript-v1` (`docs/relational-warp.md` §2), its bytes, and
  every caller of it.

`run-transcript-v1` records each run's result value and the identities of the
operations that reached the root, with Console bytes. It cannot say *which*
arguments or results matter, so two calls to the same operation with
different arguments look identical. An observation policy names exactly what
is recorded and compared, and an observation transcript is recorded under one
policy.

## 1. Policies

A policy selects:

| choice | values |
|---|---|
| the run's result value | `compare` (data-v1 equality, below) or `ignore` |
| observed operations | a list of operation identities (HASH_V0 operation hashes, never display names), each with a rule |
| operations not listed | `ignore` (not recorded at all) or a rule applied to every other operation |
| per rule: arguments | `all`, `none`, or ascending zero-based positions (`0,2`) |
| per rule: result | `compare` or `ignore`: the value or failure the root handler returned |
| per rule: output | `compare` or `ignore`: bytes a trusted adapter accepted (Console print) |
| field byte limit | a positive bound on every recorded field |
| interface pin | `none`, or the interface-v1 identity the observed program must have |

**Exclusion is redaction.** A field the policy does not compare is dropped
before anything is recorded: it never reaches transcript bytes, a rendered
difference, or a file. There is no "hash of the value" projection; a plain hash
of a low-entropy secret would identify it, so none is offered. A policy
therefore cannot select a redacted field for equality: a field is either
compared or absent.

**Data-v1 equality.** Every compared value (a run's result, an argument, a
handler's result) is recorded as its `Observation.render` spelling, except that
each constructor is qualified by its identity (`Ready#<64 hex>`). Two
constructors that share a display name (two types' `Ready`, or a redefined
type) therefore never compare equal. This is stricter than `run-transcript-v1`
value equality, which compares display names.

**Secrets and executable values are unsupported, not rendered.** A field whose
value contains a secret, closure, continuation, builtin, operation value,
constructor function, task or channel anywhere inside it is recorded as
`unsupported kind=<first such kind>`. Its bytes are never recorded, and two
unsupported fields never compare equal (see §4).

### Canonical encoding and identity

```
jacquard-observation-policy format=1
result=compare field-bytes=4096 interface=none
unlisted=record arguments=all result=ignore output=compare
operations=1
operation=<64 hex> arguments=0,2 result=compare output=ignore
```

Operations are sorted by identity with no repeats; `unlisted=ignore` replaces
the whole `record ...` clause. Parsing is strict: unknown versions or clauses,
reordered or misspelled fields, noncanonical numbers or hashes, unsorted
operations, and trailing bytes are refused with E1005, and no input bytes are
copied into a diagnostic. The policy identity is
`HASH_V0("jacquard-observation-policy-v1" NUL bytes)`, so a comparison or cache
key that names a policy names exactly one selection.

The default policy is the one shown above with no operations listed: results
compared, every operation observed with all its arguments and its output, its
result ignored, 4096 bytes per field.

### Drift and stale interfaces

Because operations are named by identity, a changed operation (a renamed
effect, a changed signature) has a new identity. `validate_operations` refuses
(E1005) a policy that lists an identity that is not an operation of the
observed program, so a policy never silently drifts to observing nothing.
`check_interface` refuses (E1005) a policy pinned to a different interface-v1
identity than the program's.

## 2. Observation transcripts

```
jacquard-observation-transcript format=1 policy=<policy identity> runs=N
run index=0 status=complete events=1
value data bytes=2
42
event index=0 operation=<64 hex> arguments=1
argument index=0 data bytes=5
"abc"
result data bytes=1
7
```

- A run is `complete` (with its `value` line when results are compared),
  `failed code=<diagnostic code>` (never E0919), or `incomplete code=E0919`
  when the run's fuel budget stopped it, during evaluation or while its result
  was being rendered. Unlike `run-transcript-v1`, a failed or incomplete run is
  recorded, with the events observed before it stopped.
- An event is recorded for each root operation the policy observes, in order.
  It has the compared argument positions, then `result` and `output` lines
  exactly when the rule compares them.
- A field is `data bytes=N` (the data-v1 rendering, or the raw output
  bytes), `truncated total=T bytes=L` (the first L bytes, L the policy limit,
  of a longer rendering), `unsupported kind=K` (not for raw output),
  `failure code=C` (a handler failure, results only), `missing` (compared but
  not produced: a selected position the call does not have, no output, or a
  result that never arrived because a driver captured the operation without
  dispatching it, a post-call check refused the handler's result, or the run
  stopped inside the handler), or
  `unfinished` (the fuel ran out while the field was being projected; for
  all-arguments a single position 0 stands for every argument). An event whose
  arguments are unfinished never reached its handler, so its compared result
  and output are `missing`. Output is every chunk the call's trusted adapter
  accepted, concatenated in order.

An operation is recorded before its arguments are projected, so a run that
runs out of fuel while projecting them still records which operation it
reached. Running out of fuel usually ends the run, but not always: a fuel scope, a
nested bounded invocation, or recording outside an invocation can let it
continue. So unfinished fields, and handler results that failed with E0919,
may appear on any event of any run. The parser fixes only what the recorder
guarantees: unfinished arguments mean the handler never ran (every selected
position unfinished, no result or output), a failed run is never coded E0919,
an incomplete run always is, and an opaque kind is one the projection
produces.

Parsing needs the policy: the header's policy identity must match it, and each
event must carry exactly the lines its rule demands. Everything else is as
strict as `run-transcript-v1` (E1006). The encoding is deterministic: the same
runs under the same policy produce the same bytes.

Recording forces argument projections inside the observer callback, so their
walk draws on the observed invocation's fuel (`docs/computation-fuel.md`).

## 3. Correlation

Every typed event carries a correlation id (`call`,
`docs/observation-boundary.md`): a call's `Output` and `Result` carry its
`Operation`'s id, including when calls to one operation nest, and when a
driver captures an operation and dispatches it later (the captured
`once_capture` carries the id, and `Eval.dispatch_root_operation` requires
it). The recorder
pairs by that id alone. The id is not recorded: it is not stable across runs.
An operation the policy does not record has nothing to pair with.

## 4. Comparison

Two transcripts under different policies are refused (E1006). Otherwise the
comparison walks runs, then each run's status and value, then its events
(operation identity, arguments, result, output) and returns:

- `Equal`: every compared field agrees.
- `Divergent`: the first field that certainly differs, by path
  (`run[0].event[2].argument[1]`).
- `Inconclusive`: nothing certainly differs, but at the first path shown two
  fields agree only on a truncated prefix and length, only on an unsupported
  kind, or only on being failures without a diagnostic code, or one of them is
  unfinished. Equality is not claimed.

Field agreement: equal data, and equal coded failures, agree; truncated fields
with the same prefix and total, unsupported fields of the same kind, two
`uncoded` failures (or two runs failed `uncoded`), and anything against an
unfinished field are inconclusive; when either event's arguments are
unfinished, its arguments are inconclusive as a whole. Anything else
(including data against truncated, or any kind against another) differs. Two
incomplete runs are compared field by field like any others (a missing result
or a shorter event list is a divergence), but two incomplete runs that agree
on everything recorded are inconclusive, never equal: neither produced what it
would have compared next. A divergence renders as a three-line frame with the
path and both sides; only recorded fields can appear in it.

## 5. Relational comparison under a policy

`jacquard relate FILE --vary KIND --seed S --policy POLICY` reads a canonical
policy file and compares every run with run 1 under it:

- Before anything runs, the program is checked into a private scratch store,
  and the policy is refused (E1005) if it is malformed, lists an identity that
  is not an operation of that prepared program (its prelude or its own
  declarations), or is pinned to an interface other than the program's
  interface-v1 identity.
- Each top-level expression is recorded as a run of an observation transcript.
  A runtime failure is an observation, not a failed constituent: the failed
  run is recorded and the next expression is still checked against the
  constituent's authority and run.
- A certain difference is `E1003`, naming the policy identity and the
  observation path. If no run certainly differs but some pair cannot be called
  equal, the first such pair is `E1007`. Otherwise the verdict line names the
  policy: `relate runs=N seed=S verdict=equal policy=<identity>`.
- Diagnostics pass through the Secret-variation redaction applied to raw field
  bytes, which also removes a trailing fragment of a payload left by
  truncation; only recorded fields can appear in them.

The policy identity is the comparison's name: two comparisons are the same
comparison exactly when their policy identities are equal. Warp relational
lanes (`SameUnder`) do not select a policy yet: they keep the frozen
result-values projection, which the `warp-v2` cache-key version already names.
When a lane gains policy selection, its relational cache key must include the
policy identity alongside the variation fields.

## 6. Compatibility

| surface | change |
|---|---|
| `run-transcript-v1` | none: same bytes, same parser, same callers |
| `jacquard relate` without `--policy` | none: same projections, output and exits |
| Warp relational lanes and cache keys | none: their projection is fixed and named by `warp-v2` |
| kernel, HASH_V0, stores, schedule traces | none |
| diagnostics | E1005 (policy invalid or refused), E1006 (transcript invalid, or recorded under another policy), E1007 (runs cannot be called equal under a policy) |

Not in this version: a named `Eq` for result equality (only data-v1
equality), and a projection of a field other than its full rendering.
