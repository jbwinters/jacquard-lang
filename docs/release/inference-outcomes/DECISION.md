# Typed inference outcomes (INF.1)

Status: accepted. Scope: the application-facing discrete inference API
(`dist.*` in the prelude) and `jacquard infer`.

## Problem

Before this change, the library and the CLI disagreed about failure:

- `dist.enumerate` returned `+nan.0` weights for impossible evidence, while
  `jacquard infer enumerate` reported E0901 for the same model.
- An enumeration path whose weight underflowed to zero was pruned as though it
  were impossible.
- NaN and infinite weights printed as a posterior.
- `dist.sample-lw` stopped the program with E0901 and offered no value to
  inspect.

No result said whether it was exhaustive, which seed or bound produced it, or
how much work was done.

## Decision

**D-INF1.1: versioned identities, released ones unchanged.**
`dist.enumerate-v1` and `dist.sample-lw-v1` are new canonical identities
(`prelude/31-inference-outcome.jqd`). They follow the `-v1` precedent for
changed return types. `dist.enumerate`, `dist.sample-lw`, `enum-run` and
`normalize` keep their hashes and behaviour: the prelude hash golden only
grows.

**D-INF1.2: one typed result, built from the existing `result` type.**

```text
dist.enumerate-v1 : (() ->{Dist | e} a, Int) ->{| e}
                      Result InferenceFailureV1 (InferencePosteriorV1 a)
dist.sample-lw-v1 : (() ->{Dist | e} a, Int, Int) ->{| e}
                      Result InferenceFailureV1 (InferencePosteriorV1 a)
```

`InferenceFailureV1` has three cases:

- `InferenceImpossibleV1`: no surviving path or run.
- `InferenceExhaustedV1`: the budget was reached before every path was explored.
- `InferenceNumericFailureV1`: carries a reason, one of `InferenceUnderflowV1`,
  `InferenceNonFiniteV1` or `InferenceNegativeMassV1`.

Every outcome, success or failure, carries `InferenceMetadataV1`:

- `method`: exact enumeration or likelihood weighting.
- `complete`: true only when enumeration reached every terminal path; never for
  sampling.
- `seed`: `none` for enumeration.
- `bound`: the terminal-path budget, or the sample count.
- `explored`: terminal paths reached, or runs executed.

No new syntax or abstract type is needed.

**D-INF1.3: one classification contract.** `dist.classify-v1` in the prelude
and `Infer_dist.classify` in OCaml apply the same checks, in this order:

1. Any surviving weight is non-finite: non-finite.
2. Any surviving weight is negative: negative mass.
3. Nothing survives: impossible.
4. The total is non-finite (overflow): non-finite.
5. The total is zero (every surviving path underflowed): underflow.
6. Otherwise: the normalized posterior.

What "surviving" means:

- An enumeration path is pruned only when one of its factors is exactly zero. A
  pruned path still counts against the budget and in `explored`.
- A path whose product merely underflows survives, so underflow is not
  impossibility.
- A sampled run is impossible when an observation factor is exactly zero or it
  draws from a categorical whose support has zero total mass. Impossible runs are
  dropped, not weighted zero.

Both drivers multiply a path's factors forward, in model order. The library
threads the weight through its handler instead of scaling results on the way
back, so both see the same binary64 path weight even when the order decides
whether a product underflows. The test suite checks library/CLI agreement model
by model, including such an order-sensitive model. Posteriors agree to
within floating-point summation order: the library leaves entries unmerged,
while the CLI merges them by rendering.

**D-INF1.4: explicit budgets and no partial posteriors.** `dist.enumerate-v1`
takes a maximum number of terminal paths. Attempting one more path yields
`InferenceExhaustedV1`, with `complete = false` and `explored = budget`. A
non-positive budget is exhausted before the model runs, with `explored = 0`.
The budget counts terminal paths: a model that loops before reaching one is
not bounded by it. `jacquard infer enumerate
--max-branches N` gives the CLI the same bound; it is unbounded by default.
Sampling is bounded by its sample count and is never described as exhaustive.

