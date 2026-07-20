# Governed Membranes GM.12A Evidence

Status: candidate reconstructible GM.12A overlay on exact GM.11 base
`79645e934f63abad481ce057b3d877ef88716f09`.

## Context

GM.11 released the live Workspace leaf that translates reviewed facade calls
to `Fs`, `Net`, and `Secret`. The language semantics already let an operation
clause re-perform the same operation into an outer handler, which is the
mechanism required for project, tenant, company, and host policies to tighten
one another by ordinary nesting.

The GM.8 verifier could not represent that structure honestly. Its v0 action
target contained only an operation hash, so forwarding `workspace.write-file`
to the next layer's identical `workspace.write-file` looked like a recursive
cycle. Silently changing v0 would invalidate the meaning of released evidence.

GM.12A therefore adds the versioned static-analysis foundation needed before
the runtime forwarding layer is published. It changes no language syntax,
kernel form, evaluator behavior, Workspace identity, gate, raw driver, command
line, or release serialization.

## What changed

`Governance_verify.V1` is an additive public module accepting exact
`governance-verifier-v1` contracts. It keys forwarding by:

```text
(layer-id, facade-operation-id)
```

The verifier requires one linear live membrane chain with a unique inner root
and raw outer leaf. Every layer must cover the complete once-mode facade.
Every non-leaf operation must forward exactly once to the identical operation
in its declared immediate outer layer. The leaf must contain a nonempty list
of raw actions.

Transitive authority expansion follows the qualified graph and compares the
result with the frozen Call and Proposal envelopes at every layer. The existing
control-effect exclusion, absolute `Eval` prohibition, configured-resource
checks, canonical identity reconstruction, pure normalizer and summarizer
requirements, secret exclusion, complete Ask binding, canonical live-flow
ordering, and single sequence owner rules remain fail-closed.

V1 additionally checks direct adjacent Call lineage. The inner root is
`Original`. Identical Call IDs require exact `Unchanged_forward` evidence.
Different IDs require exact `Transformed_forward` evidence whose parent is the
immediate inner Call. The runtime slice will publish unchanged forwarding only;
argument transformation remains deferred until a versioned typed carrier can
preserve that lineage end to end.

## Why this shape

Layer identity belongs in analysis evidence because an operation hash names a
facade operation, not one dynamic membrane instance. Qualifying the graph
makes valid same-operation forwarding distinct from recursion without changing
any frozen program identity.

A linear chain is the smallest production contract matching the product rule:
the nearest policy sees a request first, an inner allow cannot force an outer
allow, and only the outer leaf introduces raw authority. Rejecting branching,
skipped layers, partial facades, mixed raw/forward actions, and multiple token
owners avoids claiming semantics the planned runtime API does not provide.

V0 remains byte- and behavior-compatible for released single-layer evidence.
V1 is live-only because GM.12 composes live policy layers; the existing GM.10
dry-run contract remains unchanged.

## Executable evidence

`test/test_governance_verify_v1.ml` pins:

- a valid three-layer chain forwarding all three Workspace operations under
  identical qualified operation IDs;
- complete and duplicate-free facade coverage at every layer;
- rejection of duplicate IDs, unknown outer layers, cycles, branches, and
  disconnected leaves;
- rejection of wrong-operation, skipped-layer, empty-leaf, forwarding-leaf,
  and consistently forged facade-as-raw-leaf action shapes;
- direct root, unchanged, and transformed-parent lineage;
- transitive frozen authority equality and raw control/`Eval` exclusion;
- one exact sequence-token use per live layer; and
- additive v1 version refusal without changing `governance-verifier-v0`.

The current successor inventory is 775 compiled Alcotest/QCheck cases, 44 cram
transcripts, and 27 documentation examples across 8 documents.

## Exclusions

GM.12A does not add `workspace.forward-layer`, execute a nested membrane, alter
arguments, add an artifact extractor or `jac governance check` command, change
dry-run behavior, add a raw effect, or make a native/runtime claim. Those
runtime and exhaustive monotonicity obligations remain GM.12B.

## Reproduction

```sh
eval "$(opam env)"
mkdir -p "$PWD/.scratch/tmp"
export TMPDIR="$PWD/.scratch/tmp"
opam exec -- dune build --root "$PWD" @all
cd test && ../_build/default/test/test_jacquard.exe test \
  'governance-verify-v1|governance-verify|workspace-live|handlers|gauntlet-handlers' \
  --compact --color=never
cd ..
opam exec -- dune runtest --root "$PWD" --force
opam exec -- dune build --root "$PWD" @fmt
opam exec -- dune build --root "$PWD" @doc
scripts/release/reproduce-0.1.sh
sha256sum -c docs/release/governed-membranes/GM12A-MANIFEST.sha256
```
