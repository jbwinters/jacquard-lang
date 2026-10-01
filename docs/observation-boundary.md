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

- `Operation { call; operation; name; arguments }`: an operation reached the root,
  after every language handler declined it and before any root handler runs.
- `Output { call; operation; bytes }`: a trusted root adapter accepted bytes for that
  operation (today only Console print).
- `Result { call; operation; result }`: a granted root handler returned (a value or
  its own runtime failure) and every post-call check passed: the arguments, the
  result's fuel charge, and the result's validation. So `Result` carries exactly
  what the program receives. There is no `Result` for an operation a driver
  captured instead of dispatching, for a dispatch refused before the handler
  ran, or when a post-call check (including fuel exhaustion) fails. One case
  follows the event: if the callback itself exhausts the budget (for example by
  forcing a large payload), the invocation ends with E0919 after `Result`, even
  when the callback caught the exception.

`call` is a correlation id, distinct within an evaluator: a call's `Output` and
`Result` carry its `Operation`'s id, even when calls to one operation nest or a
captured operation is dispatched later by a driver. It is not stable across
runs and is not persisted by any projection.

Arguments and results are never live runtime values. They arrive as an
immutable data projection (`Observation.value`: integers, reals, text, hashes,
tuples, constructors and code). Secrets, closures, continuations, builtins,
operations, and task or channel handles appear only as opaque markers. The
projection is computed only if an observer forces it, and its walk (like
`Observation.render`) draws on computation fuel. The charge goes to whichever
invocation is active when the payload is forced: inside the callback that is
the observed invocation; a consumer that keeps an event and forces it after the
invocation ended pays from its own budget, or from none. A consumer still
chooses what to persist or render through an explicit policy (OBS.1). The v1
projection keeps only operation identities and Console bytes, as before.
Rendering a quoted code value charges one node plus the metered printing of its
form (its nodes and bytes).

## 3. Ownership, lifetime and failure

- An observer (`Eval.with_observer`) is installed for the dynamic extent of the
  installing call only. It is removed on every exit, and invocation teardown
  restores the observer that was in place before the invocation. No observer
  receives events after its extent ends.
- The innermost observer receives the events; an enclosing one is suspended
  while an inner one is installed and resumes afterwards. Installing an
  observer adds no authority, grant or handler.
- An observer cannot re-enter the evaluator or change its authority-bearing
  configuration (grants, natives, code resolution). While a callback runs,
  that evaluator refuses to evaluate, to apply or resume a continuation, and to
  dispatch a routed operation. Registering a root handler
  or a native, changing code resolution, restoring a validated state's mutable
  graph (`fresh_validated_state`), or minting an audit owner
  (`fresh_audit_run_id`) raises `Invalid_argument`. A captured operation's
  Once/Multi mode is fixed before the callback runs. So observation through the
  evaluator cannot add authority, resume a continuation twice, or change
  dispatch.
- The boundary is an API contract, not a sandbox. An observer is host code in
  the evaluator's process. It can still reach objects the host owns, such as
  the `Store` it opened the session with, the process-wide `Fuel_meter`, or
  its own data structures. Changing those from a callback is the host changing
  its own program mid-run, exactly as it could between steps without an
  observer. The guarantees above cover what an event hands over and what the
  evaluator refuses. They do not cover host-owned handles the callback already
  holds.
- Observers see no secret: a secret is an opaque marker in the data
  projection, and no live value (so no capability or mutable cell) reaches a
  callback.
- An exception from a callback propagates after observer state is restored.
  An exception from an `Operation` callback stops that operation before it is
  dispatched; no event is emitted twice. Two exceptions become failures of the
  observed program instead of reaching the caller: fuel exhaustion (the callback
  and the program share the budget, so the program is exhausted too, with
  E0919), and an evaluator refusal raised internally (for example
  `Eval.apply_state` called from a callback), which fails the run with the
  refusal's `Eval_error` unless the callback catches it. Either way the refused
  action never takes effect, and fuel exhaustion stays sticky even when caught.
- An operation that is dispatched is dispatched exactly once whether or not
  observers are installed. The Once/Multi behavior is unchanged: a captured
  operation's mode is read before any callback runs.

## 4. Projections

`Run_transcript` records through `Eval.with_observer` and projects events to
`run-transcript-v1` exactly as before:
- `Operation` becomes a trace event with empty output;
- `Output` attaches bytes to the pending event of its operation;
- `Result` is ignored.

Its serialized bytes are unchanged. Richer projections are new, versioned
formats layered on the same events: `observation-transcript-v1`, recorded under
an OBS.1 observation policy (`docs/observation-policies.md`).

The older `Eval.with_root_observer` is kept as the same v1 view (operation
identities and trusted output bytes) over the typed stream.
