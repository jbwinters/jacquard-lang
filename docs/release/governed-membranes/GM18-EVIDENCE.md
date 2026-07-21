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
2. The actual live composition places an inner `workspace.forward-layer`
   inside the released `workspace.live-layer` leaf and shares one audit
   sequence. A permissive inner policy records `Allow` and forwards the exact
   call unchanged; the stricter outer policy records `Block`. The refused run
   has three audit entries and zero `Fs`, `Net`, or `Secret` calls. Changing
   only the outer policy permits the unchanged agent: the host records one
   read, one write, two fetches, two secret reads, and two secret exposures in
   the exact raw-driver order printed by the transcript. The inferred live row
   is `{Secret, Fs, Net}`; the dry row remains empty.
3. The denial beat evaluates the demo's proposal-only
   `deployment-approval-request()` through the real
   `Governance_approval_bridge` and durable `Governance_approval_queue`. The
   first run durably submits the canonical Medium/High deployment proposal
   without entering a live world. After the host records `Denied`, a complete
   rerun consumes that exact Decision and returns it. The three durable records
   are Submit, Decision, and Consume; `Fs`, `Net`, and `Secret` counters all
   remain zero. This avoids replaying prior live effects and does not wrap the
   Workspace gate with `governance.approval.before-action`. No approved host
   orchestration path is claimed by GM.18.
4. The launcher invokes the unchanged
   `test/cli/governance-fault-laws.jqd --exhaustive` lane. It executes all 349
   immutable fault sites and verifies the released 698 typed-error/fail-stop
   paths; GM.18 does not copy or weaken that matrix.

The deployment review row is derived at runtime from released constructors:

```text
call-id     e73e16e6f1659873b45eafdeb84f161180cd72d9e8e790369f44683bd63ab672
policy-id   fc90806170e9d902775c96263539a673c1f440259d178c24dd42058a8ca75ec1
proposal-id 90d9ca81e7e55d61d8176476589f15fb14a907ce67175f745552db2dc65bba38
```

Before the host installs the raw live adapter, it reconstructs that proposal
from the exact typed deployment request, Medium/High policy, and fixture
assessment and requires the same proposal ID. The adapter then matches both
deployment URL and generated body before incrementing the Net counter; request
or proposal drift fails closed before the deployment driver boundary. This is
an exact preauthorization boundary, not blanket deployment permission.

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
identity, real live counters/order, queue result, verified head, Warp summary,
and the GM.15 executable summary. The compiled Alcotest inventory remains 799
cases. The overlay raises
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

Use a newly created empty TMPDIR. The public launcher creates bounded fresh
subtrees for the live host and durable bridge queue.
