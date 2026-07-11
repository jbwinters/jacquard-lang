# Demos

Public examples use Jacquard's `.jac` surface syntax and the `jac` command.
From a repository checkout, build once and point the CLI at the normal prelude:

```bash
eval "$(opam env)"
export JACQUARD_PRELUDE=$PWD/prelude
opam exec -- dune build @all
opam exec -- dune exec jac -- run demos/repair.jac --allow eval
```

An installed release sets prelude discovery in its wrapper, so the same demo is
simply `jac run ~/.local/share/jacquard/demos/repair.jac --allow eval` under the install
prefix.

## Surface Programs

- `repair.jac`: computed single-edit program repair as Bayesian inference. A
  failing test is evidence and the MAP patch is a one-line semantic diff.
- `synthesis.jac`: candidate programs as data, with tests conditioning the
  posterior over implementations.
- `agent-dream.jac`: one network policy under scripted and probabilistic world
  handlers.
- `ambiguity-pipeline.jac`: uncertain extraction stays a posterior until a
  user's selection becomes an observation.
- `clarifying-question.jac`: exact value-of-information for interrupting a user.
- `m3-two-coins.jac`: one model under exact enumeration and seeded likelihood
  weighting.
- `word-count.jac`: console capability and standard-library collection smoke.
- `m1-choose.jac`: a multi-shot handler resumes both branches.
- `m1-gated.jac`: executing quoted code requires an explicit `eval` grant.
- `m1-fact.jac`: recursive factorial; `surface-fact.jac` is the earlier SS.16
  carrier of the same quick-start program.
- `surface-expression.jac`: a bare top-level expression with no declaration.

The shell entry points `m1.sh`, `m3.sh`, `clarifying-question.sh`,
`agent-dream.sh`, `ambiguity-pipeline.sh`, and `repair.sh` run these surface
programs through the built `jac` alias. `repair.sh` then runs its retained
bootstrap Warp fixture as a second, explicitly internal route.

## Tooling Evidence

- `showcase-warp-tests.sh`: Warp checks over the VOI, dream-mode, and ambiguity
  definitions. The assembled test file remains a bootstrap fixture.
- `m4-hostile.sh`: authority-manifest transcript over a generated-looking
  bootstrap fixture that reaches for `net`.
- `escrow/`: product-shaped kernel/tooling evidence for manifest checks,
  dry-run, Warp, replay, fault exploration, semantic diff, and approval by hash.
- `cookbook.jqd`: compact probabilistic library fixture used by the demo cram.

Committed transcripts live in `test/cli/demos.t`, `infer.t`, `repair.t`,
`showcase.t`, `hostile-demo.t`, and `escrow.t`. They exercise the public `.jac`
programs through `jac`, retained `.jqd` routes, and semantic hash parity for
paired files.

## Bootstrap Inventory

Bootstrap s-expressions are fully supported. They are the internal/debug
carrier, quote-literal notation, and kernel format of record; they are not
removed by the surface migration and are not declared deprecated.

Paired format-of-record files, each retained beside its public surface twin:

- `m1-fact.jqd`, `m1-choose.jqd`, `m1-gated.jqd`, `m3-two-coins.jqd`
- `clarifying-question.jqd`, `agent-dream.jqd`, `ambiguity-pipeline.jqd`
- `synthesis.jqd`, `repair.jqd`, `word-count.jqd`

Bootstrap-only test, tooling, and release fixtures:

- `cookbook.jqd`, `m4-hostile.jqd`
- `repair-warp-tests.jqd`, `showcase-warp-tests.jqd`
- `escrow/workflow.jqd`, `escrow/workflow-escalated.jqd`
- `escrow/main.jqd`, `escrow/tests.jqd`

The broader bootstrap corpus under `corpus/`, prelude under `prelude/`, native
gauntlet, and release fixtures also remain unchanged as kernel evidence. The
SS.17 corpus twin harness and these demo crams prove that paired `.jac` and
`.jqd` carriers lower to the same semantic identities.
