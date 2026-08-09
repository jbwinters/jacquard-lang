# Explicit dictionary evidence

This successor evidence supports the contract in
[DECISION.md](DECISION.md). It does not rewrite the frozen Jacquard Core 0.1 or
surface-syntax manifests.

## Current inventory

- Alcotest/QCheck cases: `847`
- Cram transcript files: `51`
- Doctest examples: `28` across 8 documents

The four new compiled cases cover standard and alternate `Num` instances,
cross-store identity, evaluation order, and the public release contract. The
existing native cram file gains explicit-dictionary surface/bootstrap,
quotation, diagnostic, and interpreter/native checks, so the cram file count
does not change.

## Contract-to-evidence map

| contract | evidence |
|---|---|
| canonical and alternate instances are explicit ordinary values | `test/test_stdlib.ml`, `test/cli/native.t` |
| dotted integer names retain the four published hashes | `test/test_stdlib.ml`, `corpus/golden/prelude-hashes.golden` |
| names and values survive independent stores | `test/test_stdlib.ml` |
| generic calls preserve left-to-right evaluation | `test/test_stdlib.ml` |
| effectful methods expose their effect row | `corpus/sigs/27-explicit-dictionaries.jqd`, `corpus/golden/sigs.golden` |
| `.jac`, `.jqd`, quotation, interpreter, and native behavior agree | `test/cli/native.t` |
| exclusions and future compatibility stay explicit | `test/test_surface_laws.ml`, `DECISION.md` |

The identity test checks both the exact old hash and equality with the new
dotted name. Golden regeneration is additive: existing prelude and ring-freeze
lines must stay byte-identical, while new public declarations gain new lines.

## Reproduction

Run from a clean checkout with the repository-local opam switch:

```sh
eval "$(opam env)"
mkdir -p "$PWD/.scratch/tmp"
export TMPDIR="$PWD/.scratch/tmp"
opam exec -- dune build @all
opam exec -- dune runtest --force
opam exec -- dune fmt
git diff --exit-code
opam exec -- dune build @doc
```

Native parity, leak, sanitizer, and seeded-fuzz evidence use the existing
commands in [CI/CD](../../ci-cd.md). Release reproduction uses
`scripts/release/reproduce-0.1.sh`; the historical artifacts it reconstructs
remain unchanged.
