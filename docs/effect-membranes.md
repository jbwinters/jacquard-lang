# Governed Effect Membranes — GM.0 Implementation Charter

Companion to the blessed effect taxonomy, effect linearity, the standard library, Warp, the surface syntax, and the package manager. This document expands the membrane pattern canonized by D60 into a complete semantic and library design: what crosses the boundary, what is trusted, how calls are identified, how live and simulated execution differ, how approvals and audits bind to immutable IDs, and what the type system can prove before the program runs.

Status: normative v0 charter for G0-G4, July 2026. D61-D73 are frozen for
implementation. No kernel form, ambient authority, scheduler behavior, or
general linear type is added. G5 posterior judgment remains a separate research
phase and is not part of the v0 contract.

Implementation note: GM.2 completes the §10 two-level identity core. The
successor `GovernanceProposal` is intentionally separate from the frozen ET.6
carrier, derives its constituent IDs and Call authority through typed GM.1
artifacts, and hashes the exact tuple below with the existing `code.hash`
canonical-Code boundary.

---

## 1. Thesis

A membrane is a handler that turns **requested authority** into **governed authority**.

Code inside the membrane cannot speak directly to `Fs`, `Net`, `Pg`, `Secret`, or another raw world effect. It speaks a narrow, typed facade effect such as `Workspace`, `Deploy`, or `Commerce`. The membrane handles that facade. For every operation it:

1. constructs a canonical description of the proposed call;
2. asks a `Judge` for a risk assessment;
3. applies a pure, content-addressed policy;
4. records the decision before any action occurs;
5. executes, simulates, asks for approval, or refuses;
6. records the outcome; and
7. resumes the caller exactly once with an explicit result.

The raw world exists only outside the membrane. The untrusted computation’s row names the virtual powers it may request; the membrane’s outward row names the real powers its drivers may exercise. Handling makes the translation visible:

```text
agent        : () ->{Workspace} Report
workspace.live(agent)
             : () ->{Judge, Approval, Audit, Fs, Net, Secret} Report
workspace.dry-run(agent)
             : () ->{Judge, Audit} Report
```

That pair of signatures is the design in miniature. The live boundary reveals its complete authority. The dry-run boundary has no world authority to misuse. The same agent body is used in both.

This is not a policy engine bolted beside the language. It is ordinary Jacquard code built from typed effects, handlers, rows, affine resumptions, content hashes, code values, semantic diffs, and Warp. The language’s existing invariants do almost all of the security work.

## 2. Why this is Jacquard-shaped

Most agent governance systems intercept strings at a tool API, run policy in a separate service, log prose, and trust conventions to keep the agent from finding another path to the world. Jacquard can make the boundary structural.

* **Rows close the bypass.** A governed body whose row contains `Workspace` but not `Fs` or `Net` cannot directly perform the raw operations. The manifest states the distinction before execution.
* **Handlers perform the translation.** A facade operation is intercepted at the language level, not by monkey-patching a client library. The nearest handler is the authority boundary.
* **Once modes prevent duplicated action.** World operations and facade tool operations are `once`; the membrane receives an affine `Resume` and cannot accidentally charge a card or send a message twice by resuming twice.
* **Hashes make consent precise.** The proposed call, policy, assessment, driver, and exact review artifact can be content-addressed. Approval binds to the immutable proposal ID rather than a mutable name or unbound rendered paragraph.
* **Code values make calls inspectable.** Arguments can be represented as canonical `Code` without introducing a second serialization language.
* **Warp verifies policy laws.** Risk and verdict types are finite. Policy monotonicity, dry-run safety, refusal behavior, and nested-membrane laws can be exhaustively checked rather than sampled.
* **Record/replay and `Fault` verify the boundary.** Approval services, audit sinks, simulators, and world drivers are effects with scripted, replayed, and fault-injected handlers.
* **Semantic diffs make governance reviewable.** A policy or call-spec change is a tree diff with a stable hash. “The agent gained write access” becomes a computed authority diff rather than a changelog claim.

The membrane should therefore remain library code. Adding a privileged kernel sandbox form would duplicate weaker versions of machinery Jacquard already has and would make the boundary less inspectable.

## 3. Terminology and the boundary

The word **tool** is a role, not one universal effect name. Each boundary should declare a domain-specific facade effect with typed operations:

This short declaration omits its carrier types; the complete executable
`Workspace` declaration is pinned by the §8 fixture.

```text
once effect Workspace where
  read-file  : (Path) -> Result ToolError Text
  write-file : (Path, Text) -> Result ToolError ()
  fetch      : (Request) -> Result ToolError Response
```

A universal operation such as `tool.call(name: Text, args: Code) -> Code` would be easy to intercept and bad for everything else: argument and result types disappear, exhaustiveness disappears, operation identity becomes stringly typed, and reviewers cannot distinguish powers in signatures. The shared abstraction is the **gate**, not a dynamically typed mega-effect.

The word **host** is also a role, not a blessed effect. A membrane translates to the existing concrete vocabulary: `Fs`, `Net`, `Pg`, `Blob`, `Secret`, `Serve`, and so on. Introducing a single `Host` effect would erase the exact authority rows were designed to display.

The v0 trusted boundary consists exactly of:

* the canonical membrane implementation and its exact hash;
* the call normalizers and deterministic renderers;
* the chosen `Judge`, `Approval`, and `Audit` handlers;
* the live drivers that perform raw effects;
* the runtime root handlers and their grant configuration.

The governed body, its prompts, and its requested summaries are outside that
trusted set. A simulator is trusted only for the invariant that the dry API
cannot reach a live driver; its fidelity remains evidence to review rather than
part of the trusted computing base. Package names and mutable store names are
not trust anchors: every trusted component is selected by resolved identity or
an exact content hash.

## 4. Exact v0 vocabulary

The governance module owns the following exact constructor shapes. Display
syntax is descriptive, not a parser change. Every schema marked with a
`version` field carries `GovernanceV0`; `Decision` is bound by its proposal ID
and embedded in a versioned audit entry. A future field or constructor change
creates a new content-addressed interface rather than silently reinterpreting
v0 data.

The block is exact schema notation but is not a standalone program because its
opaque carrier declarations and effect interfaces are intentionally omitted.

```text
type GovernanceVersion = GovernanceV0

type Risk =
  | Low
  | Medium
  | High
  | Forbidden

type Verdict =
  | Allow
  | Simulate
  | Ask
  | Block

type ToolError =
  | Blocked(reason: Text)
  | Denied(reason: Text)
  | Escalated(reason: Text)
  | NoSimulation
  | DriverFailed(message: Text)
  | StaleApproval
  | InvalidDecision

type Authority =
  | Effect(effect-id: Hash)
  | Resource(effect-id: Hash, scope: Text, configuration: Hash)

type Call =
  | Call(
      version: GovernanceVersion,
      call-id: Hash,
      operation-id: Hash,
      operation-name: Text,
      arguments: Code,
      authority: List Authority,
      summary: Text,
      preconditions: Code,
      parent-call-id: Option Hash)

type GovernanceAssessment =
  | GovernanceAssessment(
      version: GovernanceVersion,
      risk: Risk,
      confidence: Real,
      reasons: List Text,
      evidence: Code)

type GovernanceOutcomeSummary =
  | GovernanceOutcomeSummary(
      version: GovernanceVersion,
      status: Text,
      digest: Hash,
      detail: Text)

type Proposal =
  | Proposal(
      version: GovernanceVersion,
      proposal-id: Hash,
      call-id: Hash,
      policy-id: Hash,
      assessment-id: Hash,
      rendering: Code,
      summary: Text,
      authority: List Authority,
      preview: Option GovernanceOutcomeSummary)

type Decision =
  | Approved(proposal-id: Hash, approver: Text, evidence: Code)
  | Denied(proposal-id: Hash, approver: Text, reason: Text)
  | Escalate(proposal-id: Hash, reason: Text)

type AuditEntry =
  | Evaluated(
      version: GovernanceVersion,
      sequence: Int,
      call-id: Hash,
      policy-id: Hash,
      assessment: GovernanceAssessment,
      verdict: Verdict)
  | Consented(
      version: GovernanceVersion,
      sequence: Int,
      call-id: Hash,
      proposal-id: Hash,
      decision: Decision)
  | Completed(
      version: GovernanceVersion,
      sequence: Int,
      call-id: Hash,
      branch: Text,
      outcome: GovernanceOutcomeSummary)

type SecretRef =
  | SecretRef(
      version: GovernanceVersion,
      name: Text,
      secret-version: Option Text)
```

