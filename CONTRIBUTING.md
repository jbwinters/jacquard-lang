# Contributing to Weft

This document pins the engineering conventions for the Weft prototype. The
development plan (`docs/development-plan.md`) is the execution queue; the spec
(`spec/weft-kernel-ast-m0.md`) is the source of truth for language behavior.

## Module naming

- One module per concept, lowercase file names: `src/form.ml`, `src/reader.ml`.
- Interface files (`.mli`) are added once a module's API is stable enough to
  pin; until then, doc comments in the `.ml` state the public contract.
- Internal helper modules nested inside their user, not split into files.

## Error convention

- Library code returns `('a, Diag.t list) result`. No exceptions across public
  API boundaries.
- Exceptions are only for internal invariant violations that indicate a bug in
  Weft itself, and their constructors are prefixed `Bug_`.
- Every diagnostic has a stable code (`E0001`-style for errors, `W0001`-style
  for warnings). Codes are never reused or renumbered once released.
- Public functions in touched modules carry doc comments stating the contract
  and failure modes.

## Test naming

- Test files live in `test/` and are named `test_<module>.ml` after the module
  under test; the runner is `test/test_weft.ml`.
- Alcotest suite names match the module (`"form"`, `"reader"`); test case
  names say what is asserted, e.g. `"equal_ignoring_meta ignores span"`.
- QCheck property tests are prefixed `prop_` and state the property, e.g.
  `prop_roundtrip_print_parse`.
- Bug fixes add a regression test first, named after the failure.

## Corpus layout

- `corpus/valid/` — `.wft` files that must parse, validate, resolve, and hash
  to their golden values.
- `corpus/invalid/` — `.wft` files that must fail, each with a sidecar
  `.expect` file naming the failing stage and expected diagnostic code.
- `corpus/golden/` — pinned outputs (hashes, printed forms, signatures).
- Every task that adds observable behavior grows the corpus in the same PR.

## PR checklist (mirrors the global definition of done)

- [ ] `dune build @all` and `dune runtest` pass locally and in CI.
- [ ] New behavior has tests in the same PR; bug fixes add a regression test
      first.
- [ ] Public functions in touched modules have doc comments stating contract
      and failure modes.
- [ ] No compiler warnings; `dune fmt` clean.
- [ ] The conformance corpus still passes; it grows if the task added
      observable behavior.
- [ ] No out-of-scope features (see the guardrails in
      `docs/development-plan.md`).
