# Language-neutral host boundary

Status: HB.0 design contract, August 2026. This document freezes the roles,
trust boundary, and compatibility rules for host integration. HB.1's concrete
envelopes and vectors are frozen in
[`spec/host-protocol-v0.md`](../spec/host-protocol-v0.md). Neither document
ships a foreign-host ABI, executable carrier, adapter, HTTP server, or host
scheduler.

Read alongside:

- [`ast.md`](ast.md) for the permanent 27-form kernel;
- [`effect-taxonomy.md`](effect-taxonomy.md) for blessed effect identities and
  the rule that “host” is a role rather than an effect;
- [`effect-membranes.md`](effect-membranes.md) and the governed-membrane
  [`LIMITS.md`](release/governed-membranes/LIMITS.md) for trusted-host and
  external-execution limits;
- [`concurrency.md`](concurrency.md) for the deterministic interpreted
  scheduler and explicit C4 exclusions; and
- [`release/0.2/LIMITS.md`](release/0.2/LIMITS.md) for the released baseline.

## 1. Purpose

Another language or process should be able to invoke checked Jacquard logic
and answer the real-world effect requests that reach its root. The same
contract should support a small HTTP integration, later developer tools, and
eventually native or WebAssembly carriers without giving each application a
different interpretation of Jacquard.

The boundary keeps one separation visible:

- **Jacquard owns meaning:** parsing and checking Jacquard code, canonical
  program identity, typed values, effect requirements, language handlers,
  continuation rules, structured diagnostics, and core evidence.
- **The host owns reality:** operating-system access, process identity,
  resource ceilings, persistence, locking, external-state freshness,
  credentials, deployment, and the final execution of world actions.

This is a trust boundary, not a sandbox claim. A host can lie about a result,
ignore a verdict, leak data, or perform an undeclared action. Jacquard can make
the selected program and the requests it emitted reviewable; it cannot prove
that a malicious host obeyed them.

## 2. Terms

**Core** is the Jacquard checker, evaluator, store, prelude, and runtime
implemented in `jacquard-lang`.

**Program artifact** is checked Jacquard code selected by exact canonical
identity. HB.0 does not introduce modules or a package format. HB.1 selects one
checked callable by exact stored term-member hash without treating a mutable
display name as identity; it explicitly declines to invent a module or
export-name identity.

**Host** is the trusted application or process that invokes Core and owns
operating-system resources. There is no `Host` effect. A host services exact
typed operations from concrete effect or facade interfaces.

**Adapter** is the code that implements one carrier, validates its envelopes,
maps configured operations to host actions, and maps results or failures back
to Core. It is part of the trusted host.

**Carrier** is a transport implementation. A framed child process may be the
first carrier; an in-process OCaml/C boundary or WebAssembly imports may be
later carriers. The carrier is not the semantic contract.

**Application** is Jacquard and host code for a product. HTTP parsing, routing,
study behavior, and deployment are application/integration work outside
`jacquard-lang`.

## 3. Ownership

| Concern | Core owns | Host owns |
|---|---|---|
| Program selection | validation, resolution, canonical identity, checked callable shape | artifact provenance, distribution, deployment configuration, and which reviewed identity to request |
| Values | Jacquard types and runtime validity | carrier buffers, memory ownership outside Core, and conversion to/from host values |
| Effects | inferred rows, language handlers, operation identity/mode, continuation discipline, and explicit root installation | which supported root adapters are configured and the actual outside action |
| Authority | absence of ambient Jacquard root handlers and refusal of missing grants | OS credentials, process permissions, network/filesystem isolation, and honest adherence to the configured grant |
| Persistence | typed requests and returned evidence values | database/filesystem lifecycle, locking, transactions, retention, and recovery |
| Failure | structured checker/runtime diagnostics and cancellation delivery | timeouts, process death, partial outside actions, restart policy, and operator reporting |
| Evidence | canonical program/operation identity and deterministic core-owned fields | authenticity, durable publication, external receipts, private-data handling, and host-owned fields |

The boundary must label host-owned facts as host-owned. A host timestamp,
authenticated actor, database receipt, peer address, or deployment identifier
does not become a fact proven by `HASH_V0` merely because it appears beside a
canonical program hash.

## 4. Abstract invocation

The first contract is deliberately lockstep:

```text
host -> Core: begin one invocation of one checked callable
Core -> host: zero or more typed root-operation requests
host -> Core: one typed response or refusal for the current request
Core -> host: one successful value or one structured failure
```

This sequence describes meaning, not bytes. HB.1 freezes the concrete
envelopes, framing, version negotiation, limits, and schema/state conformance
vectors in [`spec/host-protocol-v0.md`](../spec/host-protocol-v0.md).

The following invariants already apply:

1. **Opt in explicitly.** Ordinary `jac run`, native builds, and the
   deterministic scheduler do not silently become hosted execution.
2. **Bind identity before work.** An invocation identifies the exact checked
   program/callable before any host operation. Display names are for review,
   never the sole identity.
