# Jacquard Core 0.1 Claim Matrix

This matrix is deliberately falsifiable: every major claim names the test,
cram, or demo that currently proves it, plus caveats where the proof is partial.

| claim | why it matters | proving test/cram/demo | negative test | known caveat |
|---|---|---|---|---|
| Metadata/provenance do not affect identity | provenance must not fork content hashes | `test/test_canon.ml` meta mutation; `test/cli/store.t`; `test/cli/escrow.t` | origin sidecars survive rename in `test/cli/store.t` | provenance sidecar format is simple text |
| Formatting/comments do not affect identity | formatter can be used in review without dirtying hashes | `test/test_fmt.ml`; `test/gauntlet/formatter-diff.t`; `test/cli/escrow.t` | semantic edit in `test/test_canon.ml` changes hash | top-level comment-only variants are pinned; arbitrary metadata injection is unit-tested |
| Alpha-equivalent locals hash equal | local names are not semantic identity | `test/test_canon.ml`; `test/test_gauntlet_hashing.ml` | shadowing-sensitive negative in `test/test_gauntlet_hashing.ml` | byte-identical recursive twins may swap member hashes on rename; group hash stays stable |
| Recursive SCC reorder is stable | generated declarations can reorder without identity churn | `test/test_canon.ml`; `test/test_gauntlet_hashing.ml` | literal edit changes hash in `test/test_canon.ml` | very large symmetric tie classes are rejected by `E0505` |
| Same model, same hash, different inference handlers | M3 thesis: algorithm is a handler, not a model rewrite | `test/cli/infer.t`; `test/test_infer.ml` | hash compared before/after enumerate/lw | only file/hash stability is claimed, not algorithmic equivalence for all models |
| Public surface demos preserve kernel identity | `.jac` is a projection, not a second semantics | `test/cli/demos.t`; `test/cli/infer.t`; `test/test_surface_twins.ml` | paired `.jac`/`.jqd` hash outputs are compared byte-for-byte | bootstrap remains supported as the internal/debug format of record |
| Enumeration is exact on discrete models | exact posterior must be available for finite support | `test/test_infer.ml`; `test/test_dist_lib.ml`; `test/test_gauntlet_dist.ml` | impossible observation returns `E0901` | continuous distributions are out of scope |
| Likelihood weighting is seeded and reproducible | approximate inference must be reproducible in CI | `test/test_infer.ml`; `test/cli/infer.t`; `test/cli/dist.t` | different seed differs in unit test | stochastic accuracy is bounded by sample count, not exact |
| Deep multi-shot resumptions work | handlers are the semantic core | `test/test_handlers.ml`; `test/test_gauntlet_handlers.ml` | clause-body same-op escapes outward | escaped resumptions are allowed and pinned by gauntlet |
| `fault.all` explores exactly `2^n` paths | fault simulation must not silently miss branches | `test/test_replay.ml`; `test/cli/escrow.t` | budget refusal `E0905` | retry demo distinguishes double-fault proof from triple-fault failure |
| Unhandled world effects require grants | no ambient authority | `test/cli/world.t`; `test/cli/manifest.t`; `test/cli/hostile-demo.t`; `test/cli/escrow.t` | ungranted effects exit 3 | root grants are whole-effect, not path-scoped |
| Eval does not imply Net/Fs/etc. | eval must not become all authority | `test/gauntlet/eval-capabilities.t`; `test/cli/tools.t` | eval-only net payload dies unhandled | direct hash refs in eval payload are not rejected if matching world grant exists |
| Handler removes only handled effects | attenuation must be precise | `test/test_check.ml`; `test/gauntlet/checker-effects.t` | console handler leaves net in row | effect granularity is per effect, not per object |
| Higher-order functions propagate rows | rows must not leak through function arguments | `test/gauntlet/checker-effects.t`; `test/test_check.ml` | manifest fails without net | stored effectful top-level bodies are rejected (`E0815`) |
| Test cannot touch world effects | hermetic tests are cacheable and grant-free | `test/cli/warp.t`; `test/test_warp.ml` | world case is refused without grants | effect is enforced by checked test type, not naming convention |
| Public surface programs can define Warp suites | demos should test the code users actually read | `test/cli/warp.t`; `test/cli/case-studies.t` | surface test files still reject top-level expressions with `E1001` | test discovery remains type-directed and declaration-only |
| WorldTest can touch world effects only in its lane | world tests must be explicit | `test/cli/warp.t`; `test/cli/escrow.t` | refused until `--allow fs,clock,console,net` | WorldTests are intentionally not cached |
| Record/replay strict drift fails closed | fixtures must detect changed world requests | `test/test_replay.ml`; `test/cli/tools.t`; `test/cli/escrow.t` | malformed or drifted replay reports diagnostics/diff | loose replay is separate and documented as loose |
| Counterfactual fork specs fail closed when malformed | debugger must not silently ignore bad forks | `test/cli/tools.t` | invalid `--fork garbage` is `E0104` | fork grammar is intentionally small: `N=FORM` |
| `dist-diff` rejects type-mismatched models | posterior diffs over different result types are meaningless | `test/cli/tools.t` | int vs text model fails `E0801` | equality is by rendered discrete support values |
| Dry-run performs no world mutation | consequence preview must be safe | `test/cli/tools.t`; `test/cli/escrow.t` | dry-run refuses eval (`E1002`) | reads and clock are forwarded observations |
| Cache reruns zero tests on reformat/comment | semantic identity must drive test selection | `test/cli/warp.t` | corrupted cache reruns instead of trusting | top-level rename cache case is not separately pinned |
| Cache reruns dependents on semantic dependency edit | Warp must not miss affected tests | `test/cli/warp.t`; `test/test_warp.ml` | leaf edit reruns one dependent and fails honestly | coverage is definition-level |
