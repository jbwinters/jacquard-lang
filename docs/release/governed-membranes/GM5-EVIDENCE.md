# Governed Membranes GM.5 Evidence

Status: reconstructible GM.5 overlay on validated GM.1 commit `b5587ce`.

GM.5 releases the blessed once `Judge` interface and the deterministic
assessment handlers required by the GM.0 charter. It reuses GM.1's exact
versioned `GovernanceCall` and `GovernanceAssessment` carriers; it does not
introduce parallel call, risk, or assessment vocabulary.

## Contract

- `judge.assess` is once and has frozen interface identity
  `9b677b5e2c3ec8521c5d5dfac321ae361a959565e1cbf082fec4512199977354`.
- `judge.rules` accepts a pure call-to-assessment function. Raw-world effects
  cannot fit that parameter and therefore cannot be hidden behind `Judge`.
- `judge.fixed` replays one validated assessment for every request.
- `judge.scripted` consumes a list in request order. Exhaustion throws before
  resumption; it never reuses the last entry or invents a default.
- Every deterministic handler calls `governance.validate-assessment` before
  resumption. The closed field types validate risk, reasons, and evidence, and
  the verifier rejects non-finite or out-of-range confidence from public
  constructor escape.
- `judge.model` requires an assessor with an explicit `Infer` row and retains
  `Infer` outward. It returns the same v0 point assessment. Posterior values,
  `Dist`, and uncertainty policy remain deferred to G5.
- Validation failure is the visible `Throw Text` effect. Exact inferred
  signatures are pinned in both the prelude and Judge suites.

## Executable evidence

`test/test_judge.ml` pins the interface and operation hashes, once mode, exact
handler rows, deterministic fixed/rules/scripted replay, script exhaustion,
malformed assessment refusal, all four field types, model assessments whose
reasons are derived from distinct scripted `Infer` completions, malformed
model-output refusal through the same adapter, and a checker refusal for a
Net-using rules callback.
`test/test_effect_taxonomy.ml`
requires the machine TSV, Markdown table, typed registry, prelude declaration,
ring assignment, and frozen hash to agree. `test/test_prelude.ml` additionally
forces every handler and compares its full elaborated signature.

The prelude hash golden records the effect, operation, validator, and each
handler identity. `prelude/operation-modes.manifest` reviews `judge.assess` as
once, and `prelude/rings.manifest` assigns the complete layer to ring 3.

## Reproduction

```sh
eval "$(opam env)"
mkdir -p "$PWD/.scratch/tmp"
export TMPDIR="$PWD/.scratch/tmp"
opam exec -- dune build --root "$PWD" @all
opam exec -- dune runtest --root "$PWD" --force
opam exec -- dune build --root "$PWD" @fmt
opam exec -- dune build --root "$PWD" @doc
sha256sum -c docs/release/governed-membranes/GM5-MANIFEST.sha256
```

The GM.5 checkout contains 619 compiled Alcotest/QCheck cases and 32 cram
transcript files. Historical GM.1 and effect-taxonomy evidence packs remain
unchanged; this file and manifest are a successor overlay.
