# Jacquard host protocol v0

Status: frozen HB.1 contract, August 2026.

This specification turns the abstract boundary in
[`docs/host-boundary.md`](../docs/host-boundary.md) into concrete envelopes and
test vectors. It defines one transport-neutral invocation model and one
provisional process carrier. It does not ship the carrier, an adapter, a
module system, HTTP, persistence, asynchronous I/O, or a security sandbox.

The version name is `jacquard-host-v0`. The provisional carrier name is
`stdio-u32-json-v0`.

## 1. Contract at a glance

One trusted host starts one Core worker and performs at most one invocation:

```text
Core -> host  core_hello
host -> Core  host_select
host -> Core  invoke
Core -> host  effect_request       zero or more times
host -> Core  effect_ok | effect_failure | cancel
Core -> host  outcome              exactly once
```

After negotiation, the host may send `shutdown` instead of `invoke`; Core
answers `shutdown_ack` and exits. There is never more than one live invocation
or one outstanding effect request. A second invocation, a response for the
wrong request, or any message after a terminal frame is a protocol error.

The first version deliberately chooses these constraints:

- the target is one checked, content-addressed term, not a mutable module or
  export name;
- the callable interface is closed, monomorphic, positional, and
  first-order;
- the capability set is the callable's exact closed effect row;
- the host registry contains exact `once` operation identities;
- Core chooses when and how a continuation resumes;
- protocol IDs are deterministic ordinals scoped to this one worker; and
- Core evidence and relayed host observations remain visibly separate.

Ordinary `jac run`, native artifacts, and the interpreted scheduler do not use
this protocol unless a later HB.2 entry point opts in explicitly.

## 2. Trust and non-claims

The host and operating system are trusted. Core validates the selected
artifact, interface, values, capabilities, operation identities, ordering, and
limits. It cannot prove that the host performed the stated outside action,
used only the stated OS authority, reported an honest result, or retained no
private data.

This is an application capability boundary, not hostile-code containment.
The protocol has no authentication, encryption, remote transport, TLS,
reverse-proxy semantics, vendor headers, public-listener policy, or
production-deployment claim. The process carrier is local integration
evidence. Its bytes are not `HASH_V0`, an artifact identity, or a permanent
ABI.

## 3. Framing and process behavior

`stdio-u32-json-v0` uses the child process's standard streams:

- host-to-Core frames travel on stdin;
- Core-to-host frames travel on stdout; and
- stderr is bounded human/operator output and is never a protocol or evidence
  channel.

The worker starts against one host-selected local Core store. Store location,
artifact copying, process environment, and launch credentials are startup
configuration, not envelope fields or Core evidence. The target hash and its
complete reachable closure must resolve in that store before evaluation.

Each frame is four bytes of unsigned big-endian payload length followed by
exactly that many payload bytes. The length must be between 1 and the active
`max_frame_bytes`, inclusive. The payload is one UTF-8 JSON object. There is no
compression, byte-order marker, trailing newline, or data after the JSON
value. A writer emits and flushes one complete frame before another writer may
act.

Before `host_select`, both directions use the hard limits in section 6. After
selection, both directions use the selected limits. EOF inside a length or
payload, invalid UTF-8, a non-object JSON value, duplicate object keys, an
unknown or missing field, a disallowed JSON value, or trailing payload data
fails closed.

JSON object key order and insignificant whitespace do not carry meaning.
Implementations must not hash raw frame bytes as semantic evidence. Protocol
strings are decoded Unicode scalar values; lone surrogate escapes and invalid
UTF-8 are rejected. Jacquard `Text` bytes are not normalized.

Core writes nothing to stdout except frames. A valid `outcome`, `fatal`, or
`shutdown_ack` that is completely flushed is a structured terminal result and
permits process exit 0. Exit 64 means that a protocol failure prevented a
trustworthy terminal frame, exit 70 means an internal Core invariant failed,
and exit 74 means carrier I/O was lost. Exit status alone never upgrades a
missing terminal frame into Core evidence.

Core writes at most the selected `max_stderr_bytes` over the worker lifetime.
It truncates further operator text at a valid UTF-8 boundary. Truncation never
changes, supplements, or substitutes for a structured protocol result.

## 4. Common validation rules