`Call.summary` is produced by a trusted deterministic renderer. It is not
agent-authored prose. The binding artifact is `Call.call-id`; the summary is a
reading aid. `Proposal.proposal-id` binds the exact review artifact, including
its deterministic rendering.

`Call.arguments` and `Call.preconditions` are canonical code values. The call
ID is computed from `GovernanceV0`, the operation's resolved identity,
canonical arguments, the operation's transitive raw-authority envelope,
preconditions, and `parent-call-id`. It deliberately excludes presentation
text and the carried `call-id` field. The proposal ID is computed from
`GovernanceV0`, call ID, policy ID, assessment ID, the same authority envelope,
preview, deterministic rendering, and summary, excluding the carried
`proposal-id` field. The governance verifier recomputes both IDs.

`policy-id` hashes `(GovernanceV0, canonical policy value)` and excludes the
carried ID. `assessment-id` hashes the exact versioned `GovernanceAssessment` value.
`Authority.Resource.configuration` hashes the resolved grant configuration
whose scope is being claimed. These inputs use canonical code encoding and
`HASH_V0`; mutable names are never substituted for resolved identities.

Every facade operation freezes one ordered, duplicate-free **raw-authority
envelope** beside its schema. `Workspace.read-file` and
`Workspace.write-file`, for example, declare `Effect(Fs-id)`;
`Workspace.fetch` declares `Effect(Net-id), Effect(Secret-id)`. An effect entry
uses the resolved interface identity, not a display name. A resource entry may
refine one of those effect entries with configured evidence, but never replaces
the effect-level claim. `Call.authority` and `Proposal.authority` must both equal
that envelope byte for byte.

The verifier computes the same envelope from the call-specific action. Raw
effects remain unchanged; a re-performed facade operation expands recursively
through its frozen envelope. Thus an intermediate
`workspace.write-file(path, text)` action and the leaf `fs.write` action both
project to `Effect(Fs-id)`. This transitive expansion is why unchanged nested
forwarding retains one call ID even though only the leaf performs the raw
effect. Dynamic selection among different facade operations in one action is
not accepted in v0; each clause supplies one statically resolved action.

The authority analysis isolates the live/forward action thunk from the gate.
The v0 gate-control set is exactly `Judge`, `Approval`, and `Audit`; those
effects and the continuation row `e` are outside the action and therefore do
not enter its envelope. They are not silently subtracted if performed inside
the action thunk: such an action is rejected. The private sequence `State` is
likewise discharged around the gate, not an authority exclusion. V0 defines no
other authority exclusions. In particular, `Secret` is raw authority and
`Eval` remains prohibited.

```text
code.hash : (Code) ->{} Hash
```

It uses the language’s fixed canonical serializer and `HASH_V0`. This is a stdlib/runtime addition, not a new kernel form.

`Authority.Resource` records a finer grant claim such as a hostname or path and
the hash of the grant configuration that supports it. The type system proves
only effect-level authority. Resource scopes are configured-resource evidence,
never row proofs, and every CLI or UI rendering must label them that way.

## 5. The governance effects

The taxonomy already defines `Approval`, `Audit`, and `Secret`. The membrane’s central `Judge` must also be blessed if the pattern is to be shared vocabulary rather than a different ad-hoc effect in every package.

This operation-only excerpt omits the exact data declarations already frozen
above; the complete executable declarations appear in the §8 fixture.

```text
once effect Judge where
  assess : (Call) -> GovernanceAssessment

once effect Approval where
  ask : (Proposal) -> Decision

once effect Audit where
  record : (AuditEntry) -> ()
```

`Judge` performs assessment, not action. A rules handler can discharge it purely. A model-backed handler may carry `Infer`; a probabilistic handler may carry `Dist`. Those powers appear in the handler’s outward row rather than being hidden inside the word `Judge`.

```text
judge.rules     : (() ->{Judge | e} a) ->{e} a
judge.model     : (() ->{Judge | e} a) ->{Infer | e} a
judge.posterior : (() ->{Judge | e} a) ->{Dist | e} a
```

The v0 `GovernanceAssessment` carries one conservative risk class and a confidence. A posterior-aware representation over the finite `Risk` type is the natural next step, but policy should not pretend a scalar confidence has more meaning than the judge can justify. Section 14 keeps that extension explicit.

### 5.1 Approval as a typed transaction

This repeats the exact proposal/decision schema for review, but omits its
carrier declarations and therefore is not a standalone program.

```text
type Proposal =
  | Proposal(
      version: GovernanceVersion,
      proposal-id: Hash,
      call-id: Hash,
      policy-id: Hash,
      assessment-id: Hash,
      rendering: Code,
      summary: Text,
      authority: List Authority,
      preview: Option GovernanceOutcomeSummary)

type Decision =
  | Approved(proposal-id: Hash, approver: Text, evidence: Code)
  | Denied(proposal-id: Hash, approver: Text, reason: Text)
  | Escalate(proposal-id: Hash, reason: Text)
```

The membrane rejects a decision whose embedded proposal ID does not match the
recomputed proposal ID it asked about. Queue-backed handlers consume approvals
once; reusing an old decision is `StaleApproval`. Console handlers ask every
time. Policy-auto handlers may approve only calls the policy marked `Allow`;
they must not upgrade `Ask` to `Approved` behind the gate.

Approval binding prevents code-change time-of-check/time-of-use failures. It does not freeze the external world. Operations that depend on mutable state must include preconditions such as an ETag, account version, deployment hash, or expected balance in `Call.preconditions`, and the driver must enforce them.

### 5.2 Audit as evidence

The canonical audit stream has three event classes:

This is the exact audit schema excerpt; the complete executable fixture also
supplies all referenced types.

```text
type AuditEntry =
  | Evaluated(
      version: GovernanceVersion, sequence: Int, call-id: Hash,
      policy-id: Hash, assessment: GovernanceAssessment, verdict: Verdict)
  | Consented(
      version: GovernanceVersion, sequence: Int, call-id: Hash,
      proposal-id: Hash, decision: Decision)
  | Completed(
      version: GovernanceVersion, sequence: Int, call-id: Hash,
      branch: Text, outcome: GovernanceOutcomeSummary)
```

`sequence` starts at zero once for the entire governed run and increases by one
only after an accepted `Audit.record` resumes; a refused write leaves it
unchanged. `governance.with-sequence` is the sole owner API: it
installs one `State` handler whose private payload is `(run-id: Hash,
counter: Int)`, creates one run-scoped
`AuditSequence` token, and passes that token to the membrane-layer callback.
The public owner and layer signatures remain unchanged: they expose only the
`State` effect and `Int` sequence positions, never the payload refinement.
Every live or dry layer accepts and threads the same token; no layer initializes
`State`, and nesting a public runner inside another runner is non-conforming.
Nested membranes that write one audit stream are instead assembled inside one
`with-sequence` callback and receive its single token. Separately published
audit streams are separate owner invocations and each begin at zero.
The token constructor and the fresh-id/check marker terms are unavailable
through both their source names and exact derived hashes, and stay hidden after
reopening the Store. Trusted evaluation of the already-resolved owner is the
only construction path. Each `with-sequence` invocation receives a fresh ID;
`next-sequence` and `accept-sequence` compare the token ID with the active
private state before reading or advancing, so returned tokens, cross-owner
reuse, arbitrary `state.run`, and nesting under a different owner fail closed.
`Evaluated` is recorded before approval, simulation, forwarding, or live
execution. When approval is required, `Consented` is recorded after the answer
and before the live driver. `Completed` is recorded after the branch returns.
Duplicate, skipped, or decreasing sequences are rejected by the canonical
audit handler.

