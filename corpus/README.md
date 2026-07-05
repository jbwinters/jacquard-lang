# Conformance corpus

The corpus is the spec's teeth: every `.jqd` here runs through the full
parse -> validate -> resolve -> hash pipeline on every `dune test`.

## Adding a case (under five lines)

1. Valid: drop `foo.jqd` in `valid/`, then run `dune exec test/gen_goldens.exe`
   from the repo root and commit the updated `golden/hashes.golden`.
2. Invalid: drop `foo.jqd` in `invalid/` plus a `foo.expect` sidecar naming the
   failing stage and diagnostic code:
   `stage: parse|validate|resolve|hash` (first line), `code: E0106` (second line).

## Layout

- `valid/` — must parse, validate, resolve (against the stub prelude names in
  `test/corpus_support.ml`), and hash to the golden values.
- `invalid/` — must fail at exactly the stage named in the `.expect` sidecar,
  with the expected code.
- `golden/hashes.golden` — pinned `HASH_V0` hashes for every valid file; CI
  fails on any drift.
