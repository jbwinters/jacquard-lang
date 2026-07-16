# Documentation doctests

The `runtest` rule in this directory audits executable Jacquard examples in
`README.md`, `docs/effect-taxonomy.md`, `docs/concurrency.md`, `docs/tutorial.md`, `docs/stdlib.md`,
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
4. Run `mkdir -p $PWD/.scratch/tmp` followed by
   `TMPDIR=$PWD/.scratch/tmp opam exec -- dune runtest test/docs-doctest`.

The extractor rejects missing and orphan fixtures, duplicate names or fields,
unknown fields and modes, reused fixtures, missing expectations, and byte drift.
The runner strips inherited `JACQUARD_*` variables, passes the repository
prelude with `--prelude`, captures stdout and stderr separately, and compares
both exactly before checking the exit code. It performs no output normalization.

Blocks that are signatures, equations, transcripts, data-format sketches, or
pseudocode must not use the `jacquard` fence tag. Give each excluded block a
specific adjacent reason it cannot be complete executable source; a document-
wide disclaimer is not sufficient.