Every object has an exact field set. “Optional” means that the field's presence
rule is stated explicitly; otherwise omission and addition are errors. Every
post-selection message carries `"protocol":"jacquard-host-v0"`.

Hashes are exactly 64 lowercase hexadecimal characters. They identify
existing `HASH_V0` objects; this protocol does not define another Jacquard
hash. Lists described as sets are strictly sorted by raw hash bytes and contain
no duplicates. Because the text is lowercase hexadecimal, byte order and text
order agree.

The invocation ID is exactly `0000000000000000`. The first effect request ID
is `0000000000000001`; later IDs increase by one and use 16 lowercase
hexadecimal digits. These IDs are deterministic, worker-local correlation
ordinals, not globally unique evidence identities. A deployment may attach a
separate host-owned run ID outside Core evidence.

JSON integers appear only in bounded protocol counters, limits, and the
existing diagnostic-v1 span object. Jacquard `Int` and `Real` values use the
lossless encodings below.

Validation is fail-fast in this order: framing and carrier loss; UTF-8, JSON,
nesting, and exact envelope shape; protocol version; message state and IDs;
target/interface/value preflight; capability preflight; then evaluation and
typed effect responses. A lower-level failure is not relabeled by material
that could not yet be trusted. The hostile vectors each isolate one primary
failure under this order.

## 5. Boundary types and values

### 5.1 Type descriptions

The callable itself must check as one closed monomorphic `TArrow`. Its
parameters and result use only these recursive descriptions:

```json
{"arguments":[],"identity":"1111111111111111111111111111111111111111111111111111111111111111","kind":"nominal"}
```

```json
{"items":[],"kind":"tuple"}
```

A `nominal` description is one exact declared type identity plus zero or more
type arguments. A `tuple` is the existing Jacquard tuple type; zero items is
unit. The same depth, node, and collection limits as values apply.

Type variables, open rows, arrows nested in data, `Resume`, variadic arrows,
checker-internal exact thunks, and unresolved identities are not boundary-safe
in v0. Core derives the callable's actual type and requires structural equality
with the supplied interface before evaluation. Display names and
`call-abi-v1` labels are not part of this positional interface.

### 5.2 Value descriptions

The following exact object variants map to existing runtime values:

```json
{"kind":"int","value":"-12"}
{"bits":"8000000000000000","kind":"real"}
{"kind":"text","value":"hello"}
{"kind":"hash","value":"2222222222222222222222222222222222222222222222222222222222222222"}
{"items":[],"kind":"tuple"}
{"arguments":[],"identity":"3333333333333333333333333333333333333333333333333333333333333333","kind":"constructor"}
```

An `int` value is canonical decimal text in the released OCaml 63-bit range
`-4611686018427387904` through `4611686018427387903`. Zero is `0`; leading
zeros, a plus sign, and negative zero are rejected.

A `real` value is exactly 16 lowercase hexadecimal digits containing the raw
IEEE-754 binary64 bits. This preserves infinities, NaNs, and negative zero. It
is intentionally not the normalized real encoding used as `HASH_V0` input.

A `text` value is valid UTF-8 after JSON decoding and receives no Unicode
normalization. A `hash` becomes the existing validated opaque `VHash`. A
`tuple` is ordered. A `constructor` is a saturated `VCon`; Core resolves the
exact constructor identity, checks arity and field types, and ignores no
display name because none crosses the boundary.

`Code`, `Secret`, `Task`, `ChannelHandle`, `Resume`, closures, builtins,
operation values, and unapplied constructors have no v0 encoding. They fail
with E1604 rather than being rendered to text, assigned a remote handle, or
silently redacted into a different value. Later versions may add a value only
with an exact ownership, lifetime, type, and conformance contract.

Every incoming argument and successful operation response is checked against
its expected Jacquard type before use. Every outgoing result and operation
argument is checked before encoding. A syntactically valid value with the
wrong type is an invalid response or outcome, not a coercion opportunity.

## 6. Fixed and selected limits

Core's first frame advertises these hard maxima:

