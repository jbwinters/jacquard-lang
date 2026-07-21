# Governed Membranes GM.16 source-verification evidence

Status: release-hardening implementation overlay on exact integrated base
`3f01622df8888342c194b8fc4dc759164f980b8c`.

## Context

GM.8 and GM.12A defined fail-closed governance analysis contracts, and GM.12B
shipped the reusable Workspace forwarding membrane. Reviewers still lacked one
public command that checked an actual source artifact before execution. A file
could resemble the documented composition without evidence that it resolved to
the frozen identities, used the exact argument and thunk topology, had the
profile's exact closed outward effect row, or excluded `Eval` and raw world
effects throughout its source-owned dependencies.

GM.16 adds that source gate. It changes no surface syntax, kernel form, type or
effect identity, handler semantics, evaluator, native compiler, facade
operation, membrane implementation, policy encoding, runtime artifact encoding,
driver, simulator, or release-0.1 compatibility contract.

## Public command and isolation boundary

```text
jac governance check FILE
  [--prelude DIR]
  [--syntax auto|surface|bootstrap]
  [--output-format text|json-v1]
  [--diagnostic-format text|json-v1]
```

The command accepts declaration-only `.jac` and `.jqd` input. It creates a
private `0700` temporary analysis store, loads the selected prelude, creates the
checker and freezes builtin signatures before inserting any source declaration,
then resolves and typechecks the file. It never constructs an evaluation
context, wires a builtin implementation, installs a handler, grants an effect,
or evaluates a top-level expression. Cleanup uses `lstat` and never follows a
symlink outside the exact temporary root. I/O failures become deterministic
E1413 diagnostics rather than uncaught exceptions.

There is intentionally no `--store` option. The cram evidence digests selected
source carriers, the prelude tree, and a nearby persistent store before and
after a check. It also pins empty success stderr and absence of a residual
analysis directory. The claim is limited to disposable analysis writes, not
zero filesystem writes.

## Exact accepted source contract

The only accepted `workspace-v0` roots are:

1. a closed lambda that directly calls the exact `workspace.live` or
   `workspace.dry-run` hash with its policy, simulators, and a zero-argument
   body thunk; or
2. a closed lambda whose direct head is exact `governance.with-sequence`, whose
   sequence lambda directly calls exact `workspace.live-layer`, and whose body
   is a recursive chain of one or more exact `workspace.forward-layer` calls.