The pre-action writes are fail-closed: if they cannot be recorded, the real or forwarded action does not run. A completion-write failure is surfaced but cannot undo an action that already happened; irreversible drivers should return an external receipt or idempotency key so the audit stream can be reconciled. The hash-chain handler links entries and publishes the current head exactly as D58 requires.

Malformed directly represented Call or BoundPolicy carriers are rejected as
`InvalidDecision` before Judge or Audit. This defensive precondition path is
intentionally unaudited: the malformed value has no trustworthy canonical ID to
record. It performs no simulation, summarization, approval, or world action.

Audit renderers never call `debug.inspect` on arbitrary values. Each facade operation supplies a pure, type-specific outcome summarizer. This is more verbose than reflection and is the right default: generic inspection is how secrets enter logs.

### 5.3 Secrets cross by reference

Governed code requests the *use* of a secret, not its contents:

This exact `SecretRef` excerpt omits its referenced carrier declarations.

```text
type SecretRef =
  | SecretRef(
      version: GovernanceVersion,
      name: Text,
      secret-version: Option Text)
```

A call may contain `SecretRef`, which is safe to hash and display. The live driver performs `Secret.read` only after the gate allows the action. The secret value never enters the `Call`, `Proposal`, simulator, or audit stream. A dry-run membrane has no `Secret` row at all.

This arrangement narrows the known limitation of opaque secrets. Once a program legitimately performs `secret.expose`, information-flow control is out of scope; the membrane instead keeps exposure out of the governed body and as late as possible in the driver.

## 6. Policy is data, but execution mode is typed

The taxonomy’s original sketch placed `Live | DryRun` inside one `Policy` value. That is useful for serialization but insufficient as the execution API. Rows are static: a generic function that accepts a live driver still carries the driver’s `Fs` or `Net` row even when a runtime `Mode` happens to be `DryRun`. Such a design would require world grants merely to rehearse a program, and a bug in the branch could touch the world.

The membrane therefore has distinct policy types and distinct entry points:

This exact policy-schema excerpt omits the referenced governance carriers; the
complete executable forms are pinned in §8.

```text
type LivePolicy =
  | LivePolicy(
      version: GovernanceVersion,
      auto-up-to: Risk,
      ask-up-to: Risk,
      min-confidence: Real)

type DryPolicy =
  | DryPolicy(
      version: GovernanceVersion,
      min-confidence: Real)

type StoredPolicy =
  | Live(LivePolicy)
  | DryRun(DryPolicy)

type BoundPolicy a =
  | BoundPolicy(version: GovernanceVersion, policy-id: Hash, value: a)
```

`StoredPolicy` is the file/registry representation. `BoundPolicy` carries the hash to which audits and approvals bind. The execution functions take the specific policy type.

The risk ordering is:

```text
Low < Medium < High < Forbidden
```

Policy construction validates that `auto-up-to <= ask-up-to` and that confidence thresholds lie between `0.0` and `1.0`. Invalid policies never reach the gate.

The pure verdict laws are:

### Live

1. `Forbidden` always yields `Block`.
2. Confidence below `min-confidence` never yields `Allow`; it yields `Ask` when asking is permitted, otherwise `Block`.
3. Risk at or below `auto-up-to` yields `Allow`.
4. Risk above `auto-up-to` and at or below `ask-up-to` yields `Ask`.
5. Higher risk yields `Block`.

### Dry run

1. `Forbidden` yields `Block`.
2. Every other risk yields `Simulate` when a simulator exists.
3. Missing simulation yields an explicit `NoSimulation`; it never falls back to live execution.
4. No path yields `Allow` or performs `Approval.ask`.

These functions are pure over finite values except for the real-valued confidence comparison. Warp exhaustively verifies the risk and threshold ordering over a representative finite confidence grid, and ordinary unit properties cover the numeric boundary cases.

Implementation status (GM.3): `prelude/23-governance-policy.jqd` exposes safe
validation for LivePolicy, DryPolicy, StoredPolicy, and exact BoundPolicy
hashes. The bound live and dry verdict entry points implement these laws as
total `Result ToolError Verdict` functions. Their executable evidence covers
all four risks, all sixteen live threshold pairs (rejecting the six reversed
pairs), four representative observed confidences, both simulator states, and
the finite/non-finite numeric boundaries. This completes D65, D66, and D72 for
the pure policy layer; later gate work consumes these verdicts without changing
their laws.

Implementation status (GM.6): `prelude/24-governance-gate-dry.jqd` consumes
the exact bound dry policy, shared `AuditSequence`, and pure
simulator/summarizer boundary. It returns the frozen `DryDisposition` and does
not accept or export the facade clause's affine continuation. Its closed control
row is exactly `{State, Judge, Audit}`; there is no live closure and no
`Approval`, `Secret`, `Eval`, `Fs`, `Net`, or other world effect. It reserves the
next shared audit position, records `Evaluated`, derives an explicit blocked,
missing-simulation, simulated, or simulation-failed result, reserves the next
position, records `Completed`, and returns the disposition. A refused pre-action
Audit write prevents the simulator and summarizer; a refused completion write
prevents the disposition from returning. The facade clause remains the sole
owner that consumes its local `Resume`. This implements D64-D66 without
replacing the frozen representation below; the workspace facade and live gate
remain later G2 work.

## 7. One gate, two execution APIs

Jacquard v0 rows have at most one tail, and affine `Resume` is not a public type
constructor. The gate therefore does not accept either the raw action or the
continuation. It performs only governance control and returns a typed
disposition; the facade clause then executes the selected raw/forward action or
pure simulation, records completion, and consumes its locally bound `Resume`.
The exact v0 carrier and pseudocode signatures are:

```text
type LiveDisposition = ExecuteLive | RefuseLive(error: ToolError)
type DryDisposition a = Simulated(result: Result ToolError a) | RefuseDry(error: ToolError)

governance.with-sequence :
  forall a | e.
  ((AuditSequence) ->{State | e} a) ->{| e} a

governance.gate-live :
  forall a.
  ( AuditSequence
  , BoundPolicy LivePolicy
  , Call
  , Option (() ->{} Result ToolError a)
  , (Result ToolError a) ->{} GovernanceOutcomeSummary
  ) ->{State, Judge, Approval, Audit} LiveDisposition

governance.gate-dry :
  forall a.
  ( AuditSequence
  , BoundPolicy DryPolicy
  , Call
  , Option (() ->{} Result ToolError a)
  , (Result ToolError a) ->{} GovernanceOutcomeSummary
  ) ->{State, Judge, Audit} DryDisposition a

governance.complete :
  (AuditSequence, Call, Text, GovernanceOutcomeSummary) ->{State, Audit} ()
```

These are ordinary single-tail Jacquard types. `gate-live` and `gate-dry` have
closed control rows; `with-sequence` is the only row-polymorphic owner and
discharges only `State`. A live facade layer has one outward row
`{State, Judge, Approval, Audit, raw-effects | e}`; a dry layer has
`{State, Judge, Audit | e}`. Here the sole tail `e` is the governed body's
remaining continuation row. The call-specific action is literal in the clause,
so its fixed raw effects join that same ordinary clause row by inference rather
than being represented by a second tail. Installing Judge, Approval, and Audit
handlers removes those effects normally; `with-sequence` removes State. No
G0-G4 phase may replace this disposition-and-local-Resume representation.

Every ordinary disposition consumes the clause's `Resume` exactly once:

* `ExecuteLive`: run the live/forward action, summarize, record completion,
  then resume with the result.
* `RefuseLive(error)`: the gate has recorded the refusal; resume with
  `Err(error)`.
* `Simulated(result)`: the gate has run the pure simulator and recorded its
  completion; resume with `result`.
* `RefuseDry(error)`: the gate records refusal and the clause resumes with
  `Err(error)`. `None` produces `NoSimulation` and never reaches a live action.

