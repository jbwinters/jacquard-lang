# Blessed Effect Taxonomy v1

Status: ratified for implementation review (ET.0, D56-D63), July 2026.

This specification freezes the shared effect vocabulary used by signatures,
authority manifests, package review, and future registry metadata. It is a
compatibility contract, not a claim that every reserved effect or handler is
implemented. The machine-readable copy is
[`../spec/effect-taxonomy-v1.tsv`](../spec/effect-taxonomy-v1.tsv); tests require
the table below, that artifact, the executable schema fixture, and existing
prelude declarations to agree.

## 1. Why names are load-bearing

Rows are reviewable only when their names have shared meanings. `->{Net, Eval}`
is a sentence a reviewer can understand; `->{Foo, Bar}` is not. Blessed effects
therefore receive:

- a reserved short display name in the official index;
- one fixed tier, operation schema, resumption mode, risk default, and ring;
- an interface-hash compatibility policy; and
- a one-line meaning suitable for manifests and authority diffs.

Blessing does not make an effect ambient. Root authority is still installed only
by an explicit grant, and handlers may discharge or attenuate effects in ordinary
Jacquard code.

## 2. Names, risks, rings, and status

The `name` column is the PascalCase row spelling. `index` is its reserved
lowercase short name. Every blessed row is in the `official` namespace. That
namespace is an index classification backed by resolved effect identity; it is
not part of canonical hashing and it is not a string-prefix authorization check.

Risk defaults mean:

- `none`: no external authority by itself;
- `low`: externally observable, normally read-only or human-local authority;
- `medium`: durable or operational external effects needing deliberate review;
- `high`: code execution, network-facing, storage, database, or cryptographic
  authority needing explicit attention; and
- `special`: governance semantics whose rendering is effect-specific rather
  than ordered as ordinary operational risk.

Rings retain the standard-library layering contract: control in ring 1,
world-free structures and scheduling contracts in ring 2, and world/model/meta/
governance boundaries in ring 3. `implemented` means the declaration is present
in the current prelude. `reserved` freezes the future interface but makes no
handler or runtime claim.

## 3. Complete approved table

Operation type variables are implicitly universal within an operation. `e` is
an open effect-row variable. All operations in a row use the row's declared
mode; there is no inference from names.

