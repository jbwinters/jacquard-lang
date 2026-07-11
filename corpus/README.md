# Conformance corpus

The corpus is the spec's teeth: every `.jqd` here runs through the full
parse -> validate -> resolve -> hash pipeline on every `dune test`.

## Adding a case (under five lines)

1. Valid: drop `foo.jqd` in `valid/`, then run `dune exec test/gen_surface_twins.exe`
   and `dune exec test/gen_goldens.exe` from the repo root; commit the `.jac` twin and updated
   `golden/hashes.golden`.
2. Invalid: drop `foo.jqd` in `invalid/` plus a `foo.expect` sidecar naming the
   failing stage and diagnostic code:
   `stage: parse|validate|resolve|hash` (first line), `code: E0106` (second line).

## Layout

- `valid/` — must parse, validate, resolve (against the stub prelude names in
  `test/corpus_support.ml`), and hash to the golden values. Every `.jqd` has a same-basename `.jac`
  twin that must resolve to the identical declaration and named-member hashes.
- `invalid/` — must fail at exactly the stage named in the `.expect` sidecar,
  with the expected code.
- `golden/hashes.golden` — pinned `HASH_V0` hashes for every valid file; CI
  fails on any drift.

## Surface twins

`test/gen_surface_twins.ml` deterministically prints ordinary twins. Files listed in
`valid/twins.curated` intentionally retain surface-only sugar that a bootstrap tree cannot remember;
the twin test still checks their semantic identity. `valid/twins.excluded` is the explicit readability
exclusion list and is currently empty: every valid bootstrap form prints nicely after name-aware
resolution. A future entry must name the exact form and follow-up, but remains subject to L1 printer
totality through `jqd { ... }`; readability never permits skipping the L3 twin pipeline.