| Field | Hard maximum | Meaning |
|---|---:|---|
| `max_frame_bytes` | 1,048,576 | four-byte length excludes the prefix |
| `max_json_depth` | 64 | object/array nesting after JSON decoding |
| `max_value_nodes` | 4,096 | aggregate type/value nodes in one frame |
| `max_text_bytes` | 262,144 | UTF-8 bytes in one Jacquard `Text` |
| `max_collection_items` | 1,024 | items in one array-valued field |
| `max_arguments` | 64 | callable or operation arguments |
| `max_effects` | 64 | exact effect grants |
| `max_operations` | 256 | configured host operation entries |
| `max_effect_requests` | 1,024 | requests in the invocation |
| `max_diagnostics` | 32 | diagnostics in one terminal result |
| `max_diagnostic_bytes` | 65,536 | aggregate UTF-8 diagnostic string bytes |
| `max_host_message_bytes` | 4,096 | one redacted host failure message |
| `max_stderr_bytes` | 65,536 | aggregate operator bytes over one worker |

`host_select` repeats every field with a positive integer no greater than the
advertised maximum. The selected object is the component-wise operational
ceiling; it is not a request to allocate every maximum. A deployment may
choose smaller values, but the selection is frozen before the target or any
argument is accepted.

Core accepts a selection only when its limits can represent the mandatory
smallest `fatal` and `shutdown_ack`; otherwise it returns E1602 under the hard
pre-selection limits. Before accepting an `invoke`, Core likewise verifies
that the selected limits can represent one bounded error `outcome` containing
that invocation's validated evidence. This prevents an accepted invocation
whose failure could never be reported structurally.

Limits apply before allocation when possible. A frame cannot evade a node,
text, collection, or depth limit merely because it is below the byte limit.
Limit diagnostics themselves use small fixed prose and must not echo the
refused payload.

Counting is exact. The root JSON object has depth 1; each nested object or
array adds 1, while a scalar adds no container depth. Each occurrence of a
boundary type or value variant object is one value node, including repeated
occurrences in an outcome's evidence. Collection and argument limits apply to
each corresponding array; effect-request count is cumulative for the
invocation. Diagnostic bytes are the sum of decoded UTF-8 bytes in all string
values of the diagnostic objects, including span paths and contrasts but not
fixed JSON keys. The stderr limit counts bytes actually written, including any
truncation marker when one fits.

## 7. Handshake and target selection

### 7.1 `core_hello`

Core's first frame has exactly `carrier`, `kind`, `limits`, and `versions`:

```json
{
  "carrier": "stdio-u32-json-v0",
  "kind": "core_hello",
  "limits": { "...": "all hard-limit fields from section 6" },
  "versions": ["jacquard-host-v0"]
}
```

The versions list is nonempty and ordered from most to least preferred. v0
contains only the value shown.

### 7.2 `host_select`

The host answers with exactly `kind`, `limits`, and `protocol`:

```json
{
  "kind": "host_select",
  "limits": { "...": "all selected-limit fields from section 6" },
  "protocol": "jacquard-host-v0"
}
```

An unsupported version is E1600. A missing, extra, nonpositive, or excessive
limit is E1601 or E1602 as appropriate. No version fallback occurs after this
frame.

### 7.3 `invoke`

The host then sends exactly these fields:

```json
{
  "arguments": [],
  "capabilities": {
    "effects": [],
    "operations": []
  },
  "interface": {
    "effects": [],
    "parameters": [],
    "result": {"items": [], "kind": "tuple"}
  },
  "invocation_id": "0000000000000000",
  "kind": "invoke",
  "protocol": "jacquard-host-v0",
  "target": {
    "callable": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "kind": "store-term-v0"
  }
}
```

`target.callable` is an exact stored term-member hash. Its resolved references
transitively bind the code it can directly reach. Core requires the complete
reachable store closure to be present and valid. v0 has no module, package,
export, source-path, or display-name identity; any such field is rejected.
Artifact distribution and provenance remain host-owned.

`interface` is the host's pinned expectation. `parameters` and `result` must
equal Core's derived boundary-safe arrow, and `effects` must equal its exact
closed row. Arguments are positional, have the same count as parameters, and
must validate against them.

`capabilities.effects` must exactly equal `interface.effects`. The equality
prevents both missing grants and undeclared whole-effect authority. Each
operation entry has exactly `effect`, `mode`, and `operation`; entries sort by `(effect,
operation)`, are unique, resolve in the selected store, name an operation of
that exact effect, and use `"mode":"once"`. An entry cannot introduce an
effect absent from the grant. Every configured operation must have closed,
monomorphic parameter and result types expressible by section 5; generic or
boundary-unsafe operation signatures fail E1604 during preflight. The registry
may cover only part of a granted effect; reaching another operation fails
E1606 before a request is sent.

