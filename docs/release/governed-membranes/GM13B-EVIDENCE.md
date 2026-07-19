# Governed Membranes GM.13B Evidence

Status: candidate reconstructible GM.13B overlay on exact base
`bb3f5ead766c914cacd7f7b9caee93ed109aa874`.

## Context

GM.13A released the crash-safe, authenticated, single-use approval queue, but
deliberately stopped before connecting that host state to an executing
`GovernanceApprovalV1` gate. A production boundary still had to prove that the
exact proposal submitted for review is the proposal later delivered to the
gate, that an approval cannot be replayed, and that the gate's pre-action Audit
ordering survives restart and failure.

GM.13B adds that narrow connection as the public OCaml
`Governance_approval_bridge`. It changes no Jacquard form, effect, prelude
declaration, surface syntax, canonical serializer, operation mode, native
backend, or scheduler. The kernel remains 27 forms. The released
`GovernanceApprovalV1`, `GovernanceProposal`, Decision, and HASH_V0 identities
remain unchanged.

## Frozen host workflow

The bridge implements a two-run workflow with one approval rendezvous per
driver invocation:

1. A complete first run evaluates the gate, captures only the exact released
   `governance-approval.ask` operation, converts its exact runtime
   `GovernanceProposal` carrier back to canonical semantic Code, recomputes the
   carried proposal ID, and durably submits it. A newly Applied Submit returns
   typed `Awaiting_approval` immediately without attempting Consume or resuming
   the affine continuation. A reviewer racing after Submit therefore cannot
   turn the first invocation into an executing invocation.
2. An authenticated host records a Decision with GM.13A
   `Governance_approval_queue.decide_file`. Authentication remains a host
   responsibility; the queue verifies the resulting actor against durable
   allowed-principal metadata.
3. A later complete rerun reevaluates the gate and submits the same proposal
   idempotently. Only a durable `Delivered` result is converted to the exact
   released Decision runtime constructor. Consume is committed before the new
   affine continuation is resumed once.

This intentionally persists proposal and decision state, not evaluator
continuations. A second sequential queue-backed approval in the same invocation
is rejected with E1527 before another queue transition. Workflows requiring
several approvals need an explicit persisted checkpoint/resumption design and
are not disguised as safe retries.

## Trusted routing and exact codecs

`Governance_approval_bridge.run` uses the evaluator's guarded routed
once-capture boundary. Before execution it compares every required effect,
operation, owning type, and constructor name against its frozen released hash,
owner declaration, and member role. Rebinding a canonical Store name fails with
E1527. It intercepts only the frozen `governance-approval.ask` operation hash;
every other captured operation is dispatched through the existing
installed-root-handler guard. A preinstalled root handler for the approval
operation cannot bypass the bridge. The API accepts neither a generic handler
callback nor a callback registry, and no in-language scripted approval handler
is treated as the production path.

The Proposal encoder requires the exact constructor hashes and arities for
`governance-proposal-v0`, `governance-v0`, the authority list and variants, and
the optional preview. It reconstructs the released semantic field order and
requires the carried proposal ID to equal the GM.13A recomputation before any
queue file is created. The Decision decoder accepts only exact
`approved-v1`, `denied-v1`, or `escalate-v1` Code shapes and reconstructs the
released runtime constructors. GM.13A independently revalidates the Decision's
proposal binding and authenticated actor before delivery.

Invalid Proposal or approver configuration retains E1523; invalid delivered
Decision data uses E1524. Queue corruption, transition conflict, and I/O failure
retain GM.13A E1520--E1526 diagnostics. GM.13B adds only E1527 for a frozen
bridge-schema mismatch or a second sequential rendezvous. No semantic identity
is introduced or changed.

## State and Audit ordering

The compiled gate evidence pins these externally visible sequences:

