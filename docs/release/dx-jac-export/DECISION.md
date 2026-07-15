# DX.2 Jacquard export decision

Status: accepted for implementation, 2026-07-15.

## Decision

Choose Task 166 Option A: `jac build` accepts public `.jac` input directly and
uses the same surface parse, lowering, name-resolution, and checking path as
`jac check` and `jac hash`. A normal build does not write a `.jqd` file.

Also provide `jac export INPUT.jac -o OUTPUT.jqd` as an explicit
evidence/debug operation. Export is not a required build step and is not an
ordinary publishing workflow. It exists for conformance fixtures, bootstrap
inspection, and native differential evidence that deliberately needs both
carriers.

## Audit and rationale

Task 58 made the resolved kernel the first native IR and chose content hashes
as compilation-unit identity. The implemented native loader in `bin/main.ml`
nevertheless bypassed the shared surface dispatcher and called the bootstrap
reader directly. That carrier restriction is incidental to the CLI loader,
not a native-backend or identity requirement.

Routing `build` through the existing dispatcher is the narrowest fix: it
reuses the parser/lowerer/resolver already exercised by `run`, `check`, and
`hash`, then hands the same resolved `Kernel.top` values to the unchanged
checker and native backend. The explicit export operation reuses that loader
and `Printer.print_all`; it does not introduce a second lowering pipeline,
identity system, kernel form, store format, or prelude format.

## Contract

- Input syntax is selected by extension or `--syntax`, exactly as for the
  other source commands. `build` accepts `.jac` and retained `.jqd` input.
- Export resolves against the selected prelude context, then emits canonical
  bootstrap notation for resolved tops. Repeated exports under one resolution
  context are byte-identical.
- Re-parsing the export yields the same canonical top/member hashes as the
  source under that context. Quote payloads retain the versioned
  `surface-ref-v0` constructor/operation encoding, so namespace intent is not
  collapsed inside unresolved code data.
- Export deliberately erases comments, formatting, spans, documentation, and
  provenance metadata. Those are excluded from semantic identity and are not
  promised to round-trip through the bootstrap carrier.
- Output creation is exclusive and atomic: a synced same-directory temporary
  is hard-linked into place without replacement, the parent directory is
  synced after publication and temporary cleanup, and failures roll back the
  destination. Cleanup failures are diagnosed explicitly rather than hidden.
- Stdin and non-regular/non-seekable inputs are refused with a diagnostic. A
  named input is opened once in nonblocking mode, checked with `fstat`, and
  read through that same descriptor, so a FIFO cannot block the command and a
  path replacement cannot redirect the read. Callers should materialize stdin
  before exporting.
- Ordinary programs and demos do not gain generated or checked-in twins.
  Paired `.jac`/`.jqd` files remain curated conformance evidence only.