| effect | index-name | namespace | tier | parameters | mode | risk | ring | status | interface-hash | operations | reviewer-meaning |
|---|---|---|---|---|---|---|---:|---|---|---|---|
| `Abort` | `abort` | `official` | `control` | `a` | `once` | `none` | `1` | `implemented` | `bfdfaeee39c6f5290ebea28e805bdeb92f448f1a1e0b9c47f3c70c53975b4375` | `abort:()->a` | stop a computation without an error payload |
| `Throw` | `throw` | `official` | `control` | `e,a` | `once` | `none` | `1` | `implemented` | `f236e77750a9c066fdff9220b81ab1ba6b6a5dd5226ab63dfd112f4b14aa504e` | `throw:(e)->a` | stop a computation with a typed error payload |
| `State` | `state` | `official` | `control` | `s` | `multi` | `none` | `1` | `implemented` | `44a2946788e38fb6a734449880cce3d499aa5e2f876c5d9119773533b3d621a9` | `get:()->s;put:(s)->()` | read or replace handler-local state |
| `Emit` | `emit` | `official` | `control` | `w` | `once` | `none` | `1` | `implemented` | `28afafc8cbec5108fa6103e4670269080373bc0d9a07b1f0f257861ef4b948f6` | `emit:(w)->()` | append a value to a handler-defined stream |
| `Dist` | `dist` | `official` | `uncertainty` | `-` | `multi` | `none` | `2` | `implemented` | `5a31778adb668e471820541428a4d809f40206b231b2f9d40aeb36d5684415f0` | `sample:(Distribution a)->a;observe:(Distribution a,a)->()` | denote and condition finite possibilities |
| `Choose` | `choose` | `official` | `uncertainty` | `a` | `multi` | `none` | `2` | `reserved` | `first-release` | `choose:(List a)->a` | explore one or more alternatives under a search handler |
| `Fault` | `fault` | `official` | `uncertainty` | `-` | `multi` | `none` | `1` | `implemented` | `0b7297f7a38573108de121c794c6be6471d9c43bd4749d435a3cd247e7d5f008` | `flaky:(Text)->Bool` | explore whether a named failure site fires |
| `Eval` | `eval` | `official` | `meta` | `a` | `once` | `high` | `3` | `implemented` | `94f82f3c17d019d6ca5092b24f19d51ad40720d0accbc4c50641ade0ca056c24` | `eval-code:(Code)->a` | run code constructed or loaded at runtime |
| `Console` | `console` | `official` | `world` | `-` | `once` | `low` | `3` | `implemented` | `73e8a208eb7fadc43e3bd7aef1474884cf99ce86f8108ddf0e3baff0a74b3fc9` | `print:(Text)->();read-line:()->Text` | talk to the process terminal |
| `Clock` | `clock` | `official` | `world` | `-` | `once` | `low` | `3` | `implemented` | `9041c22386c41541b6b6818bcb26f1aeb02ae8f0dce3fedbf5f411e4bff9eecb` | `now:()->Int;sleep:(Int)->()` | observe wall-clock milliseconds or wait |
| `Env` | `env` | `official` | `world` | `-` | `once` | `low` | `3` | `reserved` | `first-release` | `env.get:(Text)->Option Text` | read one named process configuration value |
| `Fs` | `fs` | `official` | `world` | `-` | `once` | `medium` | `3` | `implemented` | `8ec13169c7181851364e55353232af8e3c7f5ee4a010fa3067fcf2058dd5ed84` | `read:(Text)->Text;write:(Text,Text)->();list-dir:(Text)->List Text` | read or mutate the filesystem under the granted root handler |
| `Net` | `net` | `official` | `world` | `-` | `once` | `high` | `3` | `implemented` | `be1aad7345c6215f227e63df6c7d05874a464f207599d4f5b85de8b0a6675b45` | `fetch:(Request)->Response` | reach a network endpoint through the granted handler |
| `Pg` | `pg` | `official` | `world` | `-` | `once` | `high` | `3` | `reserved` | `first-release` | `pg.query:(Sql,Params)->Rows` | issue a parameterized PostgreSQL query |
| `Blob` | `blob` | `official` | `world` | `-` | `once` | `high` | `3` | `reserved` | `first-release` | `blob.get:(Hash)->Option Bytes;blob.put-if-absent:(Hash,Bytes)->();blob.exists?:(Hash)->Bool` | read or add immutable objects in configured blob storage |
| `Serve` | `serve` | `official` | `world` | `-` | `once` | `high` | `3` | `reserved` | `first-release` | `serve.next:()->Request;serve.respond:(Response)->()` | receive and answer server requests |
| `Crypto` | `crypto` | `official` | `world` | `-` | `once` | `high` | `3` | `reserved` | `first-release` | `crypto.verify:(Key,Signature,Hash)->Bool;crypto.random:(Int)->Bytes` | use trusted cryptographic verification or system entropy |
| `Log` | `log` | `official` | `world` | `-` | `once` | `medium` | `3` | `reserved` | `first-release` | `log.emit:(LogEntry)->()` | emit a structured operational log entry |
| `Infer` | `infer` | `official` | `model` | `-` | `once` | `medium` | `3` | `implemented` | `324b8f59279db3cabbfaaba430168717057cea8fc1435a11a1a9106e3e6fb4d8` | `complete:(Prompt)->Text` | request a model completion selected by the handler |
| `Approval` | `approval` | `official` | `governance` | `-` | `once` | `special` | `3` | `reserved` | `first-release` | `approval.ask:(Proposal)->Decision` | request hash-bound consent for an exact proposal |
| `Audit` | `audit` | `official` | `governance` | `-` | `once` | `special` | `3` | `reserved` | `first-release` | `audit.record:(AuditEntry)->()` | record governance evidence in an append-only stream |
| `Secret` | `secret` | `official` | `governance` | `-` | `once` | `special` | `3` | `reserved` | `first-release` | `secret.read:(SecretRef)->Secret;secret.expose:(Secret)->Text` | resolve opaque confidential material or explicitly expose it |
| `Judge` | `judge` | `official` | `governance` | `-` | `once` | `special` | `3` | `reserved` | `first-release` | `judge.assess:(Call)->Assessment` | assess a proposed call without performing it |
| `Async` | `async` | `official` | `concurrency` | `a` | `once` | `none` | `2` | `reserved` | `4ff8ce05ab09968163492b3be40fc91381b47dee5fb4b2980f9416d50f38e66f` | `async.spawn:(()->{Async\|e}a)->Task a;async.await:(Task a)->TaskResult a;async.cancel:(Task a)->();async.yield:()->()` | schedule structured tasks while charging child effects to the parent row |
| `Channel` | `channel` | `official` | `concurrency` | `a` | `once` | `none` | `2` | `reserved` | `first-release` | `channel.open:()->ChannelHandle a;channel.send:(ChannelHandle a,a)->Result ChannelError ();channel.recv:(ChannelHandle a)->Result ChannelError a;channel.close:(ChannelHandle a)->()` | communicate typed values between structured tasks |

