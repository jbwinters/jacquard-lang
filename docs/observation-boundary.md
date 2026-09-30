# Typed observation boundary (RF.3)

- Status: implemented contract.
- Scope: facts the evaluator observes at its root, and the versioned
  projections built from them. The existing trace and evidence formats keep
  their exact bytes.

## 1. Inventory

| carrier | produced by | what it records | trust domain | after RF.3 |
|---|---|---|---|---|
| root observer (`Eval.with_root_observer`) | evaluator root dispatch | operation identity, trusted Console bytes | program observation | a v1 projection of the typed stream |
| `run-transcript-v1` (`Run_transcript`) | `relate` complete-transcript lane | result value rendering, routed operations, Console bytes | program observation | consumes the typed stream through the v1 projection, byte-identical |
| schedule traces (`Schedule_trace`, `Schedule_control`) | deterministic scheduler | runnable queues, choices, creations, per-decision operation kind | scheduler decisions | unchanged and separate: schedule choices are not program observations |
| Warp relational comparisons | `Warp` over `Run_transcript.of_values` / `compare*` | rendered result values | program observation | unchanged: they use transcript values, not live observation |
| host request envelopes (`Host_protocol_v0`, `Host_worker`) | host session | effect requests, responses, host observations | host-owned facts | unchanged and separate: host facts are not Core observations |
| governance audit carriers (`Audit_chain`, governance modules) | governance runtime | hash-chained audit entries | governance events | unchanged and separate: the audit chain is its own trust domain |

The typed boundary covers only the first two rows. It does not merge the other
trust domains, and it is not a universal trace format.

## 2. Typed events

`Observation.event` is produced at the evaluator root, in evaluation order:

- `Operation { operation; name; arguments }`: an operation reached the root,
  after every language handler declined it and before any root handler runs.
- `Output { operation; bytes }`: a trusted root adapter accepted bytes for that
  operation (today only Console print).
- `Result { operation; result }`: a root handler returned (a value or a runtime
  failure). Operations captured by a driver instead of dispatched have no
  `Result`.

Arguments and results are runtime values. A consumer must project them through
an explicit policy before persisting or rendering them (OBS.1). The v1
projection keeps only operation identities and Console bytes, as before.

## 3. Ownership, lifetime and failure

- An observer (`Eval.with_observer`) is installed for the dynamic extent of the
  installing call only. It is removed on every exit, and invocation teardown
  restores the observer that was in place before the invocation. No observer
  receives events after its extent ends.
- The innermost observer receives the events; an enclosing one is suspended
  while an inner one is installed and resumes afterwards. Installing an
  observer adds no authority, grant or handler.
- An observer cannot re-enter the evaluator. While a callback runs, any
  evaluation on that evaluator is refused (a callback cannot run code, apply a
  captured resumption, or dispatch an operation), so observation cannot resume
  a continuation twice or change dispatch.
- An exception from a callback propagates unchanged, after observer state is
  restored. An exception from an `Operation` callback stops that operation
  before it is dispatched; no event is emitted twice.
- Each operation is dispatched exactly once whether or not observers are
  installed. The Once/Multi behavior is unchanged.

## 4. Projections

`Run_transcript` records through `Eval.with_observer` and projects events to
`run-transcript-v1` exactly as before:
- `Operation` becomes a trace event with empty output;
- `Output` attaches bytes to the pending event of its operation;
- `Result` is ignored.

Its serialized bytes are unchanged. Richer projections (OBS.1) are new,
versioned formats layered on the same events.

The older `Eval.with_root_observer` is kept as the same v1 view (operation
identities and trusted output bytes) over the typed stream.
