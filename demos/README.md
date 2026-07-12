# Demos

The demos are grouped by the idea they prove. Public programs use `.jac`;
retained `.jqd` files are kernel/debug twins or Warp fixtures. Run from a
repository checkout after building once:

```bash
eval "$(opam env)"
export JACQUARD_PRELUDE=$PWD/prelude
opam exec -- dune build @all
sh demos/case-studies/stormglass/run.sh
```

An installed release sets prelude discovery automatically. Its demo root is
`~/.local/share/jacquard/demos` unless a different install prefix was chosen.

## Case Studies

These are the best starting point for seeing several Jacquard ideas cooperate
in one program.

- `case-studies/stormglass/`: an incident-response war game. One checkout
  policy runs under simulated `Net` and `Clock` laws, exact enumeration compares
  recovery policies, and Warp proves two properties over all 27 service worlds.
- `case-studies/release-risk/`: one release policy under concrete and
  probabilistic telemetry handlers, with a conditioned risk posterior and a
  Warp safety proof over all 18 worlds.

Each directory contains `model.jac`, `tests.jac`, a short README, and a `run.sh`
that executes the narrative plus sampled and exhaustive Warp lanes.

## Basics

Directory: `basics/`

- `m1-fact.jac`: recursive factorial and the binary-install smoke program.
- `m1-choose.jac`: a deep multi-shot handler resumes both branches.
- `m1-gated.jac`: quoted code execution refuses without the `eval` grant.
- `m1.sh`: runs all three as the original M1 milestone transcript.
- `surface-fact.jac` and `surface-expression.jac`: early surface-syntax
  carriers retained as parser evidence.

## Inference And Decisions

Directory: `inference/`

- `m3-two-coins.jac` and `m3.sh`: one model, one hash, exact enumeration and
  seeded likelihood weighting under different handlers.
- `clarifying-question.jac`: exact value of information for deciding whether
  to interrupt a user.
- `ambiguity-pipeline.jac`: uncertain extraction remains a posterior until a
  user selection becomes an observation.
- `synthesis.jac`: candidate programs treated as a discrete posterior.
- `cookbook.jqd`: compact bootstrap fixture for reusable decision patterns.

## Alternate Worlds

Directory: `worlds/`

- `agent-dream.jac`: one network policy under scripted and probabilistic world
  handlers.
- `preflight.jac`: several candidate agent plans as quoted Code; weak vs sharp
  world evidence scores a posterior; semantic diffs name the rejects; the live
  policy still refuses without a Net grant after the dreams pass.
- `m4-hostile.jqd`: generated-looking code whose `net` authority is exposed by
  signatures and manifest checks.
- `escrow/`: manifest, dry-run, Warp, faults, replay, semantic diff, provenance,
  and approval by exact content hash in one executable workflow.

## Tooling

Directory: `tooling/`

- `repair.jac`: program repair as Bayesian inference over computed AST edits.
- `showcase-warp-tests.sh`: Warp checks shared by the value-of-information,
  dream-mode, and ambiguity demos.
- `word-count.jac`: console capability and standard-library collection smoke.

## Evidence

Committed transcripts live under `test/cli/`, especially `case-studies.t`,
`demos.t`, `infer.t`, `repair.t`, `preflight.t`, `showcase.t`, `hostile-demo.t`,
and `escrow.t`. They pin public `.jac` execution, Warp results, capability
refusals, and the semantic hash parity of retained surface/bootstrap twins.