The full 64-hex identities and unabridged operation strings are normative in
the TSV artifact. In particular, `Check` remains a prelude testing protocol,
not a blessed program-authority name; search packages may define additional
multi effects without acquiring an official short name.

### Async implementation obligation

The one-law schema is exactly
`async.spawn : (() ->{Async | e} a) -> Task a`. The self row is intentional:
performing `async.spawn` must make the caller row gain `{Async | e}`, so a
child cannot launder authority out of its parent signature.

SC.4 admits an effect's own name inside its operation rows and gives the exact
resolved `async.spawn` identity a dependent operation scheme: its thunk and
caller share `{Async | e}`. The dependency survives aliases, higher-order
wrappers, returned closures, tuples, polymorphic row instantiation, and nested
scopes. Executable concurrency fixtures pin `{Async, Net}` before a scope and
`{Net}` after one, and reject misleading closed annotations and cyclic rows.
Generic operation typing remains unchanged. `Async` is still reserved: SC.3
represents opaque run/scope-local Task values, SC.4 adds the static
non-laundering rule, and SC.5 adds the policy-independent lifecycle core. No
milestone yet implements scheduling policy, executable scopes, or a root
handler. See
[`concurrency.md`](concurrency.md).

The reserved interface nevertheless has a full identity because SC.4 keeps it
checker-privileged. Its HASH_V0 identity is
`4ff8ce05ab09968163492b3be40fc91381b47dee5fb4b2980f9416d50f38e66f`,
structurally derived from the exact `Task`, `TaskResult`, four operation
schemas/modes, and self-effect row. The checker also revalidates that complete
resolved structure; neither the spelling `async` nor a partial shape grants
the special rule.

## 4. Governance data schemas

The governance operations above are not placeholders. Their boundary types are
frozen as follows:

```text
type Authority = Effect(name: Text) | Resource(effect-name: Text, scope: Text)
type Call = Call(
  subject: Hash, operation: Text, arguments: Code,
  authority: List Authority, summary: Text, preconditions: Code)
type Assessment = Assessment(
  risk: Risk, confidence: Real, reasons: List Text, evidence: Code)
type OutcomeSummary = OutcomeSummary(status: Text, digest: Hash, detail: Text)
type Proposal = Proposal(
  subject: Hash, policy: Hash, assessment: Hash, summary: Text,
  authority: List Authority, preview: Option OutcomeSummary)
type Decision =
  | Approved(proposal: Hash, approver: Text, evidence: Code)
  | Denied(proposal: Hash, approver: Text, reason: Text)
  | Escalate(proposal: Hash, reason: Text)
type AuditEntry =
  | Evaluated(call: Hash, policy: Hash, assessment: Assessment, verdict: Verdict)
  | Consented(call: Hash, proposal: Hash, decision: Decision)
  | Completed(call: Hash, branch: Text, outcome: OutcomeSummary)
type SecretRef = SecretRef(name: Text, version: Option Text)
type Task a                                      -- opaque scheduler handle
type TaskResult a = Done(value: a) | Failed(message: Text) | Cancelled
type ChannelHandle a                            -- opaque, distinct from effect Channel
type ChannelError = ChannelClosed
```