The closed registry narrows adapter availability but does not turn Core 0.2's
whole-effect grant into path, host, port, or database-row containment. Correct
adapter enforcement and OS authority remain trusted.

## 8. Effect exchange

When a configured root operation is reached, Core emits exactly:

```json
{
  "arguments": [],
  "effect": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
  "invocation_id": "0000000000000000",
  "kind": "effect_request",
  "mode": "once",
  "operation": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
  "protocol": "jacquard-host-v0",
  "request_id": "0000000000000001"
}
```

Core derives the identity, mode, argument count, argument types, and result
type from the checked store. The host dispatches only by its pinned registry;
names or strings inside arguments never select an adapter by themselves. Core
emits requests in evaluation order and never emits another until the current
request has one accepted response.

For success, the host sends exactly:

```json
{
  "invocation_id": "0000000000000000",
  "kind": "effect_ok",
  "protocol": "jacquard-host-v0",
  "request_id": "0000000000000001",
  "value": {"items": [], "kind": "tuple"}
}
```

For a valid outside failure, the host sends exactly:

```json
{
  "category": "refused_authority",
  "completion": "not_started",
  "invocation_id": "0000000000000000",
  "kind": "effect_failure",
  "message": "redacted host-owned detail",
  "protocol": "jacquard-host-v0",
  "request_id": "0000000000000001"
}
```

The allowed `(category, completion)` pairs are exact:

| Category | Completion | Meaning |
|---|---|---|
| `unsupported_operation` | `not_started` | host registry drift; E1606 |
| `refused_authority` | `not_started` | host refused before action; E1607 |
| `outside_failure` | `failed` | action ran and failed definitely; E1613 |
| `completion_unknown` | `unknown` | action may have happened; E1612 |

`message` is host-authored, already redacted, valid UTF-8 detail no larger than
the selected `max_host_message_bytes` after JSON decoding. Core places those
exact decoded bytes in a bounded diagnostic-cause suffix; it performs no
secret detection and trusts the host to redact them. The message is not
canonical evidence and must not contain secrets, raw participant data, or an
entire outside response. Typed receipts belong in an operation's declared
result, not an untyped protocol side channel.

An invalid ID, duplicate or late response, invalid pair, malformed value, or
value of the wrong result type terminates with E1608. Core does not send the
request again or let the host choose whether to reuse the continuation.

## 9. Cancellation, timeout, and shutdown

During the one response slot, the host may send `cancel` instead of an effect
response:

```json
{
  "completion": "unknown",
  "invocation_id": "0000000000000000",
  "kind": "cancel",
  "protocol": "jacquard-host-v0",
  "reason": "timeout",
  "request_id": "0000000000000001"
}
```

`reason` is exactly `cancelled`, `timeout`, or `host_shutdown`.
`completion` is exactly `not_started`, `failed`, or `unknown`. Unknown
completion takes precedence as E1612; otherwise the reason maps to E1614,
E1609, or E1610. All nine combinations and their terminal evidence values are
enumerated in the vector corpus's `terminal_mappings`. Core consumes no
successful operation result, releases invocation-owned resources, emits one
error outcome, and never retries.

The serial carrier reads host control only at protocol boundaries. It does not
preempt a pure computation and does not create a reader thread or event loop.
If a host deadline expires while Core is not awaiting a response, the host may
terminate the worker; that is host-owned carrier-failure evidence, not a
fabricated Core outcome.

After selection but before invocation, the host may send exactly
`{"kind":"shutdown","protocol":"jacquard-host-v0"}`. Core answers the same
two fields with kind `shutdown_ack`, flushes, and exits. After `invoke`,
shutdown is represented by `cancel` with reason `host_shutdown`; an
out-of-band process kill may leave only host evidence.

Cancellation and shutdown cannot undo an outside action. An `unknown`
completion is terminal. Automatic invocation, request, or continuation retry
is forbidden. A later operation-specific version may permit retry only by
binding idempotency keys, authenticated receipts, and crash/recovery behavior.

## 10. Outcomes, diagnostics, and evidence

