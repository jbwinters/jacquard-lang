# Jacquard Core 0.1 Freeze Surface

Candidate base: `738dc8e`  
Evidence branch predecessor: `7d7733f`  
CLI version: `0.1.0`

This file records the surfaces treated as frozen for the 0.1 release
candidate. Changes to these surfaces after RC require an explicit freeze update.

## Identity

- hash algorithm: `HASH_V0`
- implementation: `src/hash.ml`
- digest: SHA-256 via `digestif`
- rendered hash: lowercase hex, 64 characters
- canonical serialization: `spec/serialization.md`, format `V0`
- metadata law: spans, comments, origin, docs, retained names, and hygiene marks
  are excluded from content hashes

## Store

- object format: `store/objects/<decl-hash>.jqd`
- mutable name index: `store/names.jqd`
- provenance sidecar: `store/objects/<decl-hash>.origin`
- object files are immutable once written
- derived member/constructor/op hashes do not have separate object files
- store code: `src/store.ml`

## Prelude and Ring-0

- prelude load order: sorted `prelude/*.jqd`
- ring manifest: `prelude/rings.manifest`
- ring-0 signature freeze: `corpus/golden/ring0-freeze.golden`
- ring audit: `test/test_rings.ml`

The public ring-0 surface includes primitive/data names, pure dictionaries,
pure list/option/result/bool utilities, and no world effects. The exact list is
the golden file, regenerated only with:

```sh
opam exec -- dune exec test/gen_freeze_goldens.exe
```

## Effects and Operations

Effect declarations in `prelude/03-effects.jqd`:

- `eval`: `eval-code`
- `abort`: `abort`
- `throw`: `throw`
- `state`: `get`, `put`
- `emit`: `emit`
- `console`: `print`, `read-line`
- `clock`: `now`, `sleep`
- `net`: `fetch`
- `fs`: `read`, `write`, `list-dir`
- `infer`: `complete`

Additional library effects:

- `dist`: `sample`, `observe` in `prelude/06-dist.jqd`
- `check`: `check`, `fail` in `prelude/15-warp.jqd`
- `fault`: `flaky` in `prelude/18-fault.jqd`

Grantable root authorities in 0.1:

- `console`
- `clock`
- `fs`
- `net`
- `infer`
- `dist`
- `eval`

Pure effects such as `abort`, `throw`, `state`, `emit`, `check`, and `fault`
are handled by library code and are not grantable root effects.

## CLI

Top-level commands:

- `check`
- `diff`
- `dist-diff`
- `fmt`
- `hash`
- `infer enumerate`
- `infer lw`
- `replay`
- `run`
- `store add`
- `store name`
- `store rename`
- `test`

Important options:

- `run`: `--allow`, `--seed`, `--dry-run`, `--origin`, `--infer-cache`,
  `--prelude`, `--store`
- `check`: `--print-sigs`, `--manifest`, `--origin`, `--prelude`
- `test`: `--allow`, `--seed`, `--cache-dir`, `--no-cache`, `--exhaustive`,
  `--samples`, `--budget`, `--coverage`
- `replay`: `--to`, `--fork`, `--compare`
- `dist-diff`: `--tolerance`, `--sweep`

CLI exit codes pinned in `bin/main.ml` and cram tests:

- `0`: success
- `1`: diagnostics
- `2`: runtime error
- `3`: unhandled/ungranted effect
- `123`/`124`/`125`: Cmdliner/common command errors

## Error Catalog

- catalog: `docs/errors.md`
- test: `test/test_errors_doc.ml`
- current catalog range: `E0101` through `E1002`, with warnings `W0301` and
  `W0801`
- policy: codes are stable, never reused, never renumbered

## Trace and Replay

- record/replay library: `prelude/17-codec.jqd`
- canonical world seam in 0.1: `net.record` / `test.replay`
- log payload: quoted `Code` form containing ordered operation entries
- strict replay: positional, fails on wrong op/request/result drift
- loose replay: separate API, intentionally less strict
- CLI counterfactual grammar: `--fork N=FORM`

## Dry-Run

- dry-run is a runtime handler installation, not a new language feature
- dry-run refuses `eval`
- forwarded observations: console, clock, fs.read
- audited/simulated consequences: fs.write, net.fetch, infer.complete, dist
- proof transcript: `test/cli/tools.t` and `test/cli/escrow.t`

## Dist-Diff

- output format: line-oriented posterior deltas, support gained/lost, or
  `no divergence`
- type gate: mismatched model result types are rejected before comparison
- cache key: content hash of enumerated model
- proof transcript: `test/cli/tools.t`

## Counterfactual Fork Specs

- grammar: `N=FORM`, where `N` is an operation index and `FORM` is a parseable
  Jacquard form
- malformed specs fail closed with `E0104`
- proof transcript: `test/cli/tools.t`