`Hash`, `Bytes`, `Secret`, `Task`, and `ChannelHandle` are opaque
library/runtime types. `Secret`
has no `Show` instance; generic inspection renders it redacted. `secret.expose`
is the only standard conversion to `Text`, so deliberate exposure remains in
the effect row. This is non-derivability, not information-flow tracking: after
exposure a program can still leak the text.

`Call.subject` hashes the resolved operation identity, canonical arguments,
declared authority, and preconditions. Presentation summary is excluded.
`Proposal` requires its subject hash and exact authority delta. Every dry-run or
scripted Approval handler returns `Escalate`, never `Approved`.

The declarations below are an executable surface fixture for the reserved
world, governance, Async, and Channel operation boundaries. Its small carrier
constructors for future opaque types are test scaffolding, not public
constructors. Accepting the Async declaration is only schema evidence; the
charging and laundering fixtures in `concurrency.md` are the typing evidence.

```jacquard doctest=effect-taxonomy-schemas mode=check fixture=effect-taxonomy-schemas.jac stdout=effect-taxonomy-schemas.stdout stderr=empty exit=0
type Hash = | HashValue(value: Text)
type Bytes = | BytesValue(value: Text)
type Sql = | SqlValue(value: Text)
type Params = | ParamsValue(value: List Text)
type Rows = | RowsValue(value: List (List Text))
type Key = | KeyValue(value: Text)
type Signature = | SignatureValue(value: Bytes)
type LogEntry = | LogEntryValue(value: Text)

type Risk = | Low | Medium | High | Forbidden
type Verdict = | Allow | Simulate | Ask | Block
type Authority =
  | Effect(name: Text)
  | Resource(effect-name: Text, scope: Text)
type Call =
  | Call(
      subject: Hash,
      operation: Text,
      arguments: Code,
      authority: List Authority,
      summary: Text,
      preconditions: Code)
type Assessment =
  | Assessment(risk: Risk, confidence: Real, reasons: List Text, evidence: Code)
type OutcomeSummary =
  | OutcomeSummary(status: Text, digest: Hash, detail: Text)
type Proposal =
  | Proposal(
      subject: Hash,
      policy: Hash,
      assessment: Hash,
      summary: Text,
      authority: List Authority,
      preview: Option OutcomeSummary)
type Decision =
  | Approved(proposal: Hash, approver: Text, evidence: Code)
  | Denied(proposal: Hash, approver: Text, reason: Text)
  | Escalate(proposal: Hash, reason: Text)
type AuditEntry =
  | Evaluated(call: Hash, policy: Hash, assessment: Assessment, verdict: Verdict)
  | Consented(call: Hash, proposal: Hash, decision: Decision)
  | Completed(call: Hash, branch: Text, outcome: OutcomeSummary)
type SecretRef = | SecretRef(name: Text, version: Option Text)
type Secret = | OpaqueSecret
type Task a = | TaskOpaque
type TaskResult a = | Done(value: a) | Failed(message: Text) | Cancelled
type ChannelHandle a = | ChannelHandleValue(id: Int)
type ChannelError = | ChannelClosed

once effect Env where {
  env.get : (Text) -> Option Text
}
once effect Pg where {
  pg.query : (Sql, Params) -> Rows
}
once effect Blob where {
  blob.get : (Hash) -> Option Bytes
  blob.put-if-absent : (Hash, Bytes) -> ()
  blob.exists? : (Hash) -> Bool
}
once effect Serve where {
  serve.next : () -> Request
  serve.respond : (Response) -> ()
}
once effect Crypto where {
  crypto.verify : (Key, Signature, Hash) -> Bool
  crypto.random : (Int) -> Bytes
}
once effect Log where {
  log.emit : (LogEntry) -> ()
}
once effect Approval where {
  approval.ask : (Proposal) -> Decision
}
once effect Audit where {
  audit.record : (AuditEntry) -> ()
}
once effect Secret where {
  secret.read : (SecretRef) -> Secret
  secret.expose : (Secret) -> Text
}
once effect Judge where {
  judge.assess : (Call) -> Assessment
}
once effect Async a where {
  async.spawn : (() ->{Async | e} a) -> Task a
  async.await : (Task a) -> TaskResult a
  async.cancel : (Task a) -> ()
  async.yield : () -> ()
}
once effect Channel a where {
  channel.open : () -> ChannelHandle a
  channel.send : (ChannelHandle a, a) -> Result ChannelError ()
  channel.recv : (ChannelHandle a) -> Result ChannelError a
  channel.close : (ChannelHandle a) -> ()
}
```

