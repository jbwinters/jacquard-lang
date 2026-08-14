# RW.7 Relational Regression Evidence

Status: successor evidence over exact RW.6 commit
`10e27f4bb534f275959c253b02a40cb9d87f92b0`, August 2026.

RW.7 makes the shipped relational lanes load-bearing. It adds no language
feature, kernel form, effect, authority, grant, diagnostic, hash identity,
store format, native behavior, or scheduler transition. The historical
effect-taxonomy, governed-membrane, and structured-concurrency publications
remain attestations of their exact publication trees; RW.7 records later
documentation and regression evidence in this separate successor overlay.

## Standing regression net

The registered Alcotest suite is named `relational-regression-net` and owns
three cases:

| case | variation | observation | requirement |
|---|---:|---|---|
| exact `demos/concurrency/task-schedules.jac` top expression | 16 deterministic seeds rooted at 42 | complete `run-transcript-v1` bytes | every transcript equals run 1 |
| direct cancellation with an open nested scope | 64 deterministic seeds rooted at 42 | trusted test-local Console buffer | no `orphan-direct` sentinel |
| fail-fast cancellation with a two-level nested descendant | 64 deterministic seeds rooted at 42 | trusted test-local Console buffer | no `orphan-fail-fast` sentinel |

Each constituent receives a fresh store, evaluator context, scheduler run, and
observation buffer. The cancellation fixtures declare only a test-local
`RegressionGate` effect. A descendant announces that its nested run exists,
then waits cooperatively. Direct cancellation marks the gate strictly after
`async.cancel`; the fail-fast root handler atomically marks the gate and
returns the injected failure. A descendant prints only after observing that
mark. Correct transitive cancellation removes the descendant first, while an
orphaned run can receive a later decision and produce the sentinel.

The public lane is `demos/concurrency/relational-tests.jac`. It runs three
typed `SameUnder(..., VarySchedule(...))` cases at 32 schedules each:
two-child result aggregation, fail-fast result aggregation, and nested scope
completion. `demos/concurrency/run.sh` executes the lane and
`test/cli/concurrency-evidence.t` pins its complete success transcript. The
public Warp path deliberately observes result values; the compiled gate cases
observe routed-callback safety that a result-only projection cannot see.

The new registered cases raise the compiled Alcotest/QCheck inventory from 865
to 868. The recursive cram inventory remains 58 transcript files and the
doctest inventory remains 28 named examples.

## Mutation proof

The positive control is one compile-preserving line in
`cancel_nested_scopes` in `src/round_robin.ml`:

```ocaml
cancel (child_runs parent_run parent_task)
```

is temporarily replaced with:

```ocaml
cancel (List.filter (fun _ -> false) (child_runs parent_run parent_task))
```

The registered net then failed as the positive control requires:

```text
ASSERT direct cancellation leaked sentinel `orphan-direct` under schedule seed 42
FAIL direct cancellation leaked sentinel `orphan-direct` under schedule seed 42
2 failures! in 8.241s. 3 tests run.
```

Both cancellation rows failed; the first rendered failure is retained above.
The mutation was restored with `apply_patch`, no mutation commit was created,
and the registered three-case net passed again. The restored
`src/round_robin.ml` SHA-256 is
`c87294a82b047acc4ab8c0bca0680e721a54cbb4dd22f13b25b321cc65895968`,
identical to the RW.6 base.

## Secret claim reconciliation

The living taxonomy, stdlib, tutorial, reviewer guide, and later evidence
prose retain the original limit: opaque `Secret` is non-derivable before
explicit exposure, but plaintext is ordinary `Text` afterward and Jacquard
does not provide taint tracking or a static information-flow proof. They now
point to the shipped bounded instrument:

```sh
jacquard relate FILE --vary secret=NAME --seed S --allow secret
```

A pass is scoped to the selected program, name, seed, and two exact derived
payloads. It does not detect transformed or fragmented payloads. Night Shift
is the flagship runnable lane: its launcher varies the deploy token, requires
equal complete observations, and separately scans the rendered transcript for
derived payload leakage.

## Reproduction

```sh
eval "$(opam env)"
mkdir -p "$PWD/.scratch/tmp"
export TMPDIR="$PWD/.scratch/tmp"

opam exec -- dune build @all
opam exec -- dune runtest --force
opam exec -- dune fmt
git diff --exit-code
opam exec -- dune build @doc

scripts/release/check-relational-warp-manifest.sh
scripts/release/check-historical-manifests.sh \
  --candidate-root "$PWD" --require-history
scripts/release/test-historical-manifests.sh
scripts/release/reproduce-0.1.sh
```

The RW.7 checker pins the immutable historical-publication policy and SC.17
correction anchors, verifies every successor-overlay hash, and reconciles the
manifest inventory with the complete path diff from the exact RW.6 base when
Git history is available.

## Preserved boundaries

- `VaryValue` still compares one exact generated pair; it is not approximate
  distribution comparison.
- Static information-flow typing, taint labels, probabilistic relational
  logic, and unbounded k-run generalization remain outside v0.
- Schedule variation is bounded deterministic evidence, not a proof over all
  possible future schedulers.
- The public relational lane remains hermetic and interpreter-driven. No
  native `relate` behavior is claimed.
- Registered historical manifest/checker bytes and the publication registry
  are unchanged. RW.7 is not inserted into that registry before publication.