The default does not silently drop the continuation. A caller that wants refusal to abort can use `tool.require!`, which turns `Result ToolError a` into a visible `Throw ToolError` effect.

This is why facade operations return `Result ToolError a`. If an operation promised an arbitrary `a`, the membrane could not block it without either inventing a value or aborting the whole computation. Explicit refusal keeps the program compositional and makes every denied path testable.

## 8. A complete membrane, in surface syntax

A workspace facade illustrates the pattern. The code is intentionally literal; the shared gate holds the policy mechanics, while each clause keeps normalization and raw authority local and reviewable.

This is exact representation pseudocode: the current surface has no record
syntax for `simulators`, but G2 must implement this disposition API and may not
reintroduce a second action-row tail or export `Resume`.

```text
once effect Workspace where
  read-file  : (Path) -> Result ToolError Text
  write-file : (Path, Text) -> Result ToolError ()
  fetch      : (Request) -> Result ToolError Response

workspace.live-layer(sequence, policy, simulators, body) =
  handle body() {
    | return x -> x

    | read-file(path) resume k -> {
        let call = workspace.call-read(path)
        let preview = match simulators.read-file {
          | None -> None
          | Some(simulator) -> Some(fn () -> simulator(path))
        }
        let disposition = governance.gate-live(
          sequence,
          policy,
          call,
          preview,
          workspace.summarize-read)
        match disposition {
          | ExecuteLive -> {
              let result = Ok(fs.read(path.text))
              governance.complete(sequence, call, "live", workspace.summarize-read(result))
              k(result)
            }
          | RefuseLive(error) -> k(Err(error))
        }
      }

    | write-file(path, text) resume k -> {
        let call = workspace.call-write(path, text)
        let preview = match simulators.write-file {
          | None -> None
          | Some(simulator) -> Some(fn () -> simulator(path, text))
        }
        let disposition = governance.gate-live(
          sequence,
          policy,
          call,
          preview,
          workspace.summarize-write)
        match disposition {
          | ExecuteLive -> {
              fs.write(path.text, text)
              let result = Ok(())
              governance.complete(sequence, call, "live", workspace.summarize-write(result))
              k(result)
            }
          | RefuseLive(error) -> k(Err(error))
        }
      }

    | fetch(request) resume k -> {
        let call = workspace.call-fetch(request)
        let preview = match simulators.fetch {
          | None -> None
          | Some(simulator) -> Some(fn () -> simulator(request))
        }
        let disposition = governance.gate-live(
          sequence,
          policy,
          call,
          preview,
          workspace.summarize-fetch)
        match disposition {
          | ExecuteLive -> {
              let secret = secret.read(SecretRef(GovernanceV0, "workspace", None))
              let exposed = secret.expose(secret)
              let result = match exposed { | _ -> Ok(net.fetch(request)) }
              governance.complete(sequence, call, "live", workspace.summarize-fetch(result))
              k(result)
            }
          | RefuseLive(error) -> k(Err(error))
        }
      }
  }

workspace.dry-layer(sequence, policy, simulators, body) =
  handle body() {
    | return x -> x

    | read-file(path) resume k -> {
        let simulation = match simulators.read-file {
          | None -> None
          | Some(simulator) -> Some(fn () -> simulator(path))
        }
        let disposition = governance.gate-dry(
          sequence,
          policy,
          workspace.call-read(path),
          simulation,
          workspace.summarize-read)
        match disposition {
          | Simulated(result) -> k(result)
          | RefuseDry(error) -> k(Err(error))
        }
      }

    | write-file(path, text) resume k -> {
        let simulation = match simulators.write-file {
          | None -> None
          | Some(simulator) -> Some(fn () -> simulator(path, text))
        }
        let disposition = governance.gate-dry(
          sequence,
          policy,
          workspace.call-write(path, text),
          simulation,
          workspace.summarize-write)
        match disposition {
          | Simulated(result) -> k(result)
          | RefuseDry(error) -> k(Err(error))
        }
      }

    | fetch(request) resume k -> {
        let simulation = match simulators.fetch {
          | None -> None
          | Some(simulator) -> Some(fn () -> simulator(request))
        }
        let disposition = governance.gate-dry(
          sequence,
          policy,
          workspace.call-fetch(request),
          simulation,
          workspace.summarize-fetch)
        match disposition {
          | Simulated(result) -> k(result)
          | RefuseDry(error) -> k(Err(error))
        }
      }
  }

workspace.live(policy, simulators, body) =
  governance.with-sequence(fn (sequence) ->
    workspace.live-layer(sequence, policy, simulators, body))

workspace.dry-run(policy, simulators, body) =
  governance.with-sequence(fn (sequence) ->
    workspace.dry-layer(sequence, policy, simulators, body))
```

The live fetch action deliberately resolves the ratified `SecretRef` and
performs both `secret.read` and `secret.expose` before `net.fetch`. The
provider-neutral match sequences those effects without specifying how any
particular network provider consumes exposed text; G2 must supply that detail
at its typed driver boundary. The action therefore derives `{Net, Secret}` and
matches the frozen `Workspace.fetch` envelope carried by both `Call.authority`
and `Proposal.authority`. Dry simulators continue to receive only safe request
data, never `Secret` material, and the pure outcome summarizer receives only
the typed fetch result.

The important omission from `workspace.dry-run` is the live driver. There is no dead branch containing `fs.write` and no closure whose row mentions `Fs`. The checker, not the policy author’s discipline, proves the rehearsal cannot touch the filesystem or network.

The v0 live layer and its run-level owner have these signatures:

```text
workspace.live-layer :
  forall a | e.
  ( AuditSequence
  , BoundPolicy LivePolicy
  , WorkspaceSimulators
  , () ->{Workspace | e} a
  ) ->{State, Judge, Approval, Audit, Fs, Net, Secret | e} a

workspace.live :
  forall a | e.
  ( BoundPolicy LivePolicy
  , WorkspaceSimulators
  , () ->{Workspace | e} a
  ) ->{Judge, Approval, Audit, Fs, Net, Secret | e} a
```

The v0 dry layer likewise exposes `State` only to its owner:

```text
workspace.dry-layer :
  forall a | e.
  ( AuditSequence
  , BoundPolicy DryPolicy
  , WorkspaceSimulators
  , () ->{Workspace | e} a
  ) ->{State, Judge, Audit | e} a

workspace.dry-run :
  forall a | e.
  ( BoundPolicy DryPolicy
  , WorkspaceSimulators
  , () ->{Workspace | e} a
  ) ->{Judge, Audit | e} a
```

`workspace.live` and `workspace.dry-run` each call `with-sequence` exactly once.
Composition code that publishes one audit stream instead calls
`with-sequence` once around all nested `*-layer` calls and threads its one
`AuditSequence` token through them. After wrapping `Judge` and `Audit` with
pure/scripted handlers, the dry-run is empty-row and cacheable by Warp.

The checked `governed-membrane-signatures` fixture below is the executable
surface contract for the run-level sequence owner, layer APIs, `agent`,
`workspace.live`, and `workspace.dry-run`. It uses small carrier declarations
and literal handler clauses only to make the checker elaborate these rows; the
disposition gate representation above is already frozen for G2.

