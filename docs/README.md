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
- `research/readability-benchmark/PROTOCOL.md`: preregistered reviewer tasks,
  paired-carrier fixtures, scoring, privacy, and synthetic reproduction evidence
  for future syntax decisions.
- `ci-cd.md`: GitHub gates, branch protection, and release evidence workflow.

## Core Design

- `whitepaper.tex`: historical initial design thesis, motivation, risks, and
  related work; its roadmap and implementation-status sections are outdated.
- `ast.md`: kernel AST draft and metadata/hash contract.
- `../spec/jacquard-kernel-ast-m0.md`: kernel AST source-of-truth spec.
- `../spec/serialization.md`: canonical byte serialization and hashing.
- `development-plan.md`: original task plan and milestone discipline.
- `concurrency.md`: phase-zero pure parallel hints and the staged structured-concurrency design.

## User-Facing Runtime

- `tutorial.md`: worked CLI examples.
- `stdlib.md`: prelude, rings, library effects, and standard handlers.
- `effect-taxonomy.md`: ratified blessed effect names, schemas, risks, rings,
  interface compatibility, and user-effect governance.
- `effect-review.md`: identity-first manifest and authority-diff review,
  uncertainty wording, canonical boundaries, and explicit non-goals.
- `effect-membranes.md`: GM.0 charter for typed governed facades, versioned
  decision artifacts, live/dry boundaries, and monotonic composition.
- `concurrency.md`: SC.14 ships the exact scoped typed Channel contract frozen
  by SC.13 through deterministic, seeded, replay, exhaustive, and cached
  interpreted scheduling. It publishes exact identities, capacity/backpressure,
  close, cancellation, fan-in, ownership, and policy interaction. Native
  Channel execution, host I/O readiness, and actors remain deferred to C4+.
- `warp-testing.md`: Warp test model, rows, handlers, cache, properties, and
  world lanes.
- `errors.md`: diagnostic code catalog.

## Release 0.1 Evidence

Read these together when judging whether the release candidate is credible:

- `release/0.1/EVIDENCE.md`: built artifact, test inventory, commands, summary.
- `release/0.1/CLAIMS.md`: claims mapped to proving tests/demos and caveats.
- `release/structured-concurrency/EVIDENCE.md`: SC.14 scoped Channel runtime and
  schedule-parity evidence over the complete SC.12 scheduler stack.
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
- `release/dx-jac-export/DECISION.md`: DX.2 direct `.jac` native build and
  explicit deterministic bootstrap-export decision, guarantees, and non-goals.
- `release/dx-jac-export/EVIDENCE.md`: successor-only inventory, filesystem
  adversarial coverage, native carrier parity, and reproduction commands.
- `release/dx-parser-performance/EVIDENCE.md`: DX.6 root-cause profile,
  before/after deep-input measurements, and the opt-in parser performance lane.

## Effect Linearity Evidence

- `release/effect-linearity/EVIDENCE.md`: EL.2-EL.4 scope, bounded affine-analysis
  design, frozen stdlib modes, diagnostic provenance, and verification.
- `release/effect-linearity/MANIFEST.sha256`: reconstructible EL.2-EL.4 overlay
  on the completed EL.1 base.

## Effect Taxonomy Evidence

- `release/effect-taxonomy/EVIDENCE.md`: ET.2 released Audit identity, canonical
  entry encoding, append handler contracts, failure limits, and reproduction.
- `release/effect-taxonomy/ET3-EVIDENCE.md`: ET.3 canonical hash-chain carrier,
  published-head contract, offline mutation verification, and reproduction.
- `release/effect-taxonomy/ET3-MANIFEST.sha256`: reconstructible ET.3 overlay on
  the validated ET.2 base; the ET.2 manifest remains unchanged.
- `release/effect-taxonomy/ET4-EVIDENCE.md`: ET.4 opaque Secret runtime boundary,
  explicit exposure contract, redaction guarantees, and adversarial evidence.
- `release/effect-taxonomy/ET4-MANIFEST.sha256`: reconstructible ET.4 overlay on
  the validated ET.3 base; predecessor manifests remain unchanged.
- `release/effect-taxonomy/ET5-EVIDENCE.md`: ET.5 fixed, environment-granted,
  and provider-neutral vault Secret handler boundaries with leak scans.
- `release/effect-taxonomy/ET5-MANIFEST.sha256`: reconstructible ET.5 overlay on
  the validated ET.4 base; predecessor manifests remain unchanged.