Core emits one `outcome` with exactly `evidence`, `invocation_id`, `kind`,
`protocol`, and `result`.

A successful result is
`{"kind":"ok","value":VALUE}`. An error result is
`{"diagnostics":[DIAGNOSTIC...],"kind":"error"}`. Diagnostics use the
existing `jacquard-diagnostic-v1` JSON object from `Diag.to_yojson`; this
protocol does not flatten or replace its domain, code, span, summary, cause,
next step, or optional contrast. Host failures are converted by Core into the
stable codes in section 11.

`evidence` has exactly two labeled parts:

```json
{
  "core": {
    "capabilities": {
      "effects": [],
      "operations": []
    },
    "effect_requests": [],
    "interface": {
      "effects": [],
      "parameters": [],
      "result": {"items": [], "kind": "tuple"}
    },
    "invocation_id": "0000000000000000",
    "schema": "jacquard-host-core-evidence-v0",
    "target": {
      "callable": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "kind": "store-term-v0"
    },
    "terminal": "ok"
  },
  "host_observations": {
    "responses": [],
    "schema": "jacquard-host-observations-v0"
  }
}
```

Core evidence repeats the exact validated target, interface, and complete
capability envelope, plus deterministic request order. It deliberately omits
argument and result values from the evidence section; those remain in their
typed protocol messages and may be retained only under the host's separate
privacy policy. Each `effect_requests` item has exactly `effect`, `operation`,
and one-based integer `ordinal`. `terminal` is exactly `ok`, `diagnostic`,
`cancelled`, `host_failure`, or `completion_unknown`.

Each relayed accepted host response has exactly `category`, `completion`, and
`ordinal`. Successful responses use category `ok` and completion `completed`;
effect failures retain their `category` and `completion`; cancellation uses
its `reason` as the observation category and retains its `completion`.
Malformed or rejected messages are not accepted observations. The host
observation section excludes message text, argument values, result values,
timestamps, peer identity, receipts, credentials, and deployment IDs. It
records what the trusted host claimed, not what `HASH_V0` proved.

The terminal result and evidence object are deterministic for the same exact
target, interface, arguments, registry, and sequence of host messages. No
timestamp, random ID, process ID, display name, source path, or environment
field enters Core evidence. A host may bind separate authenticated operational
evidence to this transcript, but must label it as host-owned.

After `outcome`, `fatal`, or `shutdown_ack`, Core closes the protocol without
waiting for another frame. A conforming host adapter rejects any attempted
post-terminal send locally as E1608 and does not write it. If Core happens to
observe already-buffered material, it may classify it as E1608 but never emits
a second terminal frame.

## 11. Stable protocol diagnostics

These codes extend the existing structured diagnostic catalog. They use domain
`process`, severity `error`, and a specific next step. Payload excerpts are
bounded and never copied wholesale.

| Code | Condition |
|---|---|
| E1600 | unsupported protocol version or carrier selection |
| E1601 | malformed framing, UTF-8, JSON, field set, scalar, or envelope shape |
| E1602 | selected or observed byte, depth, node, text, collection, count, or diagnostic limit exceeded |
| E1603 | target is absent, unresolved, non-callable, store-incomplete, or disagrees with the pinned interface |
| E1604 | interface or runtime value uses an unsupported or non-first-order boundary kind |
| E1605 | capability effects/operations are missing, extra, unsorted, duplicated, mismatched, non-`once`, or unresolved |
| E1606 | a root operation is not in the configured registry or the host reports it unsupported |
| E1607 | the host reports authority refusal before an outside action starts |
| E1608 | message order, protocol/invocation/request ID, response shape, response type, or finish-once invariant is invalid |
| E1609 | the host reports a timeout with known non-ambiguous completion |
| E1610 | the host reports shutdown with known non-ambiguous completion |
| E1611 | EOF, process death, write failure, or carrier loss prevents a trustworthy terminal exchange |
| E1612 | the host reports that an outside action's completion is unknown |
| E1613 | the host reports that an outside action definitely failed |
| E1614 | the host cancels with known non-ambiguous completion |

A violation before a received `invoke` has passed all target, interface,
argument, and capability preflight uses a `fatal` frame containing one or more
diagnostic-v1 objects when framing remains trustworthy. This includes a
malformed or rejected `invoke`: no checked invocation began. Once preflight
succeeds and evaluation starts, a violation uses the single error `outcome`.
Carrier loss may make either frame impossible; E1611 then belongs in
host/operator evidence and must not be pretended to have come from Core.

