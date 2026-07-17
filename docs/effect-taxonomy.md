# Blessed Effect Taxonomy v1

Status: ET.8 release-frozen taxonomy (D56-D63), with Audit, Secret, Approval,
Judge, and Workspace shipped and their canonical boundaries evidenced through
ET.8, GM.5, and GM.9, July 2026.

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

Risk defaults are review-routing metadata, not permissions or guarantees:

- `none`: no external authority by itself; behavioral and uncertainty review
  can still be required;
- `low`: externally observable, normally read-only or human-local authority;
- `medium`: durable or operational external effects needing deliberate review;
- `high`: code execution, network-facing, storage, database, or cryptographic
  authority needing explicit attention; and
- `special`: governance semantics whose rendering is effect-specific rather
  than ordered as ordinary operational risk; the effect's own contract must be
  reviewed.

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
| `Workspace` | `workspace` | `official` | `world` | `-` | `once` | `high` | `3` | `implemented` | `d5831f495fdb26e05d53d886786f07230f7bb808ac4933ab32e0a9238c89f9d0` | `workspace.read-file:(Path)->Result ToolError Text;workspace.write-file:(Path,Text)->Result ToolError ();workspace.fetch:(Request)->Result ToolError Response` | request mediated workspace reads, writes, or fetches without directly acquiring raw authority |
| `Pg` | `pg` | `official` | `world` | `-` | `once` | `high` | `3` | `reserved` | `first-release` | `pg.query:(Sql,Params)->Rows` | issue a parameterized PostgreSQL query |
| `Blob` | `blob` | `official` | `world` | `-` | `once` | `high` | `3` | `reserved` | `first-release` | `blob.get:(Hash)->Option Bytes;blob.put-if-absent:(Hash,Bytes)->();blob.exists?:(Hash)->Bool` | read or add immutable objects in configured blob storage |
| `Serve` | `serve` | `official` | `world` | `-` | `once` | `high` | `3` | `reserved` | `first-release` | `serve.next:()->Request;serve.respond:(Response)->()` | receive and answer server requests |
| `Crypto` | `crypto` | `official` | `world` | `-` | `once` | `high` | `3` | `reserved` | `first-release` | `crypto.verify:(Key,Signature,Hash)->Bool;crypto.random:(Int)->Bytes` | use trusted cryptographic verification or system entropy |
| `Log` | `log` | `official` | `world` | `-` | `once` | `medium` | `3` | `reserved` | `first-release` | `log.emit:(LogEntry)->()` | emit a structured operational log entry |
| `Infer` | `infer` | `official` | `model` | `-` | `once` | `medium` | `3` | `implemented` | `324b8f59279db3cabbfaaba430168717057cea8fc1435a11a1a9106e3e6fb4d8` | `complete:(Prompt)->Text` | request a model completion selected by the handler |
| `Approval` | `approval` | `official` | `governance` | `-` | `once` | `special` | `3` | `implemented` | `362425a29077a7efbcc37047182e579f46199a50473045eb4126a917dfc2a196` | `approval.ask:(Proposal)->Decision` | request hash-bound consent for an exact proposal |
| `Audit` | `audit` | `official` | `governance` | `-` | `once` | `special` | `3` | `implemented` | `40bc4343fb2b4bcc18b18f63f7bb68675b746751bb40b876072e622046a81372` | `audit.record:(AuditEntry)->()` | record governance evidence in an append-only stream |
| `Secret` | `secret` | `official` | `governance` | `-` | `once` | `special` | `3` | `implemented` | `6d092eccc3c9858a2a95120da5a011964cbb3ad76968e11c1cbb062c119fbb31` | `secret.read:(SecretRef)->Secret;secret.expose:(Secret)->Text` | resolve opaque confidential material or explicitly expose it |
| `Judge` | `judge` | `official` | `governance` | `-` | `once` | `special` | `3` | `implemented` | `9b677b5e2c3ec8521c5d5dfac321ae361a959565e1cbf082fec4512199977354` | `judge.assess:(Call)->Assessment` | assess a proposed call without performing it |
| `Async` | `async` | `official` | `concurrency` | `a` | `once` | `none` | `2` | `reserved` | `4ff8ce05ab09968163492b3be40fc91381b47dee5fb4b2980f9416d50f38e66f` | `async.spawn:(()->{Async\|e}a)->Task a;async.await:(Task a)->TaskResult a;async.cancel:(Task a)->();async.yield:()->()` | schedule structured tasks while charging child effects to the parent row |
| `Channel` | `channel` | `official` | `concurrency` | `a` | `once` | `none` | `2` | `implemented` | `bf9a334188ac13495eeb070fdc215d51763d9761b4775c98c61f44ebb1b03756` | `channel.open:(Int)->Result ChannelError (ChannelHandle a);channel.send:(ChannelHandle a,a)->Result ChannelError ();channel.recv:(ChannelHandle a)->Result ChannelError a;channel.close:(ChannelHandle a)->()` | communicate typed values between structured tasks |