- `release/effect-taxonomy/ET6-EVIDENCE.md`: ET.6 released Approval identity,
  exact review-artifact hashing, stale-decision rejection, and parity evidence.
- `release/effect-taxonomy/ET6-MANIFEST.sha256`: reconstructible ET.6 overlay on
  the validated pre-ET.6 base; earlier evidence manifests remain unchanged.
- `release/effect-taxonomy/ET7-EVIDENCE.md`: ET.7 canonical Approval handlers,
  exact proposal revalidation, and the no-simulated-consent laws.
- `release/effect-taxonomy/ET7-MANIFEST.sha256`: reconstructible ET.7 overlay on
  the validated ET.6 base; earlier evidence manifests remain unchanged.
- `release/effect-taxonomy/ET8-EVIDENCE.md`: ET.8 taxonomy closure, canonical
  handler/boundary inventory, review wording, and exact tooling evidence.
- `release/effect-taxonomy/ET8-MANIFEST.sha256`: reconstructible ET.8 overlay on
  the integrated Secret/Approval base; predecessor manifests remain historical.

## Structured Concurrency Evidence

- `release/structured-concurrency/EVIDENCE.md`: final C0-C2 publication gate
  plus the shipped interpreted C3 typed-Channel runtime, exact identities,
  schedule parity, counts, and claim-to-test links.
- `release/structured-concurrency/LIMITS.md`: dynamic Task and Channel lifetime
  checks, cooperative cancellation, explicit bracket cleanup, interpreter-only
  scheduling, sequential C0 hints, and explicit C4 exclusions.
- `release/structured-concurrency/MANIFEST.sha256`: reconstructible SC.16
  publication overlay on exact SC.12 commit `b828099`.

## Governed Membranes Evidence

- `release/governed-membranes/GM1-EVIDENCE.md`: GM.1 versioned ring-3 values,
  canonical identities, pure refusal boundaries, and compatibility evidence.
- `release/governed-membranes/GM1-MANIFEST.sha256`: reconstructible GM.1 overlay
  on the validated ET.6 plus GM.0 dependency-integration commit.
- `release/governed-membranes/GM2-EVIDENCE.md`: GM.2 exact Call and successor
  Proposal identities, canonical-Code goldens, and stability/sensitivity laws.
- `release/governed-membranes/GM2-MANIFEST.sha256`: reconstructible GM.2 overlay
  on the validated GM.1 commit `b5587ce`.
- `release/governed-membranes/GM3-EVIDENCE.md`: GM.3 validated live, dry,
  stored, and bound policy boundaries plus exhaustive verdict-law evidence.
- `release/governed-membranes/GM3-MANIFEST.sha256`: reconstructible GM.3 overlay
  on the validated GM.2 plus ET.3 integration commit `3e78a95`.
- `release/governed-membranes/GM4-EVIDENCE.md`: GM.4 hermetic Warp laws,
  exhaustive finite supports, exact numeric edges, cache behavior, and mutation
  detection evidence.
- `release/governed-membranes/GM4-MANIFEST.sha256`: reconstructible GM.4 overlay
  on validated GM.3 base `f813d11`.
- `release/governed-membranes/GM5-EVIDENCE.md`: GM.5 released Judge identity,
  validated deterministic handlers, explicit model `Infer` row, and refusal
  evidence.
- `release/governed-membranes/GM5-MANIFEST.sha256`: reconstructible GM.5 overlay
  on the validated GM.1 plus ET.3 integration base `94b5082`; the GM.1 evidence
  set remains historical.
- `release/governed-membranes/GM6-EVIDENCE.md`: GM.6 world-free dry-gate,
  exact audit sequencing, simulator/refusal matrix, and native parity evidence.
- `release/governed-membranes/GM6-MANIFEST.sha256`: reconstructible GM.6 overlay
  on the validated GM.3 plus GM.5 integration stack.
- `release/governed-membranes/GM8-EVIDENCE.md`: GM.8 cross-artifact verifier,
  exact authority expansion, identity, sequencing, secret, lineage, and `Eval`
  diagnostics, with one valid Workspace contract and adversarial rule coverage.
- `release/governed-membranes/GM8-MANIFEST.sha256`: reconstructible GM.8 overlay
  on exact integrated base `491e530`.
- `release/governed-membranes/GM9-EVIDENCE.md`: GM.9 typed Workspace calls,
  safe secret references, outcome summaries, and authority-order evidence.
- `release/governed-membranes/GM9-MANIFEST.sha256`: reconstructible GM.9 overlay
  on the validated identity, Judge, and secret integration stack.
