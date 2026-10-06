# Jacquard Core 0.3 Gauntlet

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

0.3 adds:

- forged construction of opaque types by name, pattern, explicit or derived
  constructor identity, manifest export, re-declaration, `eval-code` payloads,
  generated setters and host protocol decoding, plus bundles that re-export,
  carry or relabel another context's sealed constructors;
- tampered bundles and stores: object hash mismatch (including a stripped
  opaque marker), missing objects, recorded-namespace mismatch, orphan
  contexts, legacy `bundle-v1` carrying dependencies or opaque declarations,
  and dependency pins that no longer match their context identity;
- hostile manifests: unknown fields, path escapes, namespace overlap and
  ownership violations, grant mismatches, and output-path guards;
- the frozen host protocol v0 vectors: malformed and oversized frames,
  unknown fields, stale or duplicate responses, carrier loss, preflight
  fatals, and opaque or callable values at the boundary;
- computation-fuel exhaustion swept across every transition of a fixture
  program, including resumptions, scheduler steps and deep evaluator-internal value walks;
- handlers that would leak effect payload constraints, and scoped effect
  instances that would escape their scope or be constructed outside it;
- relational comparison under observation policies, including unsupported
  kinds that must stay inconclusive rather than compare equal.

The compiled gauntlet is run both through its cram selection and by an
explicit `gauntlet-.*` Alcotest filter. Historical-manifest mutation tests
prove that byte drift, unregistered or missing manifests, coordinated row
deletion, and checker-policy weakening fail closed.

## Deliberate Omissions

The gate is not unbounded fuzzing, exhaustive exploration of arbitrary
programs, a formal proof, a penetration test, a malicious-compiler proof, or a
production incident exercise. It does not test unsupported platforms or
features listed in `LIMITS.md`. Human readability results are absent because
no human study result is claimed. The documentation-only onboarding exercise
is an executable script, not a completed study with an unfamiliar developer.

The evidence says exactly which finite programs, schedules, grids, fixtures,
and properties ran. It must not be summarized as proof that no defect exists.