3. **Use existing Jacquard values.** A carrier may encode typed values but may
   not create a second value semantics. Opaque run-local values—continuations,
   `Resume`, `Task`, `ChannelHandle`, and unexposed `Secret` values—fail closed
   unless a later contract explicitly defines a safe boundary for one.
4. **Keep requests identity-bound.** A request identifies the exact effect and
   operation interface plus validated arguments. A short string alone does not
   acquire blessed status or authority.
5. **Keep the host registry closed.** An adapter services only operations
   configured for that invocation. There is no generic command, raw SQL,
   arbitrary filesystem, or stringly RPC escape hatch.
6. **Preserve continuation mode.** The host supplies a result; it never chooses
   how many times to resume a Jacquard continuation. Resource-bearing world
   operations remain `once`, and repeated delivery fails closed.
7. **Preserve source order.** The serial carrier observes root operations in
   the exact order Core reaches them. Buffering or adapter implementation
   details cannot reorder visible actions.
8. **Bound every carrier collection.** Frames, nesting, values, diagnostics,
   requests, and buffered output need exact ceilings before HB.1 can ship.
9. **Reject unknowns.** Unknown protocol versions, value variants, fields,
   operations, modes, or response shapes are failures, never best-effort
   compatibility.
10. **Finish once.** One invocation produces one terminal outcome. Messages
    after completion, cancellation, or shutdown are rejected.

This deliberately does not define a general event bus, bidirectional RPC
framework, streaming protocol, callback registry, or remote object system.

## 5. Authority and containment

The checked effect row remains the program's language-level requirement. A
host carrier cannot erase an effect from that row or install authority that
was not explicitly selected for the invocation. Language handlers may
discharge an operation before it reaches the host; only an operation that
crosses every language handler becomes a host request.

The initial adapter configuration is still coarser than OS isolation:

- Core 0.2 grants `Fs` and `Net` at whole-effect granularity.
- A closed operation registry limits which adapter implementations exist, but
  it does not make resource strings type-proven authority.
- The host process may possess credentials or OS permissions broader than the
  Jacquard grant. Correct adapter behavior is trusted.
- Task 202 may later add enforced, resource-scoped attenuation from concrete
  integration requirements. HB.0 does not pre-empt its host/port/path/secret
  grammar or claim that current evidence fields enforce containment.

Following D61-D62, the boundary never adds an opaque `Host` or universal
`Tool.call` effect. Reusable adapters handle exact blessed operations or
domain-specific typed facades and retain their real outward authority.

### Host startup authority

Authority used to start or supervise the host is distinct from an action
requested by Jacquard. For example, a host may bind a loopback listening socket
before invoking a Jacquard request parser. That bind must appear in the host's
deployment/capability evidence, but it must not be falsely attributed to a
Jacquard operation that never requested it.

Conversely, an outbound connection requested while evaluating Jacquard logic
is a program-triggered world action and must remain visible through the exact
operation, row, grant, adapter, and evidence chain. The external integration
must report both classes separately so later attenuation is based on what
actually happened.

## 6. Failure, cancellation, and retry

Host failures do not become arbitrary successful Jacquard values. HB.1 defines
stable E16xx categories for unsupported operation, refused authority, invalid
response, timeout, host shutdown, carrier failure, and an outside action whose
completion is unknown. Their exact envelopes and boundary-value subset are in
the protocol spec.

Cancellation is cooperative:

1. the host requests cancellation or shuts down;
2. Core delivers cancellation at a defined boundary and releases its
   invocation-owned resources;
3. the adapter releases its buffers, descriptors, and registrations; and
4. the outcome says whether no action ran, an action failed, or completion is
   unknown.

Cancellation cannot undo an outside action. Neither Core nor an adapter may
automatically retry a side effect after an ambiguous completion. A future
operation may opt into retry only with operation-specific idempotency keys,
authenticated receipts, and crash/recovery evidence. Retrying a pure invocation
from the beginning is a separate host policy and must not reuse a consumed
once continuation.

The host may terminate and restart a failed worker. It must fail the affected
invocation rather than pretending that in-memory Jacquard continuations
survived. HB.0 makes no durable-continuation or workflow-engine claim.

## 7. Evidence, replay, and privacy

Every hosted run must distinguish:

- core-owned deterministic facts, such as exact program/operation identities
  and the order Core emitted requests;
- host-owned observations, such as time, peer identity, resource selection,
  receipts, and outside failures; and
- redacted or omitted fields whose contents are not safe to retain.

Development and conformance fixtures may capture controlled, sanitized inputs
and responses for exact replay. Production operation does not thereby acquire
permission to archive raw traffic, secrets, participant data, or database
contents. A production profile should retain identities, decisions, hashes,
and bounded metadata unless a separate data-governance decision authorizes
more.

Strict schedule replay and world-response replay are different claims. The
existing deterministic scheduler can validate recorded runnable queues and
choices; it does not reconstruct arbitrary external state. HB.1's labeled
evidence schema states which host observations a fixture supplies, and later
C4 work must state which readiness events a host schedule records. Replay must
never fall back to live I/O after drift.

## 8. Existing implementation seams are not the boundary

Core already contains useful internal pieces:

- `Eval.run_state_capturing_once_routed` exposes the next routed root operation
  to trusted OCaml scheduler code;
