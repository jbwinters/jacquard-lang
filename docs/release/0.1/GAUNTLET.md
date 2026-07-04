# Release Gauntlet

The gauntlet is the adversarial layer: tests whose purpose is not broad
coverage, but pressure on the semantic promises most likely to fail.

## Present

CLI gauntlet files:

- `test/gauntlet/checker-effects.t`
- `test/gauntlet/eval-capabilities.t`
- `test/gauntlet/formatter-diff.t`
- `test/gauntlet/hashing.t`

OCaml gauntlet suites:

- `test/test_gauntlet_handlers.ml`
- `test/test_gauntlet_hashing.ml`
- `test/test_gauntlet_dist.ml`

Related adversarial suites already present:

- `test/test_handlers.ml`
- `test/test_check.ml`
- `test/test_canon.ml`
- `test/test_infer.ml`
- `test/test_replay.ml`
- `test/test_warp.ml`
- `test/cli/tools.t`
- `test/cli/warp.t`
- `test/cli/escrow.t`

## Currently Pinned Attacks

| seam | present proof |
|---|---|
| same-op in opclause escapes same handler | `test/test_handlers.ml` |
| same-op under resumed continuation is deep | `test/test_gauntlet_handlers.ml` |
| nested same-op handler shadowing | `test/test_gauntlet_handlers.ml` |
| return clause outside handled region | `test/test_gauntlet_handlers.ml` |
| escaped resumption is reusable | `test/test_gauntlet_handlers.ml` |
| abort skips pending argument evaluation | `test/test_gauntlet_handlers.ml` |
| eval does not install net | `test/gauntlet/eval-capabilities.t` |
| pure eval is still gated | `test/gauntlet/eval-capabilities.t` |
| higher-order row leak | `test/gauntlet/checker-effects.t` |
| handler removes only handled effect | `test/gauntlet/checker-effects.t` |
| shadowing-sensitive alpha hash | `test/test_gauntlet_hashing.ml` |
| three-member SCC reorder | `test/test_gauntlet_hashing.ml` |
| conditional dynamic branch count | `test/test_gauntlet_dist.ml` |
| duplicate support mass | `test/test_gauntlet_dist.ml` |
| zero-prob branch pruning | `test/test_gauntlet_dist.ml` |
| cloudy/sprinkler posterior | `test/test_gauntlet_dist.ml` |
| dry-run no mutation and eval refusal | `test/cli/tools.t`, `test/cli/escrow.t` |
| malformed counterfactual fork | `test/cli/tools.t` |
| dist-diff type mismatch | `test/cli/tools.t` |
| Warp cache no rerun on comment edit | `test/cli/warp.t` |
| Warp dependency edit reruns dependent | `test/cli/warp.t` |

## Proposed But Not Yet Present

| omitted test | reason omitted | risk | blocks 0.1? |
|---|---|---:|---|
| Reject direct resolved `ref` inside eval payload | current policy allows hash refs; rejection is a policy/implementation change | high | no, if documented |
| Eval cannot forge kind-confused refs | kind checks exist generally, but eval-specific hostile matrix is absent | medium | no |
| Eval of ill-typed code has quoted-code span-ish location | dynamic eval diagnostics exist; source mapping inside generated code is coarse | medium | no |
| Manifest check never runs code with host counter | checker architecture implies it, but no direct counter unit test | medium | no |
| Top-level closed-row eta-expansion seams | current design rejects effectful stored bodies with `E0815`; eta expansion is not a supported feature | medium | no |
| Deep-handler clause throw escaping perform-site catches | `net.try-fetch` documents and works around this; direct hostile test could be clearer | medium | no |
| Pattern exhaustiveness full gauntlet D1-D9 | many cases exist in `test/test_exhaust.ml`; not all proposed cases are present | low | no |
| Store rename cache reruns zero tests | semantic rename/diff is tested; Warp cache rename-specific transcript is absent | low | no |
| Direct object-files-identical store rename shell test over sha256 sums | store rename behavior is in `test/cli/store.t`; exact sha shell diff not present | low | no |
| All malformed 27-form arity variants generated | kernel accept/reject table covers the form set, but not every wrong arity permutation | low | no |

## Release Assessment

No omitted gauntlet item blocks 0.1 because the high-risk omission, direct refs
inside eval payloads, is documented as a known caveat and not claimed as a
rejected behavior. The branch should not claim typed staging, macro security, or
object-capability granularity.