```jacquard doctest=governed-membrane-signatures mode=check fixture=governed-membrane-signatures.jac stdout=governed-membrane-signatures.stdout stderr=empty exit=0
type GovernanceVersion = | GovernanceV0
type Hash = | HashValue(value: Text)
type Path = | PathValue(value: Text)
type AuditSequence = | AuditSequence(run-id: Hash)
type WorkspaceOperation = | ReadFileOperation | WriteFileOperation | FetchOperation
type SecretRef =
  | SecretRef(
      version: GovernanceVersion,
      name: Text,
      secret-version: Option Text)
type Secret = | OpaqueSecret

type Risk = | Low | Medium | High | Forbidden
type Verdict = | Allow | Simulate | Ask | Block
type ToolError =
  | Blocked(reason: Text)
  | Denied(reason: Text)
  | Escalated(reason: Text)
  | NoSimulation
  | DriverFailed(message: Text)
  | StaleApproval
  | InvalidDecision
type Authority =
  | Effect(effect-id: Hash)
  | Resource(effect-id: Hash, scope: Text, configuration: Hash)
type Call =
  | Call(
      version: GovernanceVersion,
      call-id: Hash,
      operation-id: Hash,
      operation-name: Text,
      arguments: Code,
      authority: List Authority,
      summary: Text,
      preconditions: Code,
      parent-call-id: Option Hash)
type GovernanceAssessment =
  | GovernanceAssessment(
      version: GovernanceVersion,
      risk: Risk,
      confidence: Real,
      reasons: List Text,
      evidence: Code)
type GovernanceOutcomeSummary =
  | GovernanceOutcomeSummary(
      version: GovernanceVersion,
      status: Text,
      digest: Hash,
      detail: Text)
type Proposal =
  | Proposal(
      version: GovernanceVersion,
      proposal-id: Hash,
      call-id: Hash,
      policy-id: Hash,
      assessment-id: Hash,
      rendering: Code,
      summary: Text,
      authority: List Authority,
      preview: Option GovernanceOutcomeSummary)
type Decision =
  | Approved(proposal-id: Hash, approver: Text, evidence: Code)
  | Denied(proposal-id: Hash, approver: Text, reason: Text)
  | Escalate(proposal-id: Hash, reason: Text)
type AuditEntry =
  | Evaluated(
      version: GovernanceVersion,
      sequence: Int,
      call-id: Hash,
      policy-id: Hash,
      assessment: GovernanceAssessment,
      verdict: Verdict)
  | Consented(
      version: GovernanceVersion,
      sequence: Int,
      call-id: Hash,
      proposal-id: Hash,
      decision: Decision)
  | Completed(
      version: GovernanceVersion,
      sequence: Int,
      call-id: Hash,
      branch: Text,
      outcome: GovernanceOutcomeSummary)

type LivePolicy =
  | LivePolicy(
      version: GovernanceVersion,
      auto-up-to: Risk,
      ask-up-to: Risk,
      min-confidence: Real)
type DryPolicy =
  | DryPolicy(version: GovernanceVersion, min-confidence: Real)
type BoundPolicy a =
  | BoundPolicy(version: GovernanceVersion, policy-id: Hash, value: a)

once effect Judge where {
  judge.assess : (Call) -> GovernanceAssessment
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
once effect Workspace where {
  workspace.read-file : (Path) -> Result ToolError Text
  workspace.write-file : (Path, Text) -> Result ToolError ()
  workspace.fetch : (Request) -> Result ToolError Response
}

fixture-hash = HashValue("fixture-v0")

operation-name-of(operation) = match operation {
  | ReadFileOperation -> "workspace.read-file"
  | WriteFileOperation -> "workspace.write-file"
  | FetchOperation -> "workspace.fetch"
}

call-id-for(operation) = HashValue(operation-name-of(operation))

authority-for(operation) = match operation {
  | ReadFileOperation -> [Effect(HashValue("effect:Fs"))]
  | WriteFileOperation -> [Effect(HashValue("effect:Fs"))]
  | FetchOperation ->
      [Effect(HashValue("effect:Net")), Effect(HashValue("effect:Secret"))]
}

call-for(operation) = {
  let operation-name = operation-name-of(operation)
  Call(
    GovernanceV0,
    call-id-for(operation),
    HashValue(operation-name),
    operation-name,
    quote {()},
    authority-for(operation),
    operation-name,
    quote {()},
    None)
}

proposal-for(operation) =
  Proposal(
    GovernanceV0,
    fixture-hash,
    call-id-for(operation),
    fixture-hash,
    fixture-hash,
    quote {()},
    "fixture proposal",
    authority-for(operation),
    None)

outcome-for(branch) =
  GovernanceOutcomeSummary(GovernanceV0, branch, fixture-hash, "fixture outcome")

run-read-simulator : ((Path) ->{} Result ToolError Text, Path) ->{} Result ToolError Text
run-read-simulator(simulator, path) = simulator(path)

run-write-simulator : ((Path, Text) ->{} Result ToolError (), Path, Text) ->{} Result ToolError ()
run-write-simulator(simulator, path, text) = simulator(path, text)

run-fetch-simulator : ((Request) ->{} Result ToolError Response, Request) ->{} Result ToolError Response
run-fetch-simulator(simulator, request) = simulator(request)

next-sequence : (AuditSequence) ->{State} Int
next-sequence(owner) = match owner {
  | AuditSequence(_) -> get()
}

accept-sequence : (AuditSequence) ->{State} ()
accept-sequence(owner) = match owner {
  | AuditSequence(_) -> put(add(get(), 1))
}

agent() = {
  let first = workspace.read-file(PathValue("README.md"))
  let second = workspace.read-file(PathValue("docs/README.md"))
  match second { | _ -> first }
}

workspace.live-layer : (AuditSequence, BoundPolicy LivePolicy, Option ((Path) ->{} Result ToolError Text), Option ((Path, Text) ->{} Result ToolError ()), Option ((Request) ->{} Result ToolError Response)) ->{State, Judge, Approval, Audit, Fs, Net, Secret} Result ToolError Text
workspace.live-layer(sequence, policy, read-simulator, write-simulator, fetch-simulator) =
  handle agent() {
    | return result -> result
    | workspace.read-file(path) resume continue -> {
        let request-call = call-for(ReadFileOperation)
        let request-id = call-id-for(ReadFileOperation)
        let judgment = judge.assess(request-call)
        let evaluated-sequence = next-sequence(sequence)
        audit.record(Evaluated(GovernanceV0, evaluated-sequence, request-id, fixture-hash, judgment, Ask))
        accept-sequence(sequence)
        let decision = approval.ask(proposal-for(ReadFileOperation))
        let consented-sequence = next-sequence(sequence)
        audit.record(Consented(GovernanceV0, consented-sequence, request-id, fixture-hash, decision))
        accept-sequence(sequence)
        let result = match path { | PathValue(raw) -> Ok(read(raw)) }
        let completed-sequence = next-sequence(sequence)
        audit.record(Completed(GovernanceV0, completed-sequence, request-id, "live", outcome-for("live")))
        accept-sequence(sequence)
        continue(result)
      }
    | workspace.write-file(path, text) resume continue -> {
        let request-call = call-for(WriteFileOperation)
        let request-id = call-id-for(WriteFileOperation)
        let judgment = judge.assess(request-call)
        let evaluated-sequence = next-sequence(sequence)
        audit.record(Evaluated(GovernanceV0, evaluated-sequence, request-id, fixture-hash, judgment, Ask))
        accept-sequence(sequence)
        let decision = approval.ask(proposal-for(WriteFileOperation))
        let consented-sequence = next-sequence(sequence)
        audit.record(Consented(GovernanceV0, consented-sequence, request-id, fixture-hash, decision))
        accept-sequence(sequence)
        let result = match path { | PathValue(raw) -> { write(raw, text); Ok(()) } }
        let completed-sequence = next-sequence(sequence)
        audit.record(Completed(GovernanceV0, completed-sequence, request-id, "live", outcome-for("live")))
        accept-sequence(sequence)
        continue(result)
      }
    | workspace.fetch(request) resume continue -> {
        let request-call = call-for(FetchOperation)
        let request-id = call-id-for(FetchOperation)
        let judgment = judge.assess(request-call)
        let evaluated-sequence = next-sequence(sequence)
        audit.record(Evaluated(GovernanceV0, evaluated-sequence, request-id, fixture-hash, judgment, Ask))
        accept-sequence(sequence)
        let decision = approval.ask(proposal-for(FetchOperation))
        let consented-sequence = next-sequence(sequence)
        audit.record(Consented(GovernanceV0, consented-sequence, request-id, fixture-hash, decision))
        accept-sequence(sequence)
        let secret = secret.read(SecretRef(GovernanceV0, "workspace", None))
        let exposed = secret.expose(secret)
        let result = match exposed { | _ -> Ok(fetch(request)) }
        let completed-sequence = next-sequence(sequence)
        audit.record(Completed(GovernanceV0, completed-sequence, request-id, "live", outcome-for("live")))
        accept-sequence(sequence)
        continue(result)
      }
  }

workspace.dry-layer : (AuditSequence, BoundPolicy DryPolicy, Option ((Path) ->{} Result ToolError Text), Option ((Path, Text) ->{} Result ToolError ()), Option ((Request) ->{} Result ToolError Response)) ->{State, Judge, Audit} Result ToolError Text
workspace.dry-layer(sequence, policy, read-simulator, write-simulator, fetch-simulator) =
  handle agent() {
    | return result -> result
    | workspace.read-file(path) resume continue -> {
        let request-call = call-for(ReadFileOperation)
        let request-id = call-id-for(ReadFileOperation)
        let judgment = judge.assess(request-call)
        let evaluated-sequence = next-sequence(sequence)
        audit.record(Evaluated(GovernanceV0, evaluated-sequence, request-id, fixture-hash, judgment, Simulate))
        accept-sequence(sequence)
        let result = match read-simulator {
          | None -> Err(NoSimulation)
          | Some(simulator) -> run-read-simulator(simulator, path)
        }
        let completed-sequence = next-sequence(sequence)
        audit.record(Completed(GovernanceV0, completed-sequence, request-id, "simulated", outcome-for("simulated")))
        accept-sequence(sequence)
        continue(result)
      }
    | workspace.write-file(path, text) resume continue -> {
        let request-call = call-for(WriteFileOperation)
        let request-id = call-id-for(WriteFileOperation)
        let judgment = judge.assess(request-call)
        let evaluated-sequence = next-sequence(sequence)
        audit.record(Evaluated(GovernanceV0, evaluated-sequence, request-id, fixture-hash, judgment, Simulate))
        accept-sequence(sequence)
        let result = match write-simulator {
          | None -> Err(NoSimulation)
          | Some(simulator) -> run-write-simulator(simulator, path, text)
        }
        let completed-sequence = next-sequence(sequence)
        audit.record(Completed(GovernanceV0, completed-sequence, request-id, "simulated", outcome-for("simulated")))
        accept-sequence(sequence)
        continue(result)
      }
    | workspace.fetch(request) resume continue -> {
        let request-call = call-for(FetchOperation)
        let request-id = call-id-for(FetchOperation)
        let judgment = judge.assess(request-call)
        let evaluated-sequence = next-sequence(sequence)
        audit.record(Evaluated(GovernanceV0, evaluated-sequence, request-id, fixture-hash, judgment, Simulate))
        accept-sequence(sequence)
        let result = match fetch-simulator {
          | None -> Err(NoSimulation)
          | Some(simulator) -> run-fetch-simulator(simulator, request)
        }
        let completed-sequence = next-sequence(sequence)
        audit.record(Completed(GovernanceV0, completed-sequence, request-id, "simulated", outcome-for("simulated")))
        accept-sequence(sequence)
        continue(result)
      }
  }

governance.with-sequence(body) = {
  let handled = state.run(fn () -> body(AuditSequence(fixture-hash)), 0)
  match handled { | (result, _) -> result }
}

workspace.live(policy, read-simulator, write-simulator, fetch-simulator) =
  governance.with-sequence(fn (sequence) ->
    workspace.live-layer(sequence, policy, read-simulator, write-simulator, fetch-simulator))

workspace.dry-run(policy, read-simulator, write-simulator, fetch-simulator) =
  governance.with-sequence(fn (sequence) ->
    workspace.dry-layer(sequence, policy, read-simulator, write-simulator, fetch-simulator))
```

