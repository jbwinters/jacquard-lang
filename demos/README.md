# Demos

This directory favors demos that show Weft as a substrate for model-written
programs: the same code can run under different handlers, while authority,
uncertainty, and identity stay visible to tools.

## Direct Demos

- `m1.sh`: factorial, multi-shot choice, and gated eval.
- `m3.sh`: one probabilistic model under exact enumeration and likelihood weighting.
- `m4-hostile.sh`: generated-looking code that reaches for `net`; the row exposes it.
- `clarifying-question.sh`: value-of-information for asking the user.
- `agent-dream.sh`: one agent policy under scripted and probabilistic world handlers.
- `ambiguity-pipeline.sh`: posterior-carrying extraction; user selection is an observe.
- `showcase-warp-tests.sh`: Warp tests for the VOI, dream-mode, and ambiguity demos.
- `word-count.wft`: console-only stdlib smoke demo.
- `cookbook.wft`: compact probabilistic cookbook examples.
- `escrow/`: product-shaped generated workflow with manifest, dry-run, Warp, replay,
  fault exploration, semantic diff, and approval-by-hash.

## Existing Coverage For The Bigger Thesis

- Safe generated-code runner: `demos/escrow/` and `test/cli/hostile-demo.t`.
- Counterfactual replay/debugging: `test/cli/tools.t`.
- Deterministic fault simulation: `demos/escrow/tests.wft` and `test/cli/escrow.t`.
- Semantic CI/cache/diff: `test/cli/warp.t`.
- Probabilistic refactoring tests: `test/cli/props.t`.
- Same model, different inference handler: `demos/m3.sh` and `test/cli/infer.t`.
