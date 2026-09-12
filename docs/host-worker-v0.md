# Serial host worker

`jacquard host worker --store DIR` is the HB.2c opt-in process carrier for the
[frozen v0 protocol](../spec/host-protocol-v0.md). It runs one
`stdio-u32-json-v0` worker lifetime: one `core_hello`, one `host_select`, then
either a pre-invocation `shutdown` or exactly one checked invocation whose
root operations are exchanged with the trusted host in lockstep. The OCaml
implementation is `Host_worker`, built on
[`Host_protocol_v0.Session`](host-session-v0.md), the strict codecs, and the
evaluator's sealed once-capture seam. Ordinary `jac run`, `jac check`,
`jac build`, native artifacts, and the interpreted scheduler never use it.

## Startup

The host chooses a local store that already contains the prelude, the target
term, and its complete reachable closure, typically by running
`jacquard run DECLS.jac --store DIR` once. The worker reopens that store,
wires builtin implementations, and seeds a checker with builtin signatures. It
does not reload the prelude, installs no root handlers, grants no world
effect, and reads no environment beyond the store path. A missing store fails
with E0606 and an unpopulated store fails with the prelude's E0702 before any
frame is written; both are startup configuration failures, not protocol
evidence.

Standard input carries host frames, standard output carries Core frames, and
standard error carries bounded operator text. The worker owns none of the
three descriptors and closes none of them.

## Lifecycle

| State | Event | Action | Next state |
|---|---|---|---|
| Start | process starts | write `core_hello` under the hard limits | Hello |
| Hello | valid `host_select` | adopt the selected limits, including the lifetime stderr ceiling | Selected |
| Hello | malformed, unsupported, or over-limit selection | one `fatal` under the hard limits | Exit 0 |
| Selected | valid `shutdown` | one `shutdown_ack` | Exit 0 |
| Selected | `invoke` passing preflight and terminal reservation | evaluate the checked target | Running |
| Selected | any other frame | one `fatal` under the selected limits | Exit 0 |
| Running | configured root operation with valid arguments | write one `effect_request`, retain one sealed once continuation | Waiting |
| Running | unconfigured operation, invalid value, or exhausted capacity | one error `outcome`; no request leaves Core | Exit 0 |
| Running | target returns | validate the value, one `outcome` | Exit 0 |
| Running | runtime failure or evaluation stack exhaustion | one bounded diagnostic `outcome` | Exit 0 |
| Waiting | matching typed `effect_ok` | resume the retained continuation exactly once | Running |
| Waiting | valid `effect_failure` or `cancel` | drop the continuation, one `outcome` with the frozen terminal mapping | Exit 0 |
| Waiting | invalid, stale, malformed, or over-limit frame | drop the continuation, one E1608 (or E1602) `outcome` | Exit 0 |
| any | input ends or a read fails before a complete frame | best-effort E1611 `fatal` or `outcome`, then exit 74 | Exit 74 |
| any | a write or flush fails | stop without retrying | Exit 74 |
| any | no bounded fatal fits the negotiated limits | stop; nothing trustworthy was written | Exit 64 |
| any | a Core invariant fails | stop; nothing further is written | Exit 70 |

The worker reads host control only at these boundaries. It never preempts a
pure computation, never creates a reader thread or event loop, never emits a
second terminal frame, and never retries an invocation, request, or
continuation. A buffered frame that arrives after the terminal is ignored; a
conforming host rejects that send locally as E1608.

## Exit statuses and carrier loss

| Exit | Meaning |
|---:|---|
| 0 | one complete `outcome`, `fatal`, or `shutdown_ack` was flushed |
| 64 | a protocol limit prevented any trustworthy terminal frame |
| 70 | an internal Core invariant failed |
| 74 | standard input or output was lost |

The worker ignores `SIGPIPE` for its lifetime, so a host that closes its
read end produces a structured carrier-loss result rather than a fatal
signal. A frame that could not be written is never resent: before exiting
74 the command points its standard output at the null device so exit-time
channel flushes discard the buffered bytes instead of retrying the carrier.

Carrier loss on standard input is reported as exit 74 even when standard
output remained writable long enough to flush a best-effort frame. Before an
invocation that frame is a `fatal` carrying E1611. While a response is
outstanding it is an error `outcome` with terminal `diagnostic`, E1611, the
request order so far, and every already accepted host observation. That
outcome tells the host which request had no answer; it does not classify the
host's own outstanding outside action, and the host must not treat the
missing response as a Core verdict about that action.

## Operator output

Standard error is never a protocol or evidence channel. The worker writes at
most the hard `max_stderr_bytes` before selection and at most the selected
value over the whole lifetime, counting bytes already written. Text that does
not fit is cut at a UTF-8 scalar boundary, followed by a fixed truncation
marker only when the marker also fits. Operator notes name the phase and the
E16xx classification; they never echo frame payloads, argument values, or host
messages.

## Ownership and limits

- The session owns request ordinals, response validation, terminal
  classification, and bounded evidence. The worker owns the one retained
  continuation, every write and flush, and the exit status.
- Evaluation runs without root handlers, so every root operation the target
  reaches goes through the closed configured registry or ends the invocation
  with E1606. Interpreted Tasks, Channels, `eval`, `dist`, `infer`, and
  `secret` operations have no v0 host encoding and cannot be configured.
- The trusted host and operating system remain trusted (D78). The worker is
  not a sandbox, does not isolate hostile code, enforces no path, host, port,
  or database-row containment, and provides no deadline or memory ceiling of
  its own. Process-level limits are host work.
- One worker serves one invocation. Reusing a process for a second invocation
  is a protocol error; hosts start a fresh worker instead.
- The carrier is provisional v0 evidence (D79). No stable foreign-host ABI,
  adapter, or HTTP server ships here; the HB.3 kit under
  `spec/host-protocol-v0/kit/` is what external adapters pin, and
  `docs/release/host-boundary/` records its evidence, limits, and pending
  decisions.

## Evidence

`test/test_host_worker.ml` drives the worker in-process over scripted input
files against a store populated with the real prelude and then reopened
without it. It covers pure and effectful invocations, sequential ordinals, all
four host-failure and nine cancellation mappings, pre-invocation shutdown,
preflight fatals for E1600 through E1605, unconfigured operations, stale and
malformed responses, buffered post-terminal frames, runtime failures, raw
framing defects, carrier loss before and during an invocation, the selected
stderr ceiling, descriptor and channel ownership, prelude-less stores, a
closed output pipe and a closed output descriptor through the installed
binary, and a property that doubling round-trips every bounded integer. `test/cli/host-worker.t`
pins the same exchanges through the installed `jacquard` binary, including the
exit statuses. The HB.1 vector corpus remains the schema/state contract; its
`noncanonical-target-hash` case names E1603 while the shipped preflight
classifies an uppercase hash as a malformed scalar (E1601); the kit records
this under its pending decisions for a reviewed resolution.
