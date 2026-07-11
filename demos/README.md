# Demos

This directory favors demos that show Jacquard as a substrate for model-written
programs: the same code can run under different handlers, while authority,
uncertainty, and identity stay visible to tools.

## Direct Demos

- `surface-fact.jac`: pure recursive surface program run directly by `jac run`.
- `surface-expression.jac`: a bare top-level surface expression, with no declaration wrapper.
- `m1.sh`: factorial, multi-shot choice, and gated eval.
- `m3.sh`: one probabilistic model under exact enumeration and likelihood weighting.
- `m4-hostile.sh`: generated-looking code that reaches for `net`; the row exposes it.
- `clarifying-question.sh`: value-of-information for asking the user.
- `agent-dream.sh`: one agent policy under scripted and probabilistic world handlers.
- `ambiguity-pipeline.sh`: posterior-carrying extraction; user selection is an observe.
- `showcase-warp-tests.sh`: Warp tests for the VOI, dream-mode, and ambiguity demos.
- `synthesis.jqd`: program synthesis as Bayesian inference; a test suite is an
  observation and the posterior over programs sharpens as tests are added.
- `repair.sh`: program repair as Bayesian inference; single-edit patches are
  computed from the buggy program's quoted AST, a bug report is an observation,
  and the MAP patch renders as a one-line `code.diff`. Warp tests cover the
  pure mutation machinery and the patch prior.
- `word-count.jqd`: console-only stdlib smoke demo.
- `cookbook.jqd`: compact probabilistic cookbook examples.
- `escrow/`: product-shaped generated workflow with manifest, dry-run, Warp, replay,
  fault exploration, semantic diff, and approval-by-hash.

## Existing Coverage For The Bigger Thesis

- Safe generated-code runner: `demos/escrow/` and `test/cli/hostile-demo.t`.
- Counterfactual replay/debugging: `test/cli/tools.t`.
- Deterministic fault simulation: `demos/escrow/tests.jqd` and `test/cli/escrow.t`.
- Semantic CI/cache/diff: `test/cli/warp.t`.
- Probabilistic refactoring tests: `test/cli/props.t`.
- Same model, different inference handler: `demos/m3.sh` and `test/cli/infer.t`.
- Synthesis and repair as inference: `demos/synthesis.jqd` with `test/cli/showcase.t`,
  and `demos/repair.sh` with `test/cli/repair.t`.
