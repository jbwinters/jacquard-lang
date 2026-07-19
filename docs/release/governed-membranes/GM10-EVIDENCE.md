# Governed Membranes GM.10 Evidence

Status: reconstructible GM.10 overlay on exact integrated GM.8/GM.9 base
`df37a15cd6898dc743ec4d9075b36b0c08f41b6f`.

GM.10 releases the world-free Workspace dry-run membrane. It connects the
typed GM.9 facade to the GM.6 dry gate without adding a privileged executor,
raw driver, CLI surface, kernel form, or second action-row tail. An ordinary
Workspace program is passed unchanged to `workspace.dry-run`; the handler owns
normalization, policy judgment, simulation, auditing, refusal, and the one
local affine resumption.

## Public boundary

`WorkspaceSimulators` is a ring-3 nominal bundle with optional read, write, and
fetch callbacks. Every stored callback has a closed pure arrow. The
`workspace.simulators` constructor therefore rejects callbacks that retain
State, Fault, Dist, Fs, Net, Secret, or any other effect. Three explicit
adapters make intentional test construction reviewable:

```text
workspace.discharge-state : forall a b. (() ->{State} a, b) ->{} a
workspace.discharge-fault : forall a. (() ->{Fault} a) ->{} a
workspace.discharge-dist  : forall a b.
  (() ->{Dist} b, List (Pair b Real) ->{} a) ->{} a
```

These adapters handle helper effects before a callback is stored. They do not
grant world authority. Simulator failures remain `Result ToolError` values;
hostile driver detail is preserved for the caller but reduced to the closed
ToolError label in audit summaries.

The released membrane schemes are:

```text
workspace.dry-layer : forall a | e.
  (AuditSequence, BoundPolicy DryPolicy, WorkspaceSimulators,
   () ->{Workspace | e} a) ->{State, Judge, Audit | e} a

workspace.dry-run : forall a | e.
  (BoundPolicy DryPolicy, WorkspaceSimulators,
   () ->{Workspace | e} a) ->{Judge, Audit | e} a
```

`workspace.dry-layer` handles the three exact Workspace operation identities.
Each clause calls its typed GM.9 normalizer, builds a closed simulation thunk,
passes the exact operation-specific summarizer to `governance.gate-dry`, and
consumes its local `Resume` once for either `Simulated(result)` or
`RefuseDry(error)`. `workspace.dry-run` calls `governance.with-sequence` once,
so State does not escape the public run-level boundary. There is no live branch
and no reference to Fs, Net, Secret, Approval, or GovernanceApprovalV1.

## Executable evidence

`test/test_workspace_dry_run.ml` checks the actual stored prelude definitions,
not a parallel OCaml implementation. It pins the two exact schemes and inspects
the dry layer's direct semantic dependencies: all three Workspace operation
IDs, all three typed normalizers, all three safe summarizers, and the single
GM.6 dry gate must be present; raw Fs/Net/Secret operations must be absent.
This is also the merge link to the GM.8 verifier contract: the focused gate
reruns the existing valid Workspace contract and adversarial verifier suite
against the same exact normalizer, summarizer, gate, and operation identities.

The behavioral matrix runs all three operations for every combination of four
risks and five dry thresholds. Every run records exactly ordered, contiguous
`Evaluated` and `Completed` entries starting at zero, records no `Consented`
entry, returns the expected blocked or simulated result, and leaves root
counters at zero for Fs read/write, Net fetch, Secret read/expose, Approval
ask, and GovernanceApproval ask. Separate cases pin `NoSimulation`, a hostile
typed failure with secret-safe audit rendering, State/Fault/Dist discharge, an
empty fully handled row, and closed-row rejection for effectful callbacks.

`test/cli/workspace-dry-run-laws.jqd` is the in-language Warp proof. Exhaustive
mode crosses three operations, four risks, and missing/success/failing
simulators: 36 complete cases through the real handler. Its unit case places a
one-site `fault.all` exploration inside a simulator, discharges Warp's Check
effect with `test.run`, verifies both paths, and passes only the resulting pure
typed value to the dry gate.

## Successor correction and exclusions

Executing the composed handler exposed three latent non-exhaustive matches in
GM.9's frozen raw-effect hash constants. The successor definitions now parse
each known-good literal once and use a fail-closed recursive fallback. A valid
literal returns the identical hash; a corrupted source literal cannot produce
an authority value. This changes dependent prelude semantic identities, so the
ring manifest and prelude hash golden are regenerated in this overlay. It does
not change HASH_V0, canonical Call encoding, the Workspace operation hashes,
or the authority envelope.

GM.10 intentionally excludes the live membrane, raw drivers, secret
resolution, approval execution, nested forwarding, public verifier/extractor
commands, and any kernel or serialization change. Those remain successor work;
the dry-run proof does not imply that they exist.

## Reproduction

```sh
eval "$(opam env)"
mkdir -p "$PWD/.scratch/tmp"
export TMPDIR="$PWD/.scratch/tmp"
opam exec -- dune build --root "$PWD" @all
cd test && ../_build/default/test/test_jacquard.exe test \
  'workspace-dry-run|workspace|governance-gate|governance-verify|prelude|rings' \
  --compact --color=never
cd ..
opam exec -- dune exec jacquard -- test \
  test/cli/workspace-dry-run-laws.jqd --exhaustive --budget 1000 --no-cache
opam exec -- dune runtest --root "$PWD" --force
opam exec -- dune build --root "$PWD" @fmt
opam exec -- dune build --root "$PWD" @doc
scripts/release/reproduce-0.1.sh
sha256sum -c docs/release/governed-membranes/GM10-MANIFEST.sha256
```

The integrated GM.10 checkout contains 728 compiled Alcotest/QCheck cases, 41
cram transcript files, and 27 documentation examples across 8 documents. The
GM.10 manifest attests the complete successor overlay. Historical GM.6, GM.8,
and GM.9 evidence and manifests remain immutable.
