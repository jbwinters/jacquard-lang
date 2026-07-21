# Governed Membranes GM.18 flagship evidence

Status: release-hardening demo/evidence overlay on exact integrated base
`dcdd38457f13b0523ad5e3776e05135c9fa903d7`.

## Scope

GM.18 adds a public cookbook and transcript over the unchanged GM.10–GM.17
interfaces. It adds no language form, runtime behavior, schema, CLI command,
grant, native path, or product approval surface. `agent.jac` has the exact
checked signature:

```text
governed-deploy-agent : () ->{Workspace} Result ToolError Response
```

The agent reads `deploy/manifest.json`, fetches an artifact, writes generated
configuration, and submits the deployment as another released
`Workspace.fetch(Request)`. Its canonical member identity is
`fab711efd085966134e843f93e201de04b8aeb966a54313ef414ff5997951e77`.

## Executed worlds

The checkout-only `demos/governed-workspace/run.sh` executes four evidence
worlds in one deterministic narrative:

1. The no-grant dry world uses the real `workspace.dry-run` with closed pure
   simulators. Four facade calls yield eight ordered audit entries, HTTP 202,
   and zero raw actions. The fully handled `dry-world` row is empty.
2. Two `workspace.forward-layer` calls share one audit sequence. A permissive
   inner policy records `Allow` and forwards the same call identity unchanged;
   the stricter outer policy records `Block`. The result is refused after three
   audit entries and zero raw actions. Changing only the outer semantic policy
   allows the same agent and reaches four typed actions.
3. The denial beat executes existing compiled case 4 of
   `governance-approval-bridge`. That case calls the real
   `Governance_approval_bridge` and durable `Governance_approval_queue`, writes
   a `Denied` decision carrying the queue's exact proposal ID, reruns the gate,
   and asserts the driver counter remains zero. The launcher labels this
   honestly as host-bridge evidence; the surface story does not substitute
   `governance.approval.scripted`.
4. The launcher invokes the unchanged
   `test/cli/governance-fault-laws.jqd --exhaustive` lane. It executes all 349
   immutable fault sites and verifies the released 698 typed-error/fail-stop
   paths; GM.18 does not copy or weaken that matrix.

The deployment review row is derived at runtime from released constructors:

```text
call-id     e73e16e6f1659873b45eafdeb84f161180cd72d9e8e790369f44683bd63ab672
policy-id   94542d3681b9b6f6530545f93c391276bbca4813854c9f75e4d6f26407e1da6e
proposal-id 0057b000967a9ee86a0fc792a31dfefeab06af5b1606f76c16fba311374ebf16
```

The three committed `.jqd` files are explicit audit evidence fixtures, not a
twin of the `.jac` agent. `jac audit append` verifies each predecessor while
constructing the exact inner-Allow, outer-Block, forwarded-refusal stream;
`jac governance verify-log` then verifies independently supplied head
`96b9bef50b9eaf21ffa1ed26bfc35eb37f433d1474892d3512c43205f1d4913a`.

## Warp and transcript evidence

`tests.jac` contributes three examples and one two-world property. Sampled
execution runs 100 seeded policy worlds; exhaustive execution covers both
strict and permissive outer policies. The laws pin dry result/audit shape,
inner-pass/outer-refusal ordering, exact proposal-bound denial, policy-only
outcome change, and zero-versus-four action counts.

`test/cli/governed-workspace.t` runs the public launcher and pins every row,
identity, queue result, verified head, Warp summary, and the GM.15 executable
summary. The compiled Alcotest inventory remains 799 cases. The overlay raises
the cram transcript inventory from 48 to 49; executable documentation remains
27 examples.

## Reproduction

```sh
eval "$(opam env)"
mkdir -p "$PWD/.scratch"
export TMPDIR="$(mktemp -d -p "$PWD/.scratch" gm18-evidence-tmp.XXXXXX)"
sh demos/governed-workspace/run.sh
opam exec -- dune runtest --root "$PWD" test/cli/governed-workspace.t --force
opam exec -- dune build --root "$PWD" @all
opam exec -- dune runtest --root "$PWD" --force
opam exec -- dune build --root "$PWD" @fmt
opam exec -- dune build --root "$PWD" @doc
sha256sum -c docs/release/governed-membranes/GM18-MANIFEST.sha256
```

Use a newly created empty TMPDIR: the pre-existing compiled harness derives
temporary store names from process IDs and can collide with stale stores after
PID reuse. The public launcher creates a bounded fresh subtree for the bridge.