The full 64-hex identities and unabridged operation strings are normative in
the TSV artifact. In particular, `Check` remains a prelude testing protocol,
not a blessed program-authority name; search packages may define additional
multi effects without acquiring an official short name.

### Canonical handler and boundary inventory

“Canonical” means the shipped, reviewed way to discharge or install the effect;
it does not imply that every boundary is pure or available to user code. A root
grant is a runtime boundary. The Secret entries are embedding APIs because
plaintext must not become an ordinary prelude value before explicit exposure.

| effect | canonical handlers or installation boundaries |
|---|---|
| `Abort` | `abort.to-option`, `abort.or` |
| `Throw` | `throw.to-result`, `throw.catch` |
| `State` | `state.run`, `state.eval` |
| `Emit` | `emit.collect`, `emit.pipe` |
| `Dist` | `dist.enumerate`, `dist.sample-lw`, explicit root sampling grant |
| `Fault` | `fault.none`, `fault.random`, `fault.all` |
| `Eval` | explicit root grant only |
| `Console` | `console.scripted`, explicit root grant |
| `Clock` | `clock.fixed`, explicit root grant |
| `Fs` | `fs.in-memory`, `fs.read-only`, explicit root grant |
| `Net` | `net.scripted`, `net.record`, explicit root grant |
| `Infer` | `infer.scripted`, explicit root grant |
| `Approval` | `approval.console`, `approval.scripted`, `approval.dry-run`, `approval.policy-auto` |
| `Audit` | `audit.in-memory`, `audit.line-log` |
| `Secret` | `Prelude.install_secret_fixed`, `Prelude.install_secret_vault`, explicit environment root grant |
| `Judge` | `judge.rules`, `judge.fixed`, `judge.scripted`, `judge.model` |
| `Workspace` | `workspace.read-file`, `workspace.write-file`, `workspace.fetch` typed facade |
| `Async` | interpreted structured scheduler installed by SC.9 |
| `Channel` | interpreted exact-scope FIFO channels installed by SC.14 |

`Async` remains a schema-reserved taxonomy name with the exact published
identity shown above and an interpreted structured scheduler. `Channel` is a
released prelude effect: SC.14 admits only its frozen SC.13 identity to the
interpreted scheduler, without a root grant or `--allow channel`.

The remaining seven blessed names are **reserved and unimplemented**:
`Choose`, `Env`, `Pg`, `Blob`, `Serve`, `Crypto`, and `Log`. Their
schemas reserve compatibility vocabulary only. They have no shipped declaration
hash, canonical handler, root grant, or product-availability claim. A future
first implementation must match the reserved schema and publish its resulting
full identity before tooling may classify it as released.

### Uncertainty review is separate from authority review

`Dist` has risk `none` because it needs no external authority, not because a
probabilistic result is certainly correct. Review its support, weights,
observations, handler, seed, and whether approximation error is acceptable.
`Infer` is `medium` because it crosses a model boundary; a completion is model
output, not a verified fact. A posterior or `Assessment.confidence` is evidence,
not consent: neither can substitute for an exact hash-bound `Approval` decision.

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
Generic operation typing remains unchanged. `Async` is still a reserved
taxonomy name, while its implementation has progressed beyond a placeholder:
SC.3 represents opaque run/scope-local Task values, SC.4 adds the static
non-laundering rule, SC.5 adds the policy-independent lifecycle core, and SC.9
installs the interpreted structured scheduler. See
[`concurrency.md`](concurrency.md).