| path | durable queue transition | Audit entries in the run | driver calls |
|---|---|---|---:|
| first pending run | Submit only | `Evaluated` | 0 |
| approved rerun | Consume before resumption | `Evaluated`, `Consented`, `Completed` | 1 |
| denied or escalated rerun | Consume before resumption | `Evaluated`, `Consented` | 0 |
| `Evaluated` Audit failure | none | attempted `Evaluated` | 0 |
| `Consented` Audit failure | Consume already committed | attempted `Evaluated`, `Consented` | 0 |
| replay after Consume | stale observation | `Evaluated` | 0 |

The Audit entries in this table are successful or refused handler
acknowledgements observed by the bridge tests; GM.13B does not add or claim a
durable Audit storage handler. The `Consented`-failure row is deliberately fail
closed, not transactional: the
Decision is stranded as stale after Consume and cannot be delivered again. An
Audit/queue transaction and rollback are not claimed. Conversely, failure of
the pre-approval `Evaluated` record leaves the queue absent.

Two concurrent complete reruns race through the same GM.13A lock and local
Domain guard. Exactly one consumes, resumes, and calls the live driver; the
other observes Stale or transient Busy and performs no action. This establishes
at-most-once queue delivery and bridge resumption. It does not establish
exactly-once outside-world action: a crash after Consume or after a driver side
effect can strand progress, and retry remains unsafe without a separate action
journal/reconciliation contract.

## Compiled hostile evidence

Eight new Alcotest cases in `test/test_governance_approval_bridge.ml` cover:

- first-run Submit/Awaiting, exact Approved round-trip, restart replay as Stale,
  configuration drift rejection, and root-handler bypass resistance;
- a mismatched carried proposal ID before queue creation and refusal of a
  second sequential rendezvous without a second queue transition;
- frozen effect, operation, constructor, and owning-type name rebinding;
- approved gate ordering, driver exactly once, replay, and a Decision stranded
  by refused `Consented` Audit;
- Denied and Escalate refusal paths plus an `Evaluated` Audit failure that
  leaves no queue;
- bridge-level Busy, corrupt journal, and unsafe-path failure with no action;
- repeated first-Submit races against four reviewer Domains, with no Consume
  or resumption in the first invocation; and
- two concurrent bridge consumers with exactly one completed action.

These cases raise the current successor inventory from 755 to exactly 763
compiled Alcotest/QCheck cases. The 44 cram transcripts and 27 doctest examples
across 8 documents are unchanged.

## Explicit limits

GM.13B provides an OCaml host API only. It adds no public approval/operator CLI
because accepting caller text such as `--actor` would misrepresent unauthenticated
input as a trusted identity. Authentication providers and operator UX require a
separately designed host surface.

It also adds no polling or blocking wait, persisted evaluator continuation,
multi-approval checkpoint workflow, generic handler injection, remote or
distributed queue, hostile-directory guarantee, reset of consumed approvals,
queue/Audit transaction, rollback, action exactly-once protocol, scheduler or
native integration, inference-driver integration, or fault-injection seam. The
GM.13A trusted-stable-parent-directory and local POSIX advisory-lock assumptions
remain in force.

The single-rendezvous check is an input contract, not rollback. If an invalid
program performs other root effects after its first delivered approval and then
asks again, those already acknowledged effects are not undone. Production
hosts must admit computations whose complete invocation contains exactly one
queue-backed approval rendezvous.

## Reproduction

From a clean checkout with the repository-local switch selected:

```bash
eval "$(opam env)"
mkdir -p "$PWD/.scratch/tmp"
export TMPDIR="$(mktemp -d "$PWD/.scratch/tmp/gm13b.XXXXXX")"

opam exec -- dune build @all
opam exec -- dune runtest --force
opam exec -- dune build @fmt
opam exec -- dune build @doc

cd test
opam exec -- ../_build/default/test/test_jacquard.exe test \
  'governance-approval-bridge' --compact --color=never
cd ..

sha256sum -c docs/release/governed-membranes/GM13B-MANIFEST.sha256
```

The manifest covers every tracked file changed by the GM.13B overlay and
excludes itself to avoid a self-hash.
