# Demos

The demos are grouped by the idea they prove. Public programs use `.jac`;
retained `.jqd` files are curated kernel/debug twins or Warp fixtures. New
demos do not need `.jqd` counterparts unless they explicitly prove carrier
parity. Narrative `*.sh` launchers work from either a repository checkout or
an installed release. Developer-only evidence drivers state their source-build
requirement explicitly. From a checkout, build once and run:

```bash
eval "$(opam env)"
export JACQUARD_PRELUDE=$PWD/prelude
opam exec -- dune build @all
sh demos/case-studies/stormglass/run.sh
```

An installed release sets prelude discovery automatically. Its demo root is
`~/.local/share/jacquard/demos` unless a different install prefix was chosen:

```bash
sh ~/.local/share/jacquard/demos/case-studies/stormglass/run.sh
sh ~/.local/share/jacquard/demos/worlds/escrow/run.sh
```

Use the launchers for narrative demos. A model containing `observe` must be run
with `jac infer enumerate model.jac`, not `jac run`; a multi-file demo such as
escrow must be assembled before execution. Its launcher handles those details.

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
  world evidence scores a posterior; canonical diffs name the rejects; the live
  policy still refuses without a Net grant after the dreams pass.
- `m4-hostile.jqd`: generated-looking code whose `net` authority is exposed by
  signatures and manifest checks.
- `escrow/`: manifest, dry-run, Warp, faults, replay, canonical diff, provenance,
  and approval by exact content hash in one executable workflow; run it with
  `sh worlds/escrow/run.sh` from this directory.

## Tooling

Directory: `tooling/`

- `repair.jac`: program repair as Bayesian inference over computed AST edits.
- `showcase-warp-tests.sh`: Warp checks shared by the value-of-information,
  dream-mode, and ambiguity demos.
- `word-count.jac`: console capability and standard-library collection smoke.

## Structured Concurrency Evidence

Directory: `concurrency/`

- `task-schedules.jac`: one two-child task expression plus signatures proving
  a spawned child's `Net` effect remains visible.
- `run.sh`: runs that exact expression through FIFO, seeded random, exhaustive,
  and strict replay handlers, pinning eight complete schedule worlds and
  version-1 trace identities.

This is a developer evidence demo and requires a source checkout built with
Dune because exhaustive schedule enumeration is a library/review seam, not a
public `jac run` flag. Its transcript is `test/cli/concurrency-evidence.t`.

## Evidence

Committed transcripts live under `test/cli/`, especially `case-studies.t`,
`demos.t`, `infer.t`, `repair.t`, `preflight.t`, `showcase.t`, `hostile-demo.t`,
and `escrow.t`. They pin public `.jac` execution, Warp results, capability
refusals, and the canonical hash parity of retained surface/bootstrap twins.
