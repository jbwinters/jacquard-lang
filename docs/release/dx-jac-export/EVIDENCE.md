# DX.2 direct build and bootstrap export evidence

Status: successor evidence after Jacquard Core 0.1 and the surface-syntax
release. The frozen 0.1 and SS.21/SS.22 inventories describe their reviewed
artifacts and are not retroactively updated by DX.2.

## Current inventory

- Alcotest/QCheck cases: `786`
- Cram transcript files: `46`
- Doctest examples: `27` across 8 documents

The test count includes six DX.2 filesystem-boundary cases and six DX.5/DX.7
structural-depth and diagnostic-compatibility cases. The successor cram
transcripts added after the frozen release include `test/cli/export.t`,
`test/cli/task-values.t`, the final C0-C3 concurrency evidence transcript, and
the GM.8 governance-verifier analysis lane. GM.14A adds five compiled
run-bundle cases and one public verifier transcript. GM.14B adds five compiled
action-reconciliation cases and one public reconciliation transcript.
DX.4 adds four compiled diagnostic-contract cases and one public diagnostic
format transcript.
GM.13A adds thirteen compiled approval-queue cases covering durable framing,
restart recovery, authorization, and process/Domain consumption races.
GM.13B adds eight compiled approval-bridge cases covering frozen Store
identities, guarded routing, exact runtime/Code conversion, Audit order,
reviewer races, replay, and concurrent at-most-once resumption.
GM.12A adds eight compiled layer-aware governance-verifier cases covering
qualified same-operation forwarding, topology, lineage, authority, and tokens.
GM.12B adds four compiled Workspace-forwarding cases and two Once same-op
handler cases. The native differential loop also gains two standalone twins;
the existing cram transcript count is unchanged.
GM.15 adds two hostile-boundary/replay cases and one exhaustive 698-path
transcript; its native differential twin is closed and deterministic.
GM.16 adds three canonical Workspace source-verification cases and one public
governance-check transcript.

## Proved behavior

- `jac build FILE.jac -o PROGRAM` and retained `.jqd` input share the ordered
  parse/lower/resolve/check/native path; direct builds do not emit twins.
- `jac export INPUT.jac -o OUTPUT.jqd` is byte-deterministic under one prelude
  context, and reparsing the output produces the same top and named-member
  hashes as the source.
- Quote namespace intent remains structural through `surface-ref-v0`.
- Input uses one nonblocking descriptor for open, `fstat`, and read; FIFO/stdin
  are refused and path replacement after open cannot redirect the read.
- Publication uses a synced same-directory temporary file, an exclusive hard
  link, a parent-directory sync, temporary cleanup, and another parent sync.
  Sync and cleanup failures roll back or diagnose every artifact.
- Native differential evidence covers quote/code values, deep multi-shot
  handlers, Dist, recursive SCCs, and a Preflight-shaped policy for both direct
  `.jac` and explicitly exported `.jqd` carriers wherever native v1 is
  eligible.

## Reproduction

```sh
eval "$(opam env)"
mkdir -p "$PWD/.scratch/tmp"
export TMPDIR="$PWD/.scratch/tmp"
opam exec -- dune build @all
opam exec -- dune runtest --force
opam exec -- dune fmt
scripts/release/check-surface-syntax-manifest.sh
```

The exact fixture commands and stdout/stderr/exit comparisons are pinned in
`test/cli/export.t`; filesystem fault injection is in `test/test_export.ml`.