The reserved interface nevertheless has a full identity because SC.4 keeps it
checker-privileged. Its HASH_V0 identity is
`4ff8ce05ab09968163492b3be40fc91381b47dee5fb4b2980f9416d50f38e66f`,
structurally derived from the exact `Task`, `TaskResult`, four operation
schemas/modes, and self-effect row. The checker also revalidates that complete
resolved structure; neither the spelling `async` nor a partial shape grants
the special rule.

## 4. Governance data schemas

This section records the ET.0 boundary vocabulary that preceded the membrane
charter. GM.0 in [`effect-membranes.md`](effect-membranes.md) supersedes the
exact governance record fields, version tags, ID inputs, and audit sequence
fields below. The effect operation boundaries (`Call -> Assessment`,
`Proposal -> Decision`, `AuditEntry -> ()`, and the two `Secret` operations)
remain unchanged. Implementations must use the GM.0 schemas; this older block
and its executable fixture remain historical ET.0 compatibility evidence.

```text
type Authority = Effect(name: Text) | Resource(effect-name: Text, scope: Text)
type Call = Call(
  subject: Hash, operation: Text, arguments: Code,
  authority: List Authority, summary: Text, preconditions: Code)
type Assessment = Assessment(
  risk: Risk, confidence: Real, reasons: List Text, evidence: Code)
type OutcomeSummary = OutcomeSummary(status: Text, digest: Hash, detail: Text)
type Proposal = Proposal(
  proposal-id: Hash, call-subject: Hash, policy: Hash, assessment-hash: Hash,
  authority: List Authority, rendering: Code, summary: Text,
  preview: Option OutcomeSummary)
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
type ChannelError = ChannelClosed | InvalidCapacity(requested: Int)
```

`Hash`, `Bytes`, `Secret`, `Task`, and `ChannelHandle` are opaque
library/runtime types. Hash has no public value constructor: `hash.parse`
accepts only the canonical 64-lowercase-hex HASH_V0 spelling, and
`hash.to-text` returns that unique spelling. Its marker is unavailable by both
name and direct derived hash, and the OCaml `Hash.t` representation is abstract. `Secret`
has no `Show` instance; generic inspection renders it redacted. `secret.expose`
is the only standard conversion to `Text`, so deliberate exposure remains in
the effect row. This is non-derivability, not information-flow tracking: after
exposure a program can still leak the text.

ET.5 supplies three explicit handler boundaries without changing the interface
identity or opaque value representation. `secret.fixed` is the deterministic
embedding fixture installed by `Prelude.install_secret_fixed`; exact
`(name, version)` matches return opaque values and missing names or versions
fail separately. `--allow secret` installs the environment adapter, whose
collision-free `JACQUARD_SECRET_V0_<name-hex>_{LATEST|VERSION_<version-hex>}`
keys are derived only from safe `SecretRef` data. `Prelude.install_secret_vault`
accepts an injected provider callback and selects no vendor or transport. Its
closed failure type carries no backend message or value. Dry-run installs none
of these live handlers and therefore refuses a remaining `Secret` row.

`Call.subject` hashes the resolved operation identity, canonical arguments,
declared authority, and preconditions. Presentation summary is excluded.
ET.6 releases the schema above as `proposal-v1`. `approval.make-proposal`
requires the semantic call subject, policy and assessment hashes, the exact
ordered authority list, the reviewed `Code` rendering and summary text, and an
optional typed preview. It computes `Proposal.proposal-id` from the one canonical
`proposal-v1` Code encoding; `approval.validate-proposal` recomputes that hash
and fails closed on a forged carrier. The earlier ET.2 Decision encoding was
already versioned as `approved-v1`, `denied-v1`, and `escalate-v1`, so its type
and Audit identity remain unchanged. `approval.validate-decision` requires the
embedded Decision hash to equal the exact proposal hash, and
`approval.before-action` forces its action thunk only after both checks pass.

`code.hash : (Code) ->{} Hash` applies HASH_V0 to the same canonical compact
Code bytes used by `code.render`; it is not a Proposal-specific second
serializer. Metadata is absent from those bytes. Consequently presentation
metadata on the semantic call does not change its subject, while authority,
policy, assessment, preview, rendering, or summary changes produce a different
proposal.

