# Governed Membranes Limits

These limits are part of the GM.22 public claim, not future-work footnotes.
The release is deterministic governance for the frozen typed Workspace v0
facade, implemented as an evidence-backed research reference. It is not a
production security boundary or an operating-system sandbox.

## Trusted-component failures

The membrane cannot protect against a malicious, compromised, or buggy
checker, runtime, canonical membrane, call normalizer, deterministic renderer,
policy, Judge, Approval handler, Audit handler, Secret handler, live driver,
root handler, host bridge, operating system, or deployment configuration. Exact
hash selection makes replacement visible; it does not make selected code safe.

The host supplies authenticated approval actors. Jacquard checks those actors
against durable allowed principals but does not ship an identity provider,
operator authentication protocol, or production approval UI.

## Authority and isolation

- Workspace v0 is the only advertised facade. Arbitrary user effects and
  arbitrary handler compositions are outside the evidence.
- Raw grants are effect-wide. They are not path-, domain-, row-, tenant-,
  quota-, or value-scoped object capabilities.
- Resource strings and configuration hashes are review evidence, not enforced
  row facts.
- The membrane does not prevent data-influence or confused-deputy attacks
  inside authority a policy legitimately grants.
- It does not provide hostile multi-tenant isolation, covert-channel or timing
  defenses, denial-of-service protection, or an OS process sandbox.
- Governed `Eval` is rejected. There is no dynamic-code exception.

## External state and execution

- External state may become stale unless the Call carries a precondition and
  the live driver enforces it. Workspace v0 currently freezes empty
  preconditions and makes no atomic compare-and-act claim.
- A verified uninterrupted live path invokes its driver at most once. This is
  not exactly-once external execution.
- Decision delivery and bridge resumption are at most once. A crash after an
  outside effect, or a refused completion write, may leave an honest recovery
  gap.
- There is no safe automatic retry, compensation, rollback, queue/Audit
  transaction, provider idempotency guarantee, or authenticated receipt
  protocol.
- The action journal classifies observed evidence; it does not prove that a
  provider performed an action or that an absent completion means rollback.
- Provider, publisher, receipt, Audit-head, and action-journal-head
  authenticity are external responsibilities. No trusted cross-stream clock
  ships.

## Approval queue and host assumptions

The durable approval queue is a local POSIX advisory-lock design. It assumes a
trusted stable parent directory and cooperating writers. It does not claim
safe operation against hostile concurrent renames, writers that ignore locks,
distributed filesystems, or every storage-stack crash behavior.

The bridge supports one approval rendezvous. It does not persist evaluator
continuations, poll for decisions, support multi-approval checkpoints, or
provide a general workflow service. Detecting an invalid later approval cannot
undo root effects acknowledged after an earlier one.

## Simulation and judgment

- Dry execution proves absence of the advertised live authority path; it does
  not prove that a simulator matches reality.
- Deterministic renderers may be misleading while remaining deterministic.
  They are trusted review components and must be inspected or replaced.
- A Judge assessment is governed input, not verified model truth.
- G5 posterior beliefs, uncertainty policies, inference-backed judgment, and
  assessment-evidence replay do not ship in this boundary.
- Under-confidence never auto-allows in v0, but that law is not a general
  safety or alignment claim.

## Secrets

Calls and review artifacts carry versioned `SecretRef` values, not secret
material. The evidence pins late resolution, safe summaries, and non-vacuous
leak scans before exposure. Once a permitted live driver explicitly calls
`secret.expose`, opacity ends. There is no taint tracking, downstream
information-flow control, or protection against post-exposure exfiltration.

## Audit and hashes

`Audit` means ordered, canonical, hash-linked evidence acknowledged at the
specified boundaries. It does not mean a compliance-grade durable service.
Completion acknowledgement can fail after an irreversible action.

HASH_V0 establishes canonical identity, and a chain establishes internal
consistency relative to trusted inputs and a trusted published head. Neither
proves correctness, truth, safety, authorization, review, identity of a human
or provider, or freshness.

## Composition, tooling, and native scope

- Runtime membrane composition is released for unchanged Workspace arguments.
  Transformed-call parent/new-ID relationships are verifier support, not a
  shipped transformed forwarding runtime.
- `why-effect` attribution is conservative. An empty or partial result is not
  proof that a runtime effect is absent.
- GM.17C provides a typed library seam for review classification. It is not a
  public package command, signed persisted snapshot, or package policy
  workflow.
- The playground decision-chain view does not ship.
- The flagship is a source-checkout evidence demo, not an installed production
  service.
- Selected closed programs have interpreter/native byte parity. The approval
  queue, provider adapters, and OCaml host failures are not production native
  host integration.

## Work required for a production-ready claim

At minimum: an authenticating operator surface, durable operational Audit
integration, an idempotency/recovery strategy, supported production host
deployment, external security review against this threat model, and enforceable
resource isolation finer than whole-effect grants.