**D-INF1.5: the CLI applies the contract.**

- `jacquard infer enumerate` and `jacquard infer lw` report:
  - impossible: E0901 (unchanged)
  - numerical failure: E0917 (new)
  - exhausted budget: E0918 (new)
- `--metadata` prints one extra line after the posterior.
- `--samples` and `--max-branches` must be positive integers; anything else is a
  usage error, exit 124.
- The `dist-diff` command enumerates through the same driver.

**D-INF1.6: native parity.** The seeded runs come from a new builtin,
`dist.sample-lw-weights-v1`, implemented in the interpreter and the C runtime.
It uses the same stream and run isolation as `dist.sample-lw`. Classification
and budgeted enumeration are ordinary prelude code, so both engines run them.
`test/native-gauntlet/g46-inference-outcomes.jqd` pins byte-identical output.

## Behaviour changes at the CLI

| model | before | after |
|---|---|---|
| every enumeration path underflows | E0901 (pruned as impossible) | E0917, underflow |
| a NaN or infinite weight | a NaN/inf posterior table | E0917, non-finite |
| a negative categorical weight | a table with negative or >1 probabilities | E0917, negative mass |
| `infer lw` drawing only from zero-mass categoricals | a posterior | E0901 |
| `infer lw --samples 0` | E0901 | usage error (exit 124) |

| `infer lw` where some runs are impossible | the impossible values listed with probability 0 | impossible runs are dropped, so those rows are absent |
| `infer enumerate` where some paths underflow but others do not | underflowed paths pruned, so their values were absent | underflowed paths survive and are listed with probability 0 |

Otherwise, a well-formed model prints the same posterior as before, provided
its total is positive and representable and no path underflows.

## Migration

| today | move to | handle |
|---|---|---|
| `dist.enumerate(model)` | `dist.enumerate-v1(model, max-paths)` | `ok(InferencePosteriorV1(entries, meta))` holds the same unmerged weights (normalized by division rather than by multiplying by a reciprocal, so the last bit can differ); match `err(...)` instead of testing for NaN |
| `dist.sample-lw(model, n, seed)` | `dist.sample-lw-v1(model, n, seed)` | entries are one per surviving run: `dist.tally(entries, eq)` recovers the merged table, without the zero-probability rows of impossible runs |
| scripts parsing `jacquard infer` | unchanged output | add `--metadata` to record method, completeness, seed and bound; treat E0917 and E0918 as distinct from E0901 |

Choose a budget from the model's finite support: the product of the support sizes
along the deepest path bounds the number of terminal paths.

## Non-claims

- Sampled posteriors are estimates. `complete = false` states that, and
  nothing here bounds their error.
- The classification detects non-finite, negative and underflowed mass. It does
  not validate distributions elsewhere; for example, a categorical weight above
  one still enumerates.
- A total that overflows in one summation order but not another could, in
  principle, classify differently in the library (unmerged, right fold) and the
  CLI (merged). The tests pin the ordinary overflow case, which agrees.
- The released `dist.enumerate` and `dist.sample-lw` are not deprecated
  or removed; their errata remain documented in `docs/stdlib.md` §12.

## Evidence

- `test/test_inference_outcomes.ml` (8 cases):
  - a normalized posterior with metadata
  - impossible evidence (observation, all-zero support) in the library, the
    driver, the CLI code and sampling
  - underflow distinct from impossibility
  - non-finite, NaN, negative and overflowing-total failures
  - bounded exploration: exact budget, one path over, zero budget, and pruned
    paths spending budget
  - seeded reproducibility, and agreement with `dist.sample-lw` on the same stream
  - library/CLI agreement across nine models
  - the released identity is unchanged
- `test/cli/inference-outcomes.t`: CLI codes, flags and metadata.
- `test/native-gauntlet/g46-inference-outcomes.jqd`: native parity.
- `corpus/golden/prelude-hashes.golden`: additions only.