## 5. Typed facades and concrete authority

`Tool` and `Host` are roles, not blessed effects. A governed component declares
a domain-specific, once facade such as `Workspace`, `Deploy`, or `Commerce` with
typed operations. Its membrane handles that facade and re-performs the exact
concrete effects it needs—`Fs`, `Net`, `Pg`, `Blob`, `Secret`, `Serve`, and so
on. A universal stringly `Tool.call` would erase argument/result types; an
opaque `Host` row would erase real authority. Both are forbidden by D61-D62.

`Judge` is blessed by D63 because assessment is shared governance vocabulary.
It assesses calls and does not perform them. A rules handler may discharge it
purely; a model-backed handler exposes `Infer`, and a posterior handler exposes
`Dist`, in the handler's outward row.

## 6. User effects and compatibility

User effects remain first-class. Their canonical package names are
publisher-scoped (`pk:<publisher-key>/<package>` under D18), and review tools
render a package-qualified hint plus resolved identity. They receive no
built-in risk color. A registry may curate metadata for a particular resolved
interface identity, but matching a short string or package-local rename never
inherits official status or color.

An interface is the complete ordered `DefEffect`: effect parameters, operation
names/order, modes, parameter/result types, and every referenced type identity.
Under `HASH_V0`, any change to that structure produces a new declaration hash
and is breaking. Adding an operation is also breaking for the same reason;
"additions are cheap" means a new version can coexist by hash, not that existing
handlers silently remain exhaustive. Renames in the mutable name index and
metadata-only changes retain identity.

The twelve implemented blessed effects keep their exact current declaration
hashes listed above. ET.0 does not rewrite those declarations. This preserves
the historical absence encoding for `multi`, the reviewed `once` discriminator,
and existing operation names—including `Eval.eval-code`. Each reserved effect's
first shipped `DefEffect` must match this schema; its resulting full hash is
then added to the table and frozen. A mode, operation, order, or referenced-type
edit after that point is a new interface, never an in-place revision.

## 7. Indexed decisions

| ID | decision | ratified result |
|---|---|---|
| D56 | taxonomy freeze v1 | §3 and the TSV artifact; resolved identities govern, additions use new hashes |
| D57 | Secret opacity | opaque, no `Show`, inspect redacts, explicit in-row `secret.expose`; taint deferred |
| D58 | audit chain | canonical handler hash-chains entries, publishes a head, and supports offline verification |
| D59 | Proposal schema | subject hash and authority are mandatory; hash-less proposals are ill-formed |
| D60 | membrane placement | ring 3 governance module plus cookbook and flagship demo, implemented in later phases |
| D61 | facade shape | domain-specific typed facade effects; no universal stringly `Tool.call` |
| D62 | raw authority | host is a role; membranes re-perform concrete blessed world effects, never `Host` |
| D63 | Judge status | blessed once effect with `judge.assess : (Call) -> Assessment` |

Later tasks implement registry coloring, governance handlers, membranes, and
product review surfaces. This task freezes the vocabulary they consume without
claiming those later artifacts already exist.
