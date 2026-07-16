# DX.2 direct build and bootstrap export evidence

Status: successor evidence after Jacquard Core 0.1 and the surface-syntax
release. The frozen 0.1 and SS.21/SS.22 inventories describe their reviewed
artifacts and are not retroactively updated by DX.2.

## Current inventory

- Alcotest/QCheck cases: `641`
- Cram transcript files: `36`

The test count includes six DX.2 filesystem-boundary cases. The successor cram
transcripts added after the frozen release are `test/cli/export.t` and
`test/cli/task-values.t`.

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
