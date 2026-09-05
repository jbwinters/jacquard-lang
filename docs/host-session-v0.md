# Serial host session accounting

`Host_protocol_v0.Session` implements the invocation state machine in the
[frozen v0 protocol](../spec/host-protocol-v0.md). It builds on checked invoke
preflight and the bounded type/value codecs. It is an OCaml library layer;
the opt-in process worker and evaluator loop remain to be implemented.

A session starts only after the exact stored callable, complete reachable
closure, pinned interface, arguments, grants, and operation registry pass
preflight. It also reserves room for an error outcome with that invocation's
evidence. The checker and store must remain stable for the session's lifetime.

## State and ownership

| State | Event | Returned action and next state |
|---|---|---|
| Running | Configured operation with valid arguments | One request; wait for its response |
| Running | Missing operation, invalid value, or exhausted capacity | Error outcome; closed |
| Waiting | Matching, correctly typed `effect_ok` | One value to resume with; running |
| Waiting | Valid failure or cancellation | Error outcome with the frozen classification; closed |
| Waiting | Invalid response | E1608 outcome, or E1602 for a selected limit; closed |
| Running | Computation returns | Validate actual result and return success or diagnostic; closed |
| Running or waiting | Runtime abort | Bounded diagnostic outcome; closed |
| Closed | Any further state-changing call | Result-valued E1608; no additional frame |

A second request while waiting, an unsolicited response, or a result while
waiting is E1608. Request IDs are deterministic, one-based 16-digit hex
ordinals. A response must match the selected protocol, invocation, and current
request. Stale replies cannot consume a newer response slot.

The session owns no evaluator continuation, channel, or operating-system
resource. The worker must retain one captured continuation while waiting,
resume it only on `Resume`, and drop it on `Finished`. An action is committed
when returned: the worker writes and flushes it once. A write failure ends the
worker; retrying a request or claiming that an unwritten terminal was delivered
would violate the protocol. Only the later worker integration can establish
these resource-lifetime and delivery guarantees.

## Capacity and evidence

Before returning a request, the session reserves terminal capacity for the
new request, the largest permitted next observation, and the longest terminal
label. If that evidence cannot fit, the operation is refused before a request
is returned. Accepted observations survive subsequent failure.

Each envelope passes the selected byte, depth, and collection checks.
Repeated interface descriptors and a successful result share the outcome's
node budget. Diagnostic accounting includes every rendered UTF-8 string value,
including contrasts and span paths, and excludes fixed JSON keys.

Diagnostics that cannot fit are replaced with a fixed E1602 diagnostic. This
retains the terminal classification and accepted observations: an accepted
unknown-completion response stays `completion_unknown` even when its detailed
host diagnostic exceeds the budget. Host message bytes appear as an exact
cause suffix when they fit; they are never truncated into a different claim.
The trusted host remains responsible for redacting those messages.

Core evidence contains the validated identity/interface/grants and request
order. Host observations contain only accepted category/completion/ordinal
claims. Arguments, results, and host message text stay out of both evidence
sections. Rejected responses are never recorded as accepted observations.

`test/test_host_session.ml` covers both directions of typed nominal values,
all four host-failure and nine cancellation mappings, state violations,
strict response validation, growing evidence, and exact capacity boundaries.
The worker's pipe, EOF, cancellation cleanup, descriptor, and ordinary-command
compatibility evidence belongs to the remaining integration work.