ET.7 supplies four canonical handlers. `approval.console` prints the exact
proposal hash followed by the ordered authority request and recognizes only
the exact response `approve` as consent. `approval.scripted` consumes explicit
Decisions supplied by a test fixture and validates each Decision against the
current Proposal; it never synthesizes consent. `approval.dry-run` always
returns `Escalate`, never `Approved`. `approval.policy-auto` may approve only
an already-`Allow` policy verdict; `Ask` and `Simulate` escalate, while `Block`
denies. Every handler recomputes the Proposal hash before it can resume the
protected computation. The classifier that supplies the verdict is a trusted
handler dependency: a live membrane must derive it from the exact validated
policy and assessment, never from governed caller input.

GM.0 retains that two-level identity rule while naming the successor membrane
fields `Call.call-id` and `Proposal.proposal-id`, adding `GovernanceV0` and the
exact constituent IDs, and keeping presentation summary out of call identity.
GM.1 implements that successor vocabulary as distinct versioned
`governance-*` ring-3 carriers rather than silently rewriting the frozen ET.2
or ET.6 declarations. Its pure constructors and verifier backstops reject
invalid confidence and policy thresholds, malformed operation identity,
noncanonical authority envelopes, and forged Call or BoundPolicy hashes through
`Result`. Call construction accepts a qualified operation name and derives the
exact member hash from its resolved Store effect declaration; validation
repeats that lookup before accepting the carried identity. Dry verdicts
Simulate every non-Forbidden risk when a simulator exists, independent of the
stored policy threshold, and return `NoSimulation` only when it does not. The
validated ET.6 carrier above remains compatibility evidence and keeps its
original identities. Every dry-run or scripted Approval handler returns
`Escalate`, never `Approved`; canonical handlers remain ET.7 scope.

GM.2 completes the successor review identity as the separate
`GovernanceProposal`/`governance-proposal-v0` carrier. Its smart constructor
derives the Call, live BoundPolicy, and Assessment identities from validated
values and obtains the authority envelope from the Call. The exact proposal
Code commits, in order, `GovernanceV0`, call ID, policy ID, assessment ID,
authority, optional preview, reviewed rendering, and summary. Validation
recomputes the carried hash and the artifact-aware boundary additionally
checks every constituent ID and the byte-identical authority envelope. This
uses the already released `code.hash` canonical-Code boundary; the ET.6
`proposal-v1` carrier and `Approval` effect remain hash-for-hash unchanged.

GM.0 names the semantic identities `Call.call-id` and
`Proposal.proposal-id`, adds `GovernanceV0` and the exact constituent IDs, and
keeps presentation summary out of the call identity. Every dry-run or scripted
Approval handler returns `Escalate`, never `Approved`.

The declarations below are an executable surface fixture for the reserved
world, governance, Async, and Channel operation boundaries. Its small carrier
constructors for future opaque types are test scaffolding, not public
constructors. Accepting the Async declaration is only schema evidence; the
charging and laundering fixtures in `concurrency.md` are the typing evidence.
The fixture reuses the released Audit and Approval governance types from the
prelude.

```jacquard doctest=effect-taxonomy-schemas mode=check fixture=effect-taxonomy-schemas.jac stdout=effect-taxonomy-schemas.stdout stderr=empty exit=0
type Bytes = | BytesValue(value: Text)
type Sql = | SqlValue(value: Text)
type Params = | ParamsValue(value: List Text)
type Rows = | RowsValue(value: List (List Text))
type Key = | KeyValue(value: Text)
type Signature = | SignatureValue(value: Bytes)
type LogEntry = | LogEntryValue(value: Text)

type Call =
  | Call(
      subject: Hash,
      operation: Text,
      arguments: Code,
      authority: List Authority,
      summary: Text,
      preconditions: Code)
type SecretRef = | SecretRef(name: Text, version: Option Text)
type Secret = | OpaqueSecret
type Task a = | TaskOpaque
type TaskResult a = | Done(value: a) | Failed(message: Text) | Cancelled
type ChannelHandle a = | ChannelOpaque
type ChannelError = | ChannelClosed | InvalidCapacity(requested: Int)

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
  channel.open : (Int) -> Result ChannelError (ChannelHandle a)
  channel.send : (ChannelHandle a, a) -> Result ChannelError ()
  channel.recv : (ChannelHandle a) -> Result ChannelError a
  channel.close : (ChannelHandle a) -> ()
}
```

### Channel implementation contract

