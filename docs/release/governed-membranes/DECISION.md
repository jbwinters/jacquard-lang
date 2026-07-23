# Governed Membranes Release Decision

- Decision date: 2026-07-21
- Evidence base: `c362d5d1043d3747c488ad74f1550c4a21cc7453`
- Evidence overlay: [MANIFEST.sha256](MANIFEST.sha256)
- Release posture: post-0.1 successor research reference implementation

## Decision

Advertise the released boundary as:

> **Deterministic governance for Jacquard's typed Workspace effects — an
> evidence-backed research reference implementation.**

Do not wait for G5. G5 is a separately versioned way to produce richer risk
assessments; it is not part of deterministic identity, authority, consent,
ordering, or execution enforcement. A future G5 judge may tighten or escalate
a v0 result, but may not weaken or reinterpret it.

Do not advertise this work as a production-ready security system, an
operating-system sandbox, a general agent-governance platform, an exactly-once
workflow engine, or an uncertainty-aware safety system. Do not say that every
G0-G4 product surface is complete. The package-level persisted review workflow
does not ship. The decision-chain playground ships only as a local, offline,
read-only source-checkout review surface; it is not hosted and is not an
approval or operator console. The flagship remains a checkout-only evidence
demo.

## Public claim

Jacquard implements an evidence-backed deterministic governance boundary for
the frozen Workspace v0 effect facade. For source admitted by the Workspace
source gate and executed through the trusted reference membrane and host
boundary, typed requests are bound to exact call, policy, assessment, and
proposal identities. The system supports world-authority-free dry simulation,
monotone unchanged-call live policy nesting, pre-action Audit acknowledgement,
late secret resolution inside allowed live drivers, durable single-use
approval delivery, deterministic review reports, and fail-closed replay and
drift checks.

This is a bounded claim about the exact shipped Workspace implementation and
evidence lanes. It is not a claim about arbitrary facades, arbitrary handlers,
provider truth, reviewer identity, simulator fidelity, external-state
freshness, or isolation from a hostile host.

The local playground is a presentation of that bounded evidence. Its OCaml
projection verifies typed explanation invariants before emitting a normalized
schema. The browser validates and renders that schema but does not evaluate
policy, derive authority, calculate canonical hashes, join artifacts, or
execute an action. Backend-generated examples are visibly illustrative and do
not claim verifier provenance.

## Why this boundary

Jacquard's mission is to make programs written by models reviewable and
governable by people. The deterministic layer establishes what was requested,
which raw authority it requires, which exact policy and assessment governed it,
which consent artifact was used, and which ordered evidence was observed.
Those guarantees should not depend on probabilistic model judgment.

The long-term product architecture therefore keeps two layers separate:

1. a small deterministic trust boundary for identity, authority, consent,
   ordering, and execution; and
2. replaceable judgment producers, including later inference-backed G5 judges.

The language mechanisms support that split directly: typed domain facades,
concrete raw effect rows, separate live and dry entry points, explicit pure
simulation with no live fallback, affine once-mode resumptions, canonical
identity binding, monotone handler nesting, and rejection of governed `Eval`.

## Publication conditions

This decision is valid only together with:

- the D61-D73 [claim matrix](CLAIMS.md);
- the exact [evidence and trusted-base inventory](EVIDENCE.md);
- the adjacent [limits and non-claims](LIMITS.md);
- the [fresh-clone reproduction procedure](REPRO.md); and
- the reconstructible [overlay manifest](MANIFEST.sha256).

The historical Core 0.1 evidence remains unchanged. It correctly did not claim
this successor membrane boundary.

## Production gate not yet met

Before using the term production-ready, require at minimum a real
authenticating operator surface, durable operational Audit integration, an
idempotency and recovery strategy for external actions, a supported production
host deployment, threat-model-driven external security review, and a resource
isolation story finer than whole-effect root grants.