Every head, arity, argument position, sequence argument, simulator argument,
zero-argument thunk, and policy-binder thread must match. Policy binders must be
distinct. The root's closed outward row must equal `{Audit,
GovernanceApprovalV1, Secret, Fs, Judge, Net}` for live and forwarded-live roots
or `{Audit, Judge}` for dry roots; a closed residual effect that the fixed report
cannot represent fails E1413. Exact trusted-boundary occurrence budgets reject
an additional nested live, dry, layered, or sequence-owner boundary that would
be absent from the report. The recursive checker supports arbitrary finite
forwarding depth; the tests pin direct dry, direct live, one-forward, and
two-forward shapes. Report order is inner-to-outer: each forward layer followed
by the live leaf. Inert references, wrong binder wiring, open aliases, missing
roots, multiple roots, and extra trusted boundaries are not evidence and fail
E1413.

The environment check pins exact HASH_V0 identities for the Workspace effect
and operations, live/dry and layered handlers, policy binders, gates,
normalizers, summarizers, drivers, simulators, `governance.with-sequence`,
`debug.inspect`, and the `Eval`, `Fs`, `Net`, and `Secret` effects.
The `State`, `Audit`, `Judge`, and `GovernanceApprovalV1` control effects are
pinned as well. Mutable names must still resolve to those hashes. A same-kind
`workspace.live` shadow fails E1400 even when the source root separately names
the original exact hash.

## Reachability and diagnostics

Traversal starts from the accepted root and follows every source-owned term
dependency. Recursive groups are followed through `GroupRef` member hashes;
handler clauses contribute their operation identities; live level-zero
unquote splices are decoded as resolved Kernel expressions; nested inert quote
data remains data. Traversal stops only at exact trusted membrane boundaries.

The hostile fixtures pin:

- E1412 for direct or locally handled `Eval`, same-group `Eval`, and `Eval`
  inside a live unquote splice;
- E1407 independently for raw `Fs`, `Net`, and `Secret` operations outside the
  Workspace boundary;
- E1408 for direct source-owned `Audit` and `State` handler identities, while
  exact `with-sequence` and membrane terms remain trusted traversal stops;
- E1409 for reachable `debug.inspect`;
- E1400 for mutable same-kind profile shadowing; and
- E1413 for open, absent, ambiguous, inert, miswired, extra-boundary, or
  residual-authority source roots and for top-level expressions. Residual-row
  coverage includes both canonical `Console` and a source-defined effect.

Diagnostics are sorted by source location, code, then cause. The locally
handled Eval fixture deliberately reports both the performed operation and the
handler-clause identity; security findings are accumulated rather than hidden
by the first match. Source-specific next steps say to remove Eval entirely,
route raw actions through Workspace, remove generic inspection and Secret
serialization, or restore the exact closed call grammar.

## Stable success report

The text report is `governance-check-v1`. The compact JSON contract is
`jacquard-governance-check-report-v1` with the exact ordered top-level keys:

```text
schema, profile, facade, live, dry, policy_binders,
layers, operations, runtime_identities
```

Facade and handler facts use `introduced_row`: the reusable terms retain open
effect tails, so the report does not mislabel the displayed additions as their
complete closed rows. A forwarding layer reports all five effects explicit in
its verified scheme: `Audit`, `GovernanceApprovalV1`, `State`, `Judge`, and
`Workspace`. Operations include frozen identity, authority envelope, normalizer,
and summarizer. Drivers, gates, and simulators are verified internally but
intentionally absent from the public schema.

The `.jac` and `.jqd` evidence carriers render byte-identical compact JSON.
Repeated reports compare byte-for-byte, and the JSON transcript is digest
pinned. Runtime `Call`, policy, assessment, Proposal, decision, driver, and
simulator value identities are dynamic. The report says so and hands review to
`jac governance verify-run BUNDLE`; GM.16 does not invent source-time runtime
provenance.

## Claim boundary

GM.16 proves static identity, exact call topology, closed source-owned rows,
and the listed reachability exclusions for one canonical `workspace-v0` source
artifact. It proves that the check itself performs no Jacquard evaluation or
world action and leaves source, prelude, and nearby persistent-store evidence
unchanged.

It does not prove that a checked function was later called, that runtime policy
or proposal bytes match a source-time guess, that a driver or simulator ran,
that an external provider performed an action, that a published head is
authentic, that resources are path-scoped, or that rollback or safe retry is
possible. Those runtime identities remain the domain of run-bundle verification
and reconciliation. It also does not add a general governance profile language,
arbitrary handler recognition, transformed forwarding, or a new serialization.

## Executable evidence

- `test/test_governance_source_check.ml` pins direct dry plus exact 0/1/2 live
  topology, every hostile reachability class, residual outward authority,
  same-kind shadowing, report fields, schema key order, operation authority,
  introduced rows, and the dynamic-runtime handoff.
- `test/cli/governance-check.t` pins public CLI output, surface/bootstrap parity,
  deterministic bytes, isolated storage, immutable input/store digests,
declaration-only refusal before evaluation, all hostile diagnostics, and
  usage refusal for unsupported options. Its source-I/O lane also pins E1413 on
  stderr with no randomized analysis-directory name.
- `corpus/governance/workspace-check-*.jqd` and the paired `.jac` carrier are
  declaration-level evidence fixtures, not a new requirement to publish twins
  for ordinary programs.

The successor inventory is 786 compiled Alcotest/QCheck cases, 46 cram
transcripts, and 27 documentation examples across 8 documents.

## Reproduction

Use a fresh per-run temporary directory because the test harness intentionally
uses process-local store names:

```sh
eval "$(opam env)"
mkdir -p "$PWD/.scratch/tmp"
GM16_TMP="$(mktemp -d "$PWD/.scratch/tmp/gm16.XXXXXX")"
export TMPDIR="$GM16_TMP"
opam exec -- dune build --root "$PWD" @all
cd test && ../_build/default/test/test_jacquard.exe test \
  governance-source-check --compact --color=never
cd ..
opam exec -- dune runtest --root "$PWD" test/cli/governance-check.t
opam exec -- dune runtest --root "$PWD" --force
opam exec -- dune build --root "$PWD" @fmt
opam exec -- dune build --root "$PWD" @doc
scripts/release/reproduce-0.1.sh
sha256sum -c docs/release/governed-membranes/GM16-MANIFEST.sha256
```