SC.13 froze the complete Channel interface and its HASH_V0 identity before a
handler existed; SC.14 implements that exact contract. A capacity of zero denotes a rendezvous channel, a positive
capacity denotes a bounded FIFO channel, and a negative capacity returns
`Err(InvalidCapacity(requested))` before allocating a handle. `ChannelHandle`
is an opaque exact-scope/run capability. Close is idempotent, rejects pending
and future sends with `ChannelClosed`, and lets receivers drain values already
accepted into the buffer before returning `ChannelClosed`. The ordering,
cancellation, fan-in, policy interaction, trace fixtures, and SC.14
implementation checklist are normative in
[`concurrency.md`](concurrency.md#8-typed-channels-sc13--c3-contract). SC.14
admits only this exact interface hash to the interpreted scheduler; Channel is
never a world grant, `--allow channel` remains invalid, and a near-match
receives no special routing. Native compilation still has no Channel runtime.

## 5. Typed facades and concrete authority

`Tool` and `Host` are roles, not blessed effects. A governed component declares
a domain-specific, once facade such as `Workspace`, `Deploy`, or `Commerce` with
typed operations. Its membrane handles that facade and re-performs the exact
concrete effects it needs—`Fs`, `Net`, `Pg`, `Blob`, `Secret`, `Serve`, and so
on. A universal stringly `Tool.call` would erase argument/result types; an
opaque `Host` row would erase real authority. Both are forbidden by D61-D62.
Any earlier planning shorthand written as generic `Tool -> Host` is therefore
superseded by GM.0. There is no `Tool` or `Host` effect in governed-membrane v0.

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

The seventeen implemented blessed effects keep their exact current declaration
hashes listed above. ET.0 does not rewrite those declarations. This preserves
the historical absence encoding for `multi`, the reviewed `once` discriminator,
and existing operation names—including `Eval.eval-code`. Each reserved effect's
first shipped `DefEffect` must match this schema; its resulting full hash is
then added to the table and frozen. A mode, operation, order, or referenced-type
edit after that point is a new interface, never an in-place revision.

### Registry realization

`Effect_registry` is the executable copy used by review tooling. Its resolved
registry contains exactly the seventeen implemented entries and is keyed only by
their full `DefEffect` hashes. The complete 26-entry catalog is also typed, but
the nine `reserved` entries carry no hash and name only the
`first-release` policy; registration rejects them until a real first interface is
implemented and frozen. This keeps schema reservation distinct from resolved
program identity. Audit, Secret, Approval, Judge, and Workspace are released
governance interfaces. Their identities above are the shipped `DefEffect`
hashes. The released operations are once
`audit.record : (AuditEntry) -> ()`, once
`secret.read : (SecretRef) -> Secret`, once
`secret.expose : (Secret) -> Text`, once
`approval.ask : (Proposal) -> Decision`, and once
`judge.assess : (Call) -> Assessment`, plus once `workspace.read-file`,
`workspace.write-file`, and `workspace.fetch`. The executable GM.5
declaration uses the collision-safe GM.1 carrier names `GovernanceCall` and
`GovernanceAssessment`; these are the versioned v0 spellings of the charter
schemas shown here.

Plain rendering is deterministic. Optional ANSI styling colors only the risk
token of an identity-confirmed official entry. An unregistered effect with
package metadata preserves its canonical `pk:<publisher-key>/<package>` hint.
Until package identity is available, tooling uses the explicit deterministic
fallback `unpackaged:<hash-prefix>/<local-name>`; it does not invent a
publisher. Both forms include the full resolved hash and `unrated user effect`,
and styling never colors them. In particular, a user effect whose local
spelling is `net` does not inherit `Net` metadata or a built-in `--allow net`
suggestion.

This identity rule continues through native compilation. Baked manifests retain
the resolved effect hash, generated grant flags are hash-keyed, and a named
`--allow` installs native operations only when their owning `DefEffect` hash is
the frozen official identity. Reusing an official effect or operation name
therefore cannot acquire its grant.

Semantic diff applies this rendering only to a resolved effect row in the row
position of a typed arrow. Type-shaped forms below `quote` remain ordinary code
data and receive structural diffs, never an authority label.

### Review non-goals

- Taxonomy metadata never grants authority; only a checked row plus an explicit
  root installation or enclosing handler can make an operation run.
- Risk defaults are not vulnerability scores, policy verdicts, or claims that a
  computation is safe. User effects stay unrated until metadata is reviewed for
  their exact identity.
- The taxonomy does not provide path-scoped object capabilities, a production
  sandbox, continuous probability, verified model truth, automatic consent, or
  a universal host/tool effect.
- Secret opacity is non-derivability, not taint tracking. After
  `secret.expose`, plaintext is ordinary `Text` and may be copied or leaked.
- Secret redaction does not promise process-memory scrubbing. The v0 OCaml and
  native carriers do not zero payload bytes when a Secret is released, so
  process memory and crash-dump protection remain embedding responsibilities.
- A reserved schema is neither an implementation nor a roadmap promise. This
  release has interpreted `Async` and exact-identity `Channel` scheduling, but
  no database/blob/serve/crypto/log provider or pure `Choose` interface.

### Audit chain v1

D58 is implemented by the single canonical carrier
`(audit-chain-v1 #PREVIOUS #DIGEST ENTRY)`, one compact form plus LF per record.
`ENTRY` is the existing `audit-entry-v1` form produced by `audit.entry-code`;
the chain layer does not define a second AuditEntry serializer. The fixed empty
head is
`5a8760f8a958799a0e38154fae7cc086d9a1ee0153ff62451ac1a07f7b0b50d7`.

For each record, `DIGEST` is HASH_V0 over the domain bytes
`jacquard-audit-chain-v1\0`, the predecessor's 32 raw HASH_V0 bytes, and the
compact canonical bytes of `ENTRY`. The chain version and domain are frozen
together; alternate versions fail closed rather than falling through to the v1
verifier.

`jacquard audit append LOG ENTRY --previous HASH` first reconstructs `LOG`
against the caller's independently held previous head, appends one record, and
prints the new publishable head. It is a single-writer interface: callers must
serialize competing appenders. Append also takes a nonblocking advisory
whole-file lock, then verifies and writes through the same open file
description. Immediately before writing it rechecks that the pathname still
identifies that regular file. This lock is a fail-closed race check, not a
multi-writer protocol. `jacquard governance verify-log LOG --head HASH`
performs offline verification and rejects malformed or noncanonical records,
wrong versions, broken predecessors, digest mismatches, and a reconstructed
head different from the independently published head. The final comparison is
what detects removal of a valid tail.

Library and CLI reads use one bounded fail-closed path: chain logs are limited
to 16 MiB and entry inputs to 1 MiB. A read verifies that the regular file's
descriptor and path identity, size, mtime, and ctime stay stable through EOF.
A coherent snapshot then undergoes strict byte verification; a malformed
snapshot returns its ordinary format diagnostic. Truncation, growth, or
replacement detected during acquisition, over-limit input, and expected I/O
failures produce E1306 before any record write. A pathname replacement never
receives a record intended for the verified inode.

## 7. Indexed decisions

| ID | decision | ratified result |
|---|---|---|
| D56 | taxonomy freeze v1 | §3 and the TSV artifact; resolved identities govern, additions use new hashes |
| D57 | Secret opacity | opaque, no `Show`, inspect redacts, explicit in-row `secret.expose`; taint deferred |
| D58 | audit chain | implemented `audit-chain-v1` carrier commits existing canonical entry bytes and predecessor HASH_V0; CLI append publishes a head and governance verification fails closed offline |
| D59 | Proposal schema | implemented `proposal-v1` binds semantic call subject separately from exact review identity; policy, assessment, ordered authority, rendering, summary, and preview are mandatory hash inputs; decisions embed that exact proposal hash, and hash-less, forged, or mismatched carriers fail before action. GM.0 D67 supersedes the earlier `subject` field name with exact `call-id` and `proposal-id` schemas. |
| D60 | membrane placement | GM.1 implements the versioned core data and policies in ring 3; GM.5 releases Judge handlers and GM.9 releases the typed Workspace facade, while cookbook and flagship demo work remain later phases |
| D61 | facade shape | domain-specific typed facade effects; no universal stringly `Tool.call` |
| D62 | raw authority | host is a role; membranes re-perform concrete blessed world effects, never `Host` |
| D63 | Judge status | blessed once effect with `judge.assess : (Call) -> Assessment` |

ET.8 closes the taxonomy slice with released-identity, registry, prelude,
documentation, manifest, and authority-diff evidence. Governed membranes and
other later milestones remain separate; this freeze does not claim those
products or the reserved interfaces already exist.