The pre-invocation terminal frame has exactly
`{"diagnostics":[DIAGNOSTIC...],"kind":"fatal","protocol":"jacquard-host-v0"}`.
The diagnostics array is nonempty. It obeys the selected diagnostic count/byte
limits when selection succeeded and the hard limits otherwise. It carries no
invocation ID or evidence because no checked invocation began. An error
`outcome` likewise contains a nonempty diagnostics array.

## 12. Compatibility and evolution

v0 readers reject every unknown version, kind, field, enum member, value
variant, type variant, operation mode, and response shape. Writers emit only
the selected version. There is no ignore-unknown-field rule and no negotiation
inside an invocation.

An additive field, value kind, type kind, mode, message, or relaxed ordering
rule requires a new protocol version because v0's exact schemas reject it. A
new carrier may implement the same abstract sequence without changing v0
meaning, but it needs its own framing and ownership contract. A stable v1
claim remains gated by two independent adapters and one real serial
integration passing the same semantic fixtures.

This protocol changes no kernel form, canonical serializer byte, `HASH_V0`
derivation, type/effect rule, operation mode, continuation rule, diagnostic-v1
shape, ordinary CLI behavior, or existing native/interpreter claim.

## 13. Conformance vectors

[`host-protocol-v0/vectors.json`](host-protocol-v0/vectors.json) is the
normative HB.1 schema/state corpus. Positive cases contain complete semantic
transcripts. Hostile cases name the exact phase, mutation, and E16xx result.
Raw framing cases carry hexadecimal bytes so truncated lengths and invalid
UTF-8 survive JSON transport.

Hostile `framing`, `host_select`, and `invoke` phases are Core preflight cases
and produce one `fatal` in the controlled harness. `evaluation` and
`effect_response` phases begin after accepted preflight and produce one error
`outcome`. The `terminal` phase is a host-state-machine case: the host rejects
the attempted send locally after the already-recorded Core outcome. Raw input
loss assumes Core's stdout remains writable; a real bidirectional carrier loss
may instead leave only host/operator E1611 evidence.

The identities in HB.1 vectors are explicit synthetic 64-digit hashes. They
test framing, envelopes, ordering, limits, failure mapping, and evidence
separation; they do not claim that a Core store contains those objects. HB.2
adds the executable Core carrier fixtures. HB.3 packages the final executable
fixtures for independent adapters and replaces no HB.1 expectation.

A conforming implementation must:

- accept every positive transcript through its stated terminal result;
- reject every hostile case with the stated primary code and before the stated
  forbidden action;
- never emit an effect request for a preflight failure;
- never retry or emit a second terminal result; and
- compare semantic JSON objects, not insignificant whitespace or key order.

## 14. Frozen decisions

| ID | Decision | Frozen result |
|---|---|---|
| HP0.1 | invocation unit | one worker, one selected version, at most one invocation, one outstanding request |
| HP0.2 | first carrier | local stdio, four-byte big-endian length, bounded UTF-8 JSON object |
| HP0.3 | target identity | exact stored term-member `HASH_V0`; no mutable module/export/path identity |
| HP0.4 | callable shape | closed monomorphic positional first-order arrow with an exact closed effect row |
| HP0.5 | values | lossless Int/Real/Text/Hash/tuple/saturated-constructor subset; every opaque or callable value fails closed |
| HP0.6 | authority | capability effects equal the row; exact sorted `once` registry with monomorphic boundary-safe operations; no universal RPC or resource-containment claim |
| HP0.7 | ordering | deterministic worker-local invocation/request ordinals and strict source-order lockstep |
| HP0.8 | cancellation | cooperative only at protocol boundaries; pure-compute kill is host carrier evidence |
| HP0.9 | ambiguity | unknown outside completion is terminal E1612 and is never retried automatically |
| HP0.10 | evidence | deterministic Core facts and relayed host observations use separate labeled schemas |
| HP0.11 | compatibility | exact schemas, fail-closed unknowns, version bump for any shape or semantic extension |
| HP0.12 | implementation gate | HB.1 freezes schema/state vectors; HB.2 implements Core; HB.3 publishes cross-language evidence |
