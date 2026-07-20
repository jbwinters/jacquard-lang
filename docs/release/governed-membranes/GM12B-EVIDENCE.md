# Governed Membranes GM.12B Evidence

Status: candidate reconstructible GM.12B overlay on exact GM.12A base
`a1b4015eadf58ca43b2db4411cd09fec571701f6`.

## Context

GM.12A made same-operation layer chains representable to the verifier, but
users still had no reusable runtime layer and would need to duplicate
security-sensitive clauses. GM.12B supplies the canonical unchanged-forwarding
handler and proves that nested policies can only preserve or reduce execution
authority.

GM.11 remains the only raw leaf. This slice changes no surface syntax, kernel
form, evaluator, Workspace operation identity, Call/Proposal encoding, gate,
raw driver, operation mode, command, or release serialization.

## What changed

`prelude/28-workspace-forward.jqd` publishes one public API:

```text
workspace.forward-layer : forall a | e.
  (AuditSequence, BoundPolicy LivePolicy, WorkspaceSimulators,
   () ->{Workspace | e} a)
  ->{State, Judge, GovernanceApprovalV1, Audit, Workspace | e} a
```

For each of `workspace.read-file`, `workspace.write-file`, and
`workspace.fetch`, the layer:

1. reconstructs the canonical GM.9 Call from the exact received arguments;
2. evaluates its bound policy through `governance.gate-live` using the shared
   sequence, operation-specific simulator projection, and typed summarizer;
3. on `ExecuteLive`, re-performs the identical Workspace operation by frozen
   operation identity with unchanged arguments;
4. records `Completed` with branch `"forwarded"`; and
5. consumes the clause-local affine Resume exactly once.

Refusal resumes once with the returned typed error and records no completion
for the refusing layer. A normalizer failure resumes with `InvalidDecision`
without inventing an audit identity. The layer has no dependency on a raw
operation, `workspace.driver-*`, `workspace.live-layer`, or
`governance.with-sequence`.

Canonical composition owns one sequence and terminates in one raw leaf:

```text
governance.with-sequence(fn sequence ->
  workspace.live-layer(sequence, host-policy, simulators, fn () ->
    workspace.forward-layer(sequence, company-policy, simulators, fn () ->
      workspace.forward-layer(sequence, project-policy, simulators, body))))
```

## Why this shape

An operation clause runs outside the handler that caught it. Re-performing the
same once-mode Workspace operation therefore reaches the next outer layer;
resuming reinstalls the deep inner handler for later requests. That existing
language rule gives nearest-policy-first evaluation without a policy-merging
engine. An inner refusal prevents every outer action, while an inner execution
cannot bypass an outer refusal.

The API intentionally supports unchanged arguments only. The current Workspace
normalizers reconstruct an original Call and cannot truthfully attach a parent
Call ID for rewritten arguments. A transform callback would make silent
mutation look verified. Transformed forwarding stays deferred until a
versioned typed Call carrier preserves that lineage end to end.

## Executable evidence

`test/test_workspace_forward.ml` adds four independently selectable cases:

- the exact public row, all positive operation/gate dependencies, and absence
  of raw, leaf, and private-owner dependencies;
- unchanged read, write, and fetch arguments reaching each raw handler exactly
  once, with two evaluations and two completions per operation and no secret
  fixture bytes in results or audit;
- inner and outer Allow/Ask/Block/Denied attenuation, exact-Proposal approval
  binding, zero raw actions after refusal, and no fictional completion for the
  refusing layer; and
- two real forward layers around a hermetic leaf, exact same-op traversal, one
  leaf reach, zero raw authority, and contiguous shared audit positions.

`test/test_gauntlet_handlers.ml` adds two standalone Once cases. The first
proves a same-op perform in a Once clause reaches the outer handler. The second
proves that consuming the outer resumption reinstalls the deep inner handler
and that two sequential dynamic requests receive independent affine budgets.
`g39-once-clause-forward.jqd` and `g40-once-deep-reenter.jqd` mirror those cases
through the existing interpreter/native differential and leak lanes.

`test/cli/workspace-forward-laws.jqd` executes two actual forwarding layers
around a hermetic Workspace leaf. It constructs and binds both policies through
the public smart constructors, uses one sequence owner, a fixed Judge,
`audit.in-memory`, `None` simulators, and an approval handler that approves only
the exact Proposal ID. The six finite sample sites cover:

```text
inner policy: 10 valid threshold pairs x 5 minimum confidences = 50
outer policy: 10 valid threshold pairs x 5 minimum confidences = 50
assessment:   4 risks x 5 observed confidences = 20

50 x 50 x 20 = 50,000 terminal cases
```

For every case, the unchanged leaf succeeds exactly when both policy verdicts
are Allow or Ask. Counterexample labels include both policies, risk,
confidence, and both verdicts. The law samples and constructs the inner policy
before branching over and constructing the outer policy, avoiding redundant
policy hashing without weakening the 50,000 real-handler executions. Rich
counterexample labels are built only on a mismatch. Warp also counts
intermediate exploration states and the post-check resume, so the reviewed
command uses budget 120,000.

That proof is intentionally excluded from ordinary `dune runtest`: executing
50,000 cases through two real handlers is too costly for the normal development
loop. It remains mandatory in the dedicated `gm12b-evidence` Dune alias and
parallel CI job. The alias captures stdout and byte-compares it with
`test/cli/workspace-forward-laws.expected`, so the evidence cannot silently
degrade into a sampled run or a different claim. CI retains the actual
transcript, allows 120 minutes for cold setup and execution, reruns for the
semantic dependency closure, and always reruns on `main` and release pushes.

The successor inventory is 781 compiled Alcotest/QCheck cases, 44 cram
transcripts, and 27 documentation examples across 8 documents.

## Claim boundary and exclusions

GM.12B proves reusable nested live forwarding, exact unchanged-argument
same-operation routing, affine Once behavior in both engines, one shared audit
sequence, exhaustive attenuation over the frozen 50,000-case grid, and no raw
authority above the leaf.

It does not prove automatic end-to-end governance source verification.
`Governance_verify.V1` still consumes trusted analysis IR; no artifact
extractor or `jac governance check` command connects the actual handler source
to a V1 contract. That tooling remains a release gate before marketing the
system as automatically verified production governance.

This slice also excludes transformed calls, dry-run changes, new raw
authority, authenticated approval UX, external-state freshness or atomic
compare-and-act, path-scoped grants, syntax/kernel/evaluator changes, new
serialization identities, and rollback claims after an external action.

## Reproduction

```sh
eval "$(opam env)"
mkdir -p "$PWD/.scratch/tmp"
export TMPDIR="$PWD/.scratch/tmp"
opam exec -- dune build --root "$PWD" @all
cd test && ../_build/default/test/test_jacquard.exe test \
  'workspace-forward|workspace-live|gauntlet-handlers|governance-verify-v1' \
  --compact --color=never
cd ..
opam exec -- dune build --root "$PWD" @test/cli/gm12b-evidence --force
opam exec -- dune runtest --root "$PWD" --force
opam exec -- dune build --root "$PWD" @fmt
opam exec -- dune build --root "$PWD" @doc
scripts/release/reproduce-0.1.sh
sha256sum -c docs/release/governed-membranes/GM12B-MANIFEST.sha256
```