The fixture's agent performs two facade calls in one invocation.
`governance.with-sequence` installs `state.run` once and passes one
`AuditSequence` to `workspace.live-layer` or `workspace.dry-layer`. The live
audit positions are `0, 1, 2` for the first call and `3, 4, 5` for the second;
the dry positions are `0, 1` and `2, 3`. The checked layer signatures retain
`State`, while the public `workspace.live` and `workspace.dry-run` signatures
prove that the sole owner discharges it. A layer-local owner, per-clause
literal, or per-operation counter reset is not a conforming D69
implementation.

## 9. Simulation is evidence, not consent

A simulator answers “what would this driver return under this model?” It does not answer “may the live action occur?” The design keeps those claims apart.

Simulation laws:

1. A dry-run membrane contains no live driver and no world effects in its row.
2. A simulator passed to `gate-dry` is pure after its fixture handlers are installed. `State`, `Fault`, `Dist`, or scripted world effects may be used internally, but they must be discharged before reaching the gate.
3. A missing simulator refuses explicitly. It never falls through to live.
4. Simulation outcomes are labeled `Simulated` in audit entries and UI.
5. A simulated success never creates an `Approved` decision or reusable approval token.
6. Live `Ask` flows may run the pure simulator first and include its digest as a preview in the proposal. The preview remains non-binding.
7. Simulator fidelity is not a type-level guarantee. Its definition hash, fixtures, model hash, and test evidence should travel with the preview so a reviewer can judge what the rehearsal actually covered.

The existing mandated dry-run `Approval` handler still answers `Escalate` for approval calls made elsewhere in a program. The canonical membrane dry-run never performs `Approval.ask` at all, which is stronger.

`fault.all` and schedule enumeration later make simulation especially useful: a preview can summarize every bounded failure world or interleaving rather than one happy-path rehearsal. The proposal then cites the world-set hash and its aggregate outcome instead of attaching unstructured logs.

## 10. Call identity and review artifacts

A call’s identity must cover what changes its meaning and exclude what merely changes its presentation.

`Call.call-id` hashes a canonical code value containing:

* `GovernanceV0`;
* resolved facade effect and operation identity;
* canonical argument values or safe references;
* the operation's transitive raw-authority envelope;
* external preconditions;
* `parent-call-id`, which is `None` for an original request.

It excludes:

* spans, comments, and provenance metadata;
* rendered summaries;
* timestamps and transient request IDs;
* secret contents.

`Proposal.proposal-id` then hashes:

```text
(GovernanceV0, call ID, policy ID, assessment ID, authority,
 preview, deterministic rendering, summary)
```

An approval binds to that proposal ID. Changing the policy, risk evidence,
authority, preconditions, call arguments, rendering, or summary produces a
different proposal and requires a new decision. Rewording the summary does not
change the call ID but does change the proposal ID. The frozen split is:

* `Call.call-id`: semantic action identity;
* `Proposal.proposal-id`: exact review artifact identity, including rendering.

Tooling displays both. A reviewer approves the proposal ID; audit and replay
can still group attempts by call ID.

This is the same two-level identity move the package manager uses for implementation and interface hashes: one identity for meaning, one for the review surface that was actually shown.

`BoundPolicy` and `Call` constructors are used only inside the canonical governance module and trusted facade normalizers. Since Jacquard does not yet provide module-level constructor privacy, `jac governance check` verifies that the carried hash matches the canonical encoding of the value. Supplying an arbitrary hash is a build failure, not an accepted convention.

## 11. Membranes compose by forwarding

Jacquard’s handler semantics make layered governance unusually clean. An operation-clause body runs outside the handler that caught the operation. Therefore re-performing the same facade operation from the clause forwards it to the next outer membrane rather than recursing into the current one.

An inner project policy can allow a call and forward it to an outer company policy:

This is a partial forwarding equation; it intentionally omits carrier and gate
definitions and is not a standalone surface program.

```text
project-layer(sequence, policy, body) =
  handle body() {
    | return x -> x
    | write-file(path, text) resume k -> {
        let call = workspace.call-write(path, text)
        let disposition = governance.gate-live(
          sequence,
          policy,
          call,
          Some(fn () -> project-sim.write-file(path, text)),
          workspace.summarize-write)
        match disposition {
          | ExecuteLive -> {
              let result = workspace.write-file(path, text)
              governance.complete(sequence, call, "forwarded", workspace.summarize-write(result))
              k(result)
            }
          | RefuseLive(error) -> k(Err(error))
        }
      }
  }

governance.with-sequence(fn (sequence) ->
  company-layer(sequence, company-policy, fn () ->
    project-layer(sequence, project-policy, body)))
```

