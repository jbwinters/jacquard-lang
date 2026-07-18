# Governed Membranes GM.7 Evidence

Status: candidate reconstructible GM.7 overlay on integration commit
`f614786d02c1f8720635ef708598ba3a144b4262`.

GM.7 releases the live governance control gate, exact consent over the
canonical `GovernanceProposal`, and an additive effect-taxonomy v2. It leaves
the released ET.6 `Approval(Proposal)` interface, all v0 governance carriers,
and `HASH_V0` unchanged.

## Versioned consent boundary

`GovernanceApprovalV1` is a once governance effect with exact identity:

```text
41b449689fb30e44180185007d845bbe246e5401fe3e8478f4fd02e556a3f2ed
```

Its only operation is:

```text
governance-approval.ask : (GovernanceProposal) -> Decision
```

`GovernanceApprovalV1` is a trusted consent capability, not an authentication
protocol. Hash binding proves that a Decision names the byte-exact proposal;
it does not prove reviewer identity, freshness, or global single use. A
production handler is responsible for authenticating its reviewer and
enforcing any replay policy. Every accepted decision is still recorded as a
`Consented` audit entry, so a replay supplied by a handler remains observable.
The shipped scripted handler is deliberately an evidence/test boundary: it
consumes explicit decisions in order and validates each one before resuming.
Production hosts must not install it as their consent authority.

`governance.approval.before-action` is an alternative low-level execution
boundary for a host that already has a proposal and decision; it is not a
wrapper for the gate/facade flow. Only one of those execution APIs may own a
given action. The helper maps both malformed proposals and mismatched Decision
hashes to `StaleApproval`; operators that need to distinguish artifact damage
from ordinary staleness can run the pure `validate-decision` first and retain
its diagnostic without crossing the action boundary.

`governance.approval.validate-decision` first validates the complete canonical
proposal, then requires the Decision's embedded proposal hash to equal the
recomputed `GovernanceProposal` ID. The scripted handler accepts only explicit
pre-bound decisions; it never synthesizes or rebinds consent. The frozen ET.6
Approval identity remains
`362425a29077a7efbcc37047182e579f46199a50473045eb4126a917dfc2a196`.

`spec/effect-taxonomy-v1.tsv` remains byte-for-byte historical evidence.
`spec/effect-taxonomy-v2.tsv` preserves its exact 26-row prefix and appends
`GovernanceApprovalV1` at position 26. Versioned registry APIs expose both
snapshots; the current aliases select v2. The interpreter and native catalog
tables both contain the 27-row order. Catalog position is deterministic
serialization metadata, not privilege or risk priority. Because governance
control effects are outside raw action envelopes, the additive row does not
change existing Call or GovernanceProposal identities.

## Live gate contract

`governance.gate-live` has the exact closed control row:

```text
forall a.
  ( AuditSequence
  , BoundPolicy LivePolicy
  , GovernanceCall
  , Option (() ->{} Result ToolError a)
  , (Result ToolError a) ->{} GovernanceOutcomeSummary
  ) ->{Audit, GovernanceApprovalV1, State, Judge} LiveDisposition
```

The gate validates Call and BoundPolicy before effects, obtains and validates
the exact assessment, computes the live verdict, records `Evaluated`, and only
then selects a branch. `Allow` returns `ExecuteLive`; `Block` refuses. `Ask`
optionally computes a pure preview, constructs one canonical
`GovernanceProposal`, requests consent through `GovernanceApprovalV1`, rejects
stale Decisions, records `Consented`, and returns `ExecuteLive` only for an
exact Approved decision. Denied and Escalate remain explicit refusals.

The gate never owns raw authority or an affine `Resume`. The facade clause
performs the selected action exactly once, summarizes its result, calls
`governance.complete`, and consumes its local Resume. This representation
keeps raw effects visible in the facade's ordinary row and prevents a second
effect-row tail.

## Fail-closed evidence

`test/test_governance_gate.ml` pins the complete inferred row, both Approval
interface identities, and a host-counter matrix covering Allow,
confidence-driven Ask, Approved, Denied, Escalate, stale consent, and Block.
The driver count is exactly one for Allow and exact Approved, and zero for
every other branch. Preview, approval, and summarizer counts are independently
pinned. Direct helper tests prove that only exact Approved forces an action;
Denied, Escalate, and stale decisions return typed refusals without doing so.
Scripted-handler tests cover ordered multi-request consumption, exhaustion,
and a stale decision after a successful first request.

Audit fault tests pin the action boundary:

- refusal of `Evaluated` prevents preview, approval, summarization, and action;
- refusal of `Consented` prevents an otherwise Approved action; and
- refusal of `Completed` is surfaced after the external driver has returned.

The last case deliberately makes no rollback claim. Operators receive a
reconciliation failure while the counter proves that the external action ran
once. Accepted streams retain strict `Evaluated`, optional `Consented`, then
`Completed` sequence order.

The taxonomy suite proves the exact v1 prefix, one-row v2 suffix, prelude
schema/hash agreement, v1 cross-version refusal, and position 26 in both the
versioned and current registries. Prelude operation-mode, ring, and hash
goldens include every new declaration.

The additive row is a gate-control effect, not raw action authority. Its
governance tier, special review risk, and catalog position never add it to a
Call authority envelope; the exact closed gate row and forbidden raw-effect
assertions pin that separation.

## Reproduction

```sh
eval "$(opam env)"
mkdir -p "$PWD/.scratch/tmp/gm7-reproduce"
export TMPDIR="$PWD/.scratch/tmp/gm7-reproduce"
opam exec -- dune build --root "$PWD" @all
cd test && opam exec -- ../_build/default/test/test_jacquard.exe test \
  'governance-gate|governance-core|approval|prelude|effect-taxonomy|rings|native' \
  --compact --color=never
cd ..
opam exec -- dune runtest --root "$PWD" --force
opam exec -- dune build --root "$PWD" @fmt
opam exec -- dune build --root "$PWD" @doc
sha256sum -c docs/release/governed-membranes/GM7-MANIFEST.sha256
```

The manifest attests the complete overlay relative to the integration commit;
historical release manifests remain immutable descriptions of their own
checkouts.
