# Documentation doctests

The `runtest` rule in this directory audits executable Jacquard examples in
`README.md`, `docs/effect-membranes.md`, `docs/effect-taxonomy.md`,
`docs/concurrency.md`, `docs/tutorial.md`, `docs/stdlib.md`,
`docs/warp-testing.md`, and `demos/README.md`.

To add or update an example:

1. Put the complete program in `fixtures/NAME.jac`, where `NAME` contains only
   lowercase letters, digits, and hyphens.
2. Add exact expected stdout under `fixtures/NAME.stdout`, or use `empty` when
   that stream must be empty. Do the same for stderr when the example pins a
   diagnostic. Output files are byte-for-byte contracts, including final
   newlines.
3. Embed those exact source bytes in one audited document with an opening fence
   that names every contract artifact:
   ````text
   ```jacquard doctest=NAME mode=check fixture=NAME.jac stdout=NAME.stdout stderr=empty exit=0
   ````
   Use `mode=run` when evaluation is part of the contract. Check mode always
   invokes `check --print-sigs`, so its expectation pins inferred signatures.
   Add `grants=fs,net` only when execution requires those explicit grants.
   Use `mode=build` when a native claim is part of the contract: the fixture
   is compiled with `jacquard build` into the scratch directory and the binary
   runs with the same grants. Add `stdin=NAME.stdin` to feed a run or build
   example its standard input (interactive examples). Pin an expected failure
   as a negative example with `exit=1` and a `stderr=NAME.stderr` artifact
   whose paths are the fixture paths the runner passes (`fixtures/NAME.jac`).
   A copyable command snippet uses a `sh` fence with `mode=commands` and a
   `fixtures/NAME.sh` fixture: it runs under `sh -e` in a fresh scratch
   directory with `jacquard` and `jac` first on the PATH (wrappers for the
   audited binary) and `JACQUARD_PRELUDE` set to the repository prelude, so setup,
   build, and test instructions are checked against the current toolchain
   and stale commands fail the audit.
4. Run `mkdir -p $PWD/.scratch/tmp` followed by
   `TMPDIR=$PWD/.scratch/tmp opam exec -- dune runtest test/docs-doctest`.

The extractor rejects missing and orphan fixtures, duplicate names or fields,
unknown fields and modes, reused fixtures, missing expectations, and byte drift.
The runner strips inherited `JACQUARD_*` variables, passes the repository
prelude with `--prelude`, captures stdout and stderr separately, and compares
both exactly before checking the exit code. It performs no output normalization.
Build artifacts, the native object cache, and command working directories live
under `$TMPDIR/docs-doctest-scratch/NAME` (`TMPDIR` is resolved to an absolute
path once at startup; a commands example runs in its own empty `work/`
subdirectory with the wrappers beside it and the harness's capture files in
`$TMPDIR`, never inside `work/`; under dune that root is the build's own
temporary directory, recreated per example), and the summary line records the `jacquard --version` and prelude the
examples ran against. A commands fixture runs under `sh -e`, which fails on the
first failing simple command; a stale command inside a non-final pipeline stage
is not caught, so write each command on its own line.

Blocks that are signatures, equations, transcripts, data-format sketches, or
pseudocode must not use the `jacquard` fence tag, and bootstrap `.jqd`
implementation patterns are not copyable public examples: advertise ordinary
source as `.jac` fixtures only. Give each excluded block a
specific adjacent reason it cannot be complete executable source; a document-
wide disclaimer is not sufficient.