The `workspace.write-file(...)` action forwards because it executes in the
clause body outside `project-layer`. An outer membrane catches it. Only the
leaf membrane translates it to `Fs.write`. Both nested layers receive the
single `AuditSequence` token created by the surrounding owner, so their audit
entries share one monotonically increasing stream.

This gives four properties without a separate policy-composition engine:

* **Nearest policy first.** The innermost boundary sees the request first.
* **Monotone tightening.** An inner block prevents forwarding; an inner allow cannot force an outer allow. Nesting can only preserve or reduce authority.
* **Independent evidence.** Each layer records its policy ID and verdict against the same call ID. Its proposal binds the same raw-authority envelope but normally has a different proposal ID because policy and assessment are layer-specific.
* **Replaceable organizations.** Project, tenant, company, and host policies are ordinary nested handlers, not one global ruleset.

Unchanged forwarding reconstructs the exact same `Call`, including authority
and `parent-call-id`, so its call ID is stable across layers. A layer that
rewrites arguments is not merely a policy layer: it creates a new `Call`, sets
`parent-call-id = Some(previous-call-id)`, and recomputes the ID. The call
artifact and audit evidence thereby carry explicit lineage. Silent mutation or
changing the authority envelope while retaining the old call ID is forbidden.

## 12. Static verification and tooling

The type checker proves the broad boundary; a governance verifier checks the cross-artifact details the ordinary type system cannot express.

### 12.1 Checker obligations

* Facade effects and their operations are `once`.
* A membrane clause’s `Resume` obeys the affine discipline.
* The governed body has no direct raw effects unless explicitly admitted in its row.
* `gate-dry` receives only pure simulator thunks, and `workspace.dry-run` has no world, `Approval`, `Secret`, or `Eval` effects.
* Every layer accepts an `AuditSequence`; only `governance.with-sequence` installs and discharges its private `State` counter.
* `Secret` values do not flow into types that have `Show` or generic audit renderers.

### 12.2 Governance verifier

A `jac governance check` pass, or an equivalent checker lane, verifies:

* `Call.authority` and `Proposal.authority` equal the operation's frozen raw-authority envelope;
* transitive expansion of the call-specific live/forward action produces that same envelope;
* the gate-owned `Judge`, `Approval`, and `Audit` effects and the locally consumed continuation are outside the action projection; no effect inside the action is silently excluded;
* every facade operation has both a live clause and a dry-run clause;
* every clause obtains a canonical disposition before invoking a driver and records completion before consuming its local `Resume`;
* one `with-sequence` owner surrounds every set of nested layers that publishes one audit stream, and every such layer receives the owner's exact token;
* summaries and outcome renderers are pure;
* call normalizers are pure and hash-stable;
* no call spec serializes `Secret` values rather than `SecretRef`;
* every `Ask` proposal includes call, policy, assessment, and authority hashes;
* unchanged forwarding retains the exact call ID, while a transformed call has `parent-call-id = Some(previous-call-id)` and a new ID;
* a `BoundPolicy` hash equals the canonical hash of its policy value;
* a `Call.call-id` equals the canonical hash of its semantic call encoding;
* a `Proposal.proposal-id` equals the canonical hash of its exact review encoding.

The authority-list equality is important. Runtime proposal data is useful to
humans, but a manually written list can lie. The verifier expands facade
operations in the action through their frozen envelopes, compares the result
to both authority lists, and fails the build on disagreement. Resource entries
remain configured evidence and are checked against configuration, never
inferred from a row.

### 12.3 Review surfaces

* `jac why-effect Fs` points to the leaf membrane driver that introduces it, not merely to the agent function that requested `Workspace`.
* `jac governance explain <proposal-id>` renders the call, assessment, policy rule, approval, driver hash, and audit entries as one decision chain.
* `jac governance verify-log <head>` verifies the hash chain offline.
* Package upgrade plans classify new facade operations, widened raw driver rows, policy changes, and simulator changes separately.
* The playground renders the pipeline as `request -> assessment -> verdict -> consent -> action/simulation -> outcome`, with every box linked to its hash.
* Semantic diff treats a policy threshold change as code, because it is code.

## 13. Threat model and honest limits

### The membrane protects against

* governed code directly reaching raw effects absent from its row;
* accidental or malicious double-resume of resource-bearing operations;
* approval of one call followed by execution of changed arguments or policy;
* live fallback from a failed or missing simulation;
* simulated consent being mistaken for live approval;
* unlogged execution when the pre-action audit cannot be written;
* accidental secret disclosure through generic rendering;
* silent authority growth in a driver or package upgrade;
* one policy layer weakening an outer policy through ordinary nesting.

### The membrane does not protect against

* a malicious or buggy membrane implementation, call normalizer, driver, judge, approval handler, or root handler;
* data-influence and confused-deputy attacks inside an authority the policy legitimately grants;
* a misleading but deterministic summary unless reviewers inspect or replace the trusted renderer;
* stale external state unless the call carries and the driver enforces preconditions;
* replayed approval unless the approval handler enforces single use;
* simulator or model mismatch with reality;
* exfiltration after a secret has been explicitly exposed;
* covert channels, timing channels, or denial of service;
* resource scopes that the current effect-row type system cannot express.

One current language caveat fixes an absolute v0 boundary: `eval` runs
constructed code at root authority and bypasses interposed handlers. A
governed body whose elaborated row contains `Eval` is rejected before membrane
execution, even if another handler appears to discharge `Eval` syntactically.
Neither a live nor dry API may accept an eval-bearing body. The rule can change
only in a new charter after eval inherits the current handler environment or
uses an explicit scoped authority value.

## 14. Uncertainty-aware judgment (deferred to G5)

The v0 gate consumes one conservative `Risk` plus confidence. Posterior risk,
belief distributions, model-backed judges, and uncertainty rules are not part
of G0-G4 acceptance and make no v0 claim. They belong only to G5. Jacquard can
go further without changing the membrane shape.

A posterior judge can define:

```text
risk : (Call) ->{Dist} Risk
```

and use exact enumeration or another inference handler to produce a finite belief over `Low | Medium | High | Forbidden`. The policy then chooses a conservative bound, for example the lowest class whose upper-tail mass is below a configured tolerance. With tolerance `0.0`, any possible higher-risk world raises the effective risk; with a nonzero tolerance, the policy states its accepted uncertainty numerically.

This should land only with explicit semantics. A likely v1 vocabulary is:

These are future schema sketches, not v0 declarations or a complete program.

```text
type RiskBelief =
  | RiskBelief(low: Real, medium: Real, high: Real, forbidden: Real)

type UncertaintyRule =
  | WorstCase
  | UpperTail(max-mass: Real)
  | AlwaysAskBelow(confidence: Real)
```

The important law is already fixed: uncertainty can tighten a verdict or escalate it; it never silently lowers risk. A point estimate with low confidence cannot auto-allow a call.

This is the concrete bridge between permission review and uncertainty review: the same proposal says both what the program wants to do and how strongly the system believes the action belongs in each risk class. The audit record pins the inference handler, evidence, and posterior hash so that conclusion can be replayed.

## 15. Verification plan

Warp receives a dedicated governance suite.

### Pure exhaustive properties

* Risk monotonicity: increasing risk never loosens a verdict.
* Confidence monotonicity: decreasing confidence never changes `Ask` or `Block` into `Allow`.
* Forbidden absorption: `Forbidden` always blocks.
* Dry-run totality: dry policy never yields `Allow` or `Ask`.
* Policy tightening: lowering thresholds never increases the allowed set.
* Call ID stability: metadata, formatting, and summary changes do not alter the semantic call ID.
* Call ID sensitivity: operation, arguments, authority, or preconditions do.
* Policy binding: changing a bound policy value without changing its hash is rejected.

