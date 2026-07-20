# Governed Membranes GM.11 Evidence

Status: candidate reconstructible GM.11 overlay on exact integrated base
`ec927488054ac3cac815e217f0a0bb7a35562a5a`.

## Context

GM.9 released a typed `Workspace` request vocabulary and canonical review
artifacts. GM.10 connected that facade to the world-free dry gate. Neither
slice provided the live translation from an allowed Workspace request to the
raw `Fs`, `Net`, and `Secret` operations named by its frozen authority
envelope. A program could therefore review or simulate the facade but could
not execute it through the canonical governed boundary.

GM.11 adds that live half without changing the Workspace interface, GM.9 Call
identities, Governance v0 carriers, GM.7 gate, HASH_V0, surface syntax, or the
27 kernel forms.

## What changed

`prelude/27-workspace-live.jqd` publishes three operation-specific trusted
drivers:

```text
workspace.driver-read  : (Path) ->{Fs} Result ToolError Text
workspace.driver-write : (Path, Text) ->{Fs} Result ToolError ()
workspace.driver-fetch : (Request) ->{Secret, Net} Result ToolError Response
```

The drivers keep raw effects out of the membrane control path. Read and write
introduce only `Fs`. Fetch performs `Secret.read`, then `Secret.expose`, then
`Net.fetch`. It uses the frozen `SecretRef("workspace", None)` and never adds
the exposed bytes to the Request, Call, proposal, preview, outcome summary, or
Audit entry.

The live membrane has the exact released signatures:

```text
workspace.live-layer : forall a | e.
  (AuditSequence, BoundPolicy LivePolicy, WorkspaceSimulators,
   () ->{Workspace | e} a)
  ->{State, Judge, GovernanceApprovalV1, Audit, Fs, Net, Secret | e} a

workspace.live : forall a | e.
  (BoundPolicy LivePolicy, WorkspaceSimulators,
   () ->{Workspace | e} a)
  ->{Judge, GovernanceApprovalV1, Audit, Fs, Net, Secret | e} a
```

Every clause constructs its canonical GM.9 Call, passes only the optional pure
preview and type-specific summarizer to `governance.gate-live`, and waits for a
disposition. `ExecuteLive` invokes one raw driver once, records `Completed`,
then consumes the clause-local affine Resume once. Refusal consumes Resume
with the exact typed error and performs no raw operation. Normalizer failure
returns `InvalidDecision` without fabricating an audit identity.

## Why this shape

The gate remains world-free and does not receive a raw closure or Resume. That
keeps the authority translation visible in the facade layer's ordinary effect
row and preserves the single-tail v0 type design. Operation-specific drivers
also make review direct: the leaf introducing `Fs`, `Net`, or `Secret` is a
small named term rather than a universal tool dispatcher.

GM.9 froze empty `quote {()}` Workspace preconditions and published exact Call
goldens. Expected-hash/version freshness cannot be added honestly without
changing the artifact a reviewer approves. GM.11 therefore does not hide an
expected value in driver configuration or claim external-state freshness. A
future version must carry the expected value in a new Call/Proposal contract
and use an atomic compare-and-act host primitive. This is a deliberate,
reviewed deferral, not a simulated stale-precondition test.

The released raw operations return `Text`, `()`, `Response`, and `Secret`, not
`Result`. A host-handler failure consequently remains a structured
`Runtime_err`; this slice does not pretend to convert it to `DriverFailed`.
Typed `DriverFailed` remains available for simulators and for a future typed
driver boundary.

## Executable evidence

`test/test_workspace_live.ml` executes the stored prelude definitions through
real evaluator root handlers. It pins:

- an unchanged agent row of exactly `{Workspace}`;
- exact live-layer, live-owner, and raw-driver schemes;
- direct semantic dependencies on all three normalizers, drivers,
  `governance.gate-live`, and `governance.complete`;
- one raw action for `Allow` and exact `Approved`, and zero for `Denied`,
  `Escalate`, stale approval, and `Block`;
- one read, one write, one fetch, one secret read, and one secret expose across
  the three-operation Allow run;
- `Secret.read -> Secret.expose -> Net.fetch` ordering and absence of the fixed
  secret bytes from results and captured audit/root events;
- no direct facade bypass: an unhandled Workspace request reaches no raw root
  handler;
- refusal of the pre-action Audit write prevents the driver;
- a raw handler failure occurs after `Evaluated`, attempts the driver once,
  records no fictional `Completed`, and does not resume; and
- refusal of `Completed` is surfaced after the raw action and makes no rollback
  claim.

The current successor inventory is 767 compiled Alcotest/QCheck cases, 44 cram
transcripts, and 27 documentation examples across 8 documents.

## Exclusions

GM.11 does not add external-state preconditions, atomic compare-and-act,
path-scoped grants, typed raw-host failure conversion, nested forwarding,
queue persistence, operator CLI surfaces, a flagship demo, a kernel form, or a
new effect. Nested monotone membranes remain GM.12; product surfaces remain
later slices. The GM.13 queue/bridge remains the production approval adapter.

## Reproduction

```sh
eval "$(opam env)"
mkdir -p "$PWD/.scratch/tmp"
export TMPDIR="$PWD/.scratch/tmp"
opam exec -- dune build --root "$PWD" @all
cd test && ../_build/default/test/test_jacquard.exe test \
  'workspace-live|workspace-dry-run|workspace|governance-gate|governance-verify|prelude|rings' \
  --compact --color=never
cd ..
opam exec -- dune runtest --root "$PWD" --force
opam exec -- dune build --root "$PWD" @fmt
opam exec -- dune build --root "$PWD" @doc
scripts/release/reproduce-0.1.sh
sha256sum -c docs/release/governed-membranes/GM11-MANIFEST.sha256
```