- `release/governed-membranes/GM10-EVIDENCE.md`: GM.10 world-free Workspace
  membrane, closed simulator boundary, exact rows, audit order, zero-world
  counters, and exhaustive Warp evidence.
- `release/governed-membranes/GM11-EVIDENCE.md`: GM.11 live Workspace membrane,
  exact facade-to-raw rows, governance verdict and audit ordering, late secret
  exposure, raw-handler failure evidence, and explicit external-freshness limits.
- `release/governed-membranes/GM12A-EVIDENCE.md`: additive layer-aware
  governance verifier, same-operation forwarding across qualified membrane
  layers, direct Call lineage, linear topology, and fail-closed authority evidence.
- `release/governed-membranes/GM12B-EVIDENCE.md`: reusable unchanged-argument
  Workspace forwarding membrane, shared audit sequencing, affine same-op
  handler evidence, native twins, and the exhaustive 50,000-case attenuation law.
- `release/governed-membranes/GM13A-EVIDENCE.md`: crash-safe single-use
  approval queue host core, canonical record/commit framing, authenticated
  actor rules, restart recovery, race evidence, and the explicit GM.13B bridge
  boundary.
- `release/governed-membranes/GM13A-MANIFEST.sha256`: reconstructible GM.13A
  overlay on exact base `e20ebcf`.
- `release/governed-membranes/GM13B-EVIDENCE.md`: guarded two-run approval
  bridge, frozen Store identities, exact Proposal/Decision codecs, pre-action
  Audit ordering, reviewer-race/replay/concurrency evidence, and explicit
  single-rendezvous and host-auth limits.
- `release/governed-membranes/GM13B-MANIFEST.sha256`: reconstructible GM.13B
  overlay on exact GM.13A base `bb3f5ea`.
- `release/governed-membranes/GM14-EVIDENCE.md`: GM.14A canonical run bundles
  plus GM.14B action-journal reconciliation, unchanged artifact identities,
  exact receipt/completion linkage, honest recovery gaps, and explicit
  execution and rollback exclusions.
- `release/governed-membranes/GM14-MANIFEST.sha256`: reconstructible GM.14B
  overlay on exact integrated GM.14A base `23949d0`.
- `release/governed-membranes/GM15-EVIDENCE.md`: GM.15 immutable 698-path
  hostile-world matrix, real interpreter boundary failures, strict healthy
  replay shapes, adversarial drift refusal, and closed native parity.
- `release/governed-membranes/GM15-MANIFEST.sha256`: reconstructible
  evidence-only GM.15 overlay on exact integrated base `bed0adb`.
- `release/governed-membranes/GM16-EVIDENCE.md`: GM.16 isolated static
  `workspace-v0` source gate, exact recursive composition grammar, deterministic
  report contract, and hostile no-evaluation evidence.
- `release/governed-membranes/GM16-MANIFEST.sha256`: reconstructible GM.16
  implementation overlay on exact GM.15 successor base `3f01622`.
- `release/governed-membranes/GM17A-EVIDENCE.md`: GM.17A fully verified,
  proposal-scoped governance explanation; exact live-rule and Workspace-driver
  binding; deterministic text/JSON review facts; and fail-closed hostile
  evidence.
- `release/governed-membranes/GM17A-MANIFEST.sha256`: reconstructible GM.17A
  implementation overlay on exact integrated base `58c8027`.
- `release/governed-membranes/GM17B-EVIDENCE.md`: GM.17B conservative,
  identity-based Workspace-to-raw-effect source attribution, deterministic
  review facts, and fail-closed higher-order/handler evidence.
- `release/governed-membranes/GM17B-MANIFEST.sha256`: reconstructible GM.17B
  implementation overlay on exact integrated base `4b0670f`.
- `release/governed-membranes/GM10-MANIFEST.sha256`: reconstructible GM.10
  overlay on exact integrated GM.8/GM.9 base `df37a15`.
- `release/governed-membranes/GM11-MANIFEST.sha256`: reconstructible GM.11
  overlay on exact integrated base `ec92748`.
- `release/governed-membranes/GM12A-MANIFEST.sha256`: reconstructible GM.12A
  verifier foundation on exact GM.11 base `79645e9`.
- `release/governed-membranes/GM12B-MANIFEST.sha256`: reconstructible GM.12B
  runtime overlay on exact GM.12A base `a1b4015`.

## Maintenance Notes

- `native-compilation.md`: native compilation notes and boundaries.
- `native-parallel-decision.md`: SC.2 proof/runtime audit, fallback evidence,
  and the decision not to emit native workers yet.
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