### Handler and world properties

* `Allow` invokes the live driver exactly once and resumes exactly once.
* `Block`, `Denied`, `Escalate`, and `NoSimulation` invoke it zero times.
* Dry-run invokes no live driver under any risk or confidence case.
* The first audit entry precedes every driver event.
* An audit failure before action prevents the action.
* A stale or mismatched approval never reaches the driver.
* A live approval cannot be replayed under the queue handler.
* No audit transcript contains fixed secret fixture contents.
* Nested membranes are monotone over every pair of finite policies.
* Re-performing in a clause reaches the outer membrane exactly once.

### Fault and replay lanes

`fault.all` explores audit-write failure, approval-service failure, simulator failure, driver failure, and completion-write failure at each call site. The record/replay lane pins the exact interaction sequence among `Judge`, `Audit`, `Approval`, and raw effects. Native and interpreter executions must remain byte-identical for all flagship cases.

The demo’s acceptance statement should be stronger than “the policy seems to work”:

> For every risk class, confidence band, approval answer, and single injected infrastructure failure, the call is either refused or simulated, or executed at most once, and every executable path has a pre-action audit record.

That statement is finite and testable.

## 16. Flagship demo

The demo should be an agent operating a workspace and deployment target, large enough to feel real and small enough to read in one sitting.

The unchanged agent performs a sequence such as:

1. read a deployment manifest;
2. fetch a build artifact;
3. write a generated config;
4. request a deployment;
5. read a secret by reference only in the live driver.

Run it four ways:

* dry-run with pure simulators and no grants;
* live under a permissive project membrane and a stricter organization membrane;
* live with an approval queue scripted to deny the deployment;
* `fault.all` over audit, approval, network, and deployment failures.

The transcript shows:

* the agent’s row contains only facade effects;
* the dry-run row is world-free;
* the live row reveals exact raw powers;
* the exact `policy-id` and `proposal-id` values;
* an approval bound to the exact deployment proposal ID;
* the same call passing one membrane and being blocked by the next;
* a verified audit-chain head;
* a semantic policy diff that changes the outcome without changing the agent.

This should sit beside the hostile capability demo and the uncertainty demos. It is the point where authority, uncertainty, identity, simulation, and review all appear in one executable artifact.

## 17. Phasing

GM.0 freezes every implementation choice needed by G0-G4. Those phases may
still discover ordinary implementation defects, but they may not substitute a
different record shape, identity rule, mode API, refusal convention, audit
order, secret rule, nesting rule, or Eval boundary without a new indexed
decision. The phase deliverables are:

**G0 — Pure governance core (small).** Add `Risk`, policies, verdicts, calls, assessment, proposal/decision types, canonical call encoding, and `code.hash`. Exhaustive policy and hash properties land here. No world effects.

**G1 — Governance effects (medium).** Add blessed `Judge` plus the already planned `Approval`, `Audit`, and `Secret` handlers: rules/fixed judges, scripted and dry approval handlers, in-memory audit, hash-chain audit, fixed secrets. Pin interface hashes and risk renderings.

**G2 — Gate and reference membrane (medium).** Implement `gate-live`, `gate-dry`, the explicit refusal convention, authority verifier, and one `Workspace` facade with live and pure simulated drivers. Land the affine `Resume` integration after linearity L2.

**G3 — Composition and evidence (medium).** Nested forwarding membranes, queue-backed single-use approvals, audit verification, record/replay, and the full Warp hostile lane.

**G4 — Product surfaces (small).** Flagship demo, cookbook chapter, `governance explain`, `why-effect` call-chain rendering, package authority diffs, and playground decision-chain view.

**G5 — Uncertainty judgment (research-sized).** Posterior risk beliefs, conservative uncertainty rules, model/inference-backed judges, and exact replay of assessment evidence. This phase is deliberately separate from the security-critical deterministic core.

Dependencies: taxonomy T0/T1 before G1; linearity L1/L2 before G2; surface syntax is not semantically required but should land before the public demo so the membrane remains readable.

### G0-G4 contract closure

There are no unresolved normative choices in the G0-G4 boundary:

* G0 implements the exact versioned records, canonical ID inputs, policy types,
  and policy validation frozen here.
* G1 implements the exact governance-effect operation schemas and pins their
  interface hashes when those interfaces ship.
* G2 implements the exact `LiveDisposition`/`DryDisposition` gate signatures,
  local-`Resume` clause representation, `Result ToolError` refusal convention,
  distinct live and dry APIs, pure-simulator rule, no-fallback rule, and
  absolute governed-`Eval` rejection without introducing a second row tail.
* G3 implements facade forwarding, parent-call lineage, monotonic nesting,
  single-use approvals, and the frozen `with-sequence` owner/token API without
  changing the schemas.
* G4 renders the two distinct IDs and configured-resource evidence. It does
  not reinterpret a resource claim as proof from an elaborated effect row.

G5 may add posterior judgment as a separately versioned extension. It cannot
silently change a v0 assessment or policy decision.

## 18. Decisions

| ID  | decision          | default                                                                                                                                                    |
| --- | ----------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| D61 | facade shape      | domain-specific typed facade effects; no universal stringly `Tool.call`                                                                                    |
| D62 | raw authority     | “host” is a role; membranes re-perform concrete blessed world effects, never an opaque `Host` effect                                                       |
| D63 | Judge status      | bless `Judge` as a once governance effect with `assess : Call -> GovernanceAssessment`                                                                               |
| D64 | refusal semantics | facade operations return `Result ToolError a`; the gate returns a disposition and the facade clause consumes its local `Resume` exactly once on ordinary paths                 |
| D65 | execution modes   | separate live and dry-run policy types and entry points; dry-run accepts no live driver and carries no world, `Approval`, or `Secret` row                  |
| D66 | simulation        | simulator is explicit and pure at the gate; missing simulation refuses and never falls back live                                                           |
| D67 | identity          | call ID binds resolved operation, arguments, transitive raw-authority envelope, preconditions, and optional parent call; proposal ID binds call, policy, assessment, the same envelope, preview, rendering, and summary |
| D68 | authority claims  | each facade operation freezes a raw envelope; transitive expansion of its live/forward action must equal both authority lists; only gate-owned `Judge`/`Approval`/`Audit` and continuation `e` sit outside the action; resources are configured evidence, never row proofs |
| D69 | audit ordering    | one `with-sequence` owner and `AuditSequence` token span every operation and nested layer in a published stream; the counter starts at zero and rejects duplicate, skipped, or decreasing values; `Evaluated` and `Consented` precede action and `Completed` follows it |
| D70 | secret handling   | calls carry versioned `SecretRef` values, never secret material; resolution happens only inside an allowed live driver                                      |
| D71 | composition       | unchanged re-performance preserves the Call and call ID; transformed calls bind `parent-call-id` and get a new ID; transitive envelopes make intermediate and leaf authority agree; nesting may only tighten |
| D72 | uncertainty       | under-confidence never auto-allows; posterior risk is a later explicit phase, not hidden inside v0 policy                                                  |
| D73 | eval boundary     | governed bodies carrying `Eval` are rejected until eval respects scoped or interposed authority                                                            |

## 19. What this document changes

It refines three earlier sketches without changing their direction:

1. The taxonomy’s `Policy(mode, ...)` remains a useful stored value, but live and dry execution use separate types and APIs so the row proves dry-run safety.
2. Any earlier taxonomy or planning shorthand written as generic `Tool -> Host`
   is superseded. `Tool` and `Host` are roles only: executable interfaces use
   domain-specific typed facade effects and translate them to concrete blessed
   world effects. There is no `Tool` or `Host` effect in v0.
3. `Judge`, already load-bearing in the canonized pattern, joins the blessed governance vocabulary rather than remaining an unnamed user effect.

Everything else is the existing language used deliberately. No kernel form, ambient privilege, policy DSL, sandbox runtime, general linear type system, or second audit serialization is introduced. That restraint is the strongest part of the design: the membrane is impressive because Jacquard already had the right pieces.
