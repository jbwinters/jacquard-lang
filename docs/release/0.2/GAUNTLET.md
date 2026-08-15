# Jacquard Core 0.2 Gauntlet

The release gate includes hostile and negative evidence, not only successful
examples.

## Included Adversarial Classes

- malformed kernel and surface syntax, deep parser inputs, invalid metadata,
  resolution failures, type/effect errors, non-exhaustive matches, and stable
  diagnostics;
- omitted grants, unhandled effects, dynamic-code authority, invalid handler
  modes, and static/runtime repeated use of affine resumptions;
- malformed manifests and capability names, canonical-identity sensitivity,
  store corruption and collision seams, replay mismatch, cache invalidation,
  and fault injection;
- interpreter/native divergence, runtime memory failures, leak checks, seeded
  generated programs, compiler/exporter filesystem hostility, and corrupted
  installer checksums;
- cancellation races, nested-scope orphan prevention, cross-run Task/Channel
  misuse, closed channels, rendezvous/backpressure edges, strict replay
  mismatch, bounded scheduler enumeration, and fail-fast policy interaction;
- stale or mismatched approvals, replayed decisions, proposal/hash mismatch,
  queue restart and race cases, malformed governance operation names,
  authority expansion, invalid layer topology, audit mutation, secret
  redaction/exposure edges, and no-simulated-consent laws;
- relational mutations that must be detected across schedule, Secret, and
  grant-variation lanes;
- offline-only viewer network checks, keyboard navigation, accessibility,
  reduced motion, forced colors, and projection-fixture byte parity.

The compiled gauntlet is run both through its cram selection and by an
explicit `gauntlet-.*` Alcotest filter. Historical-manifest mutation tests
prove that byte drift, unregistered or missing manifests, coordinated row
deletion, and checker-policy weakening fail closed.

## Deliberate Omissions

The gate is not unbounded fuzzing, exhaustive exploration of arbitrary
programs, a formal proof, a penetration test, a malicious-compiler proof, or a
production incident exercise. It does not test unsupported platforms or
features listed in `LIMITS.md`. Human readability results are absent because
no human study result is claimed.

The evidence says exactly which finite programs, schedules, grids, fixtures,
and properties ran. It must not be summarized as proof that no defect exists.
