# Documentation Index

This index is for both human contributors and coding agents. It points to the
source of truth for each kind of question so readers do not have to infer the
project shape from file names alone.

## First Read

- `../README.md`: fresh-clone setup, common commands, demos, CI, and repo map.
- `../AGENTS.md`: operating rules for future agents.
- `SKILL.md`: the whole language in one file for coding agents — kernel forms,
  rows and capabilities, Dist, code-as-data, Warp, CLI, style, and gotchas.
  (Also discoverable as a project skill via `docs/SKILL.md`.)
- `tutorial.md`: runnable examples from literals through hashing and tooling.
- `../demos/README.md`: demo catalog and what each demo proves.
- `surface-syntax.md`: public `.jac` authoring syntax and its projection onto
  the retained `.jqd` kernel/debug carrier.
- `ci-cd.md`: GitHub gates, branch protection, and release evidence workflow.

## Core Design

- `whitepaper.tex`: historical initial design thesis, motivation, risks, and
  related work; its roadmap and implementation-status sections are outdated.
- `ast.md`: kernel AST draft and metadata/hash contract.
- `../spec/jacquard-kernel-ast-m0.md`: kernel AST source-of-truth spec.
- `../spec/serialization.md`: canonical byte serialization and hashing.
- `development-plan.md`: original task plan and milestone discipline.

## User-Facing Runtime

- `tutorial.md`: worked CLI examples.
- `stdlib.md`: prelude, rings, library effects, and standard handlers.
- `effect-taxonomy.md`: ratified blessed effect names, schemas, risks, rings,
  interface compatibility, and user-effect governance.
- `warp-testing.md`: Warp test model, rows, handlers, cache, properties, and
  world lanes.
- `errors.md`: diagnostic code catalog.

## Release 0.1 Evidence

Read these together when judging whether the release candidate is credible:

- `release/0.1/EVIDENCE.md`: built artifact, test inventory, commands, summary.
- `release/0.1/CLAIMS.md`: claims mapped to proving tests/demos and caveats.
- `release/0.1/REPRO.md`: fresh-clone reproduction.
- `release/0.1/FREEZE.md`: frozen version/hash/store/trace/CLI/error surfaces.
- `release/0.1/GAUNTLET.md`: adversarial tests present and omitted.
- `release/0.1/LIMITS.md`: non-goals and known caveats.
- `release/0.1/DECISION.md`: RC decision memo.
- `release/0.1/RELEASE-NOTES.md`: public release contents and binary install.

## Post-0.1 Surface Syntax Evidence

- `release/surface-syntax/DECISION.md`: SS.21 advertise/not-advertise decision,
  L1-L7 status, D34-D40 conformance, caveats, and reproduction commands.
- `release/surface-syntax/FOLLOWUPS.md`: durable D36/D38/D39 and Tier-F
  follow-up scope outside the surface release gate.
- `release/surface-syntax/MANIFEST.sha256`: historical surface-syntax evidence
  integrity set, validated by the surface manifest checker. Successor milestones
  publish separate reconstructible overlays rather than extending this set.

## Effect Linearity Evidence

- `release/effect-linearity/EVIDENCE.md`: EL.2-EL.4 scope, bounded affine-analysis
  design, frozen stdlib modes, diagnostic provenance, and verification.
- `release/effect-linearity/MANIFEST.sha256`: reconstructible EL.2-EL.4 overlay
  on the completed EL.1 base.

## Effect Taxonomy Evidence

- `release/effect-taxonomy/EVIDENCE.md`: ET.2 released Audit identity, canonical
  entry encoding, append handler contracts, failure limits, and reproduction.

## Maintenance Notes

- `native-compilation.md`: native compilation notes and boundaries.
- `perf-vm-decision.md`: why VM/performance work is not in 0.1.
- `example-code.md`: early target examples retained as design context.
- `../test/docs-doctest/README.md`: how executable documentation fences map
  to `.jac` fixtures and run under Dune.

## Suggested Paths

For a new human contributor:

1. `../README.md`
2. `tutorial.md`
3. `../demos/README.md`
4. `ci-cd.md`
5. `CONTRIBUTING.md` from the repository root

For a future coding agent:

1. `../AGENTS.md`
2. `SKILL.md`
3. `../README.md`
4. `ast.md`
5. relevant test files under `../test/`

For a release reviewer:

1. `release/0.1/EVIDENCE.md`
2. `release/0.1/CLAIMS.md`
3. `release/0.1/REPRO.md`
4. from the repository root, run `scripts/release/reproduce-0.1.sh`