- `Round_robin` drives deterministic interpreted Tasks and strict schedule
  traces; and
- `Host_readiness` proves duplicated-descriptor ownership, cancellation,
  shutdown, live readiness ordering, and replay isolation for an internal
  C4-preparatory registry.

These are implementation evidence, not a supported embedding surface. Their
OCaml types may inform HB.1, but an adapter must not publish them as the
language-neutral contract. In particular, `Host_readiness` installs no effect,
does not run a host scheduler, authenticates no trace, and promises no platform
matrix.

## 9. Repository and product boundary

`jacquard-lang` owns this contract, the HB.1 schema/state vectors, its later
carrier implementation inside Core, executable fixtures, and language/runtime
evidence. It may contain a tiny fake host used only to prove conformance.

The private `jacquard-host` repository owns real adapters, sockets,
persistence, the minimal serial HTTP integration, and the requirements report
fed back to Core. HTTP parsing and routing written in Jacquard remain external
library/application code; they do not belong in the language repository.

The real readability application moves to its own repository before it gains
participant data, public deployment, authentication, retention, or research
publication duties.

Reverse proxies, TLS termination, edge filtering, and cloud products are
ordinary deployment concerns. Core and its host contract neither know nor care
which of those products, if any, stand in front of an application. A future
generic authenticated-input facility requires its own concrete need; vendor
headers are not smuggled into HB.0.

## 10. Initial limitations and removal gates

| Limit | What it prevents us from claiming | Gate for removal |
|---|---|---|
| First-party programs | safety for hostile uploaded Jacquard code | separate-process or equivalent isolation design, hostile resource tests, and reviewed threat model |
| Trusted adapter and OS | protection from a lying host or broader OS credentials | independently enforced isolation/authentication plus external security review |
| No carrier implementation yet | interoperability or embedding support | HB.2 implementation followed by HB.3 executable cross-language fixtures and evidence |
| Experimental process carrier first | permanent ABI stability or low-overhead embedding | two independent adapters and one real integration pass the frozen fixtures before v1 |
| One serial invocation | concurrent requests, streaming, or throughput | demonstrated need followed by the C4 scheduler contract and resource evidence |
| No automatic side-effect retry | transparent recovery from ambiguous completion | per-operation idempotency, receipt, and crash/recovery contract |
| Controlled replay fixtures | production traffic replay | explicit privacy, retention, redaction, and evidence-store authority |
| Coarse Core 0.2 grants | domain/path/port-level enforcement | concrete host report followed by Task 202's reviewed attenuation algebra and handlers |
| Linux-first integration evidence | portable host-runtime claim | CI, lifecycle, cleanup, and packaging evidence for every added platform |
| No HTTP/product code in Core | a bundled web framework or hosted service | intentionally not a removal target; those products remain external consumers |

Every later evidence pack must repeat its still-active limits and link to the
exact reviewed change that removes one. Silence never widens the claim.

## 11. Follow-up gates

HB.0 closes when this role/trust contract is reviewed. It authorizes no runtime
code by itself.

HB.1 is frozen by [`spec/host-protocol-v0.md`](../spec/host-protocol-v0.md):
concrete values, envelopes, framing, version negotiation, resource ceilings,
failure schemas, and canonical positive/hostile schema/state vectors.

HB.2 implements the opt-in serial carrier and interpreter seam without HTTP,
SQLite, concurrency, or a new kernel form.

HB.3 publishes the language-neutral conformance kit and Core evidence. Only
then does the external adapter start against a released pin.

The external serial HTTP integration reports concrete authority needs back to
Core. That report gates resource attenuation. Measured concurrency need gates
a separate C4 contract, which in turn gates the existing host async-I/O task.

## 12. Decisions

| ID | Decision | Frozen result |
|---|---|---|
| D77 | boundary ownership | Core owns language meaning and evidence; the trusted host owns OS reality and final actions |
| D78 | threat model | first-party Jacquard programs, trusted adapter/OS, application enforcement only; no hostile-code or sandbox claim |
| D79 | carrier relationship | the semantic contract is transport-neutral; a bounded framed process is provisional v0 evidence, not the permanent ABI |
| D80 | invocation identity | bind one checked artifact/callable by canonical identity before work; mutable display names never suffice |
| D81 | host operations | exact typed effect/facade operations through a closed configured registry; no `Host`, universal tool call, or general RPC escape |
| D82 | first execution shape | one bounded serial lockstep invocation; concurrency, streaming, and callbacks remain later contracts |
| D83 | failure and retry | cancellation is cooperative, external actions are not undone, and ambiguous side effects are never retried automatically |
| D84 | evidence and privacy | distinguish Core facts from host observations; exact replay uses controlled sanitized fixtures unless separately authorized |
| D85 | repository/product split | Core contract and fixtures stay here; adapters/server integration and the real readability product live in external repositories |
| D86 | compatibility | preserve the 27-form kernel and existing value/effect semantics; unknown protocol material fails closed and evolution is explicitly versioned |
| D87 | startup authority | host startup/deployment authority is recorded separately from actions actually requested by Jacquard |
