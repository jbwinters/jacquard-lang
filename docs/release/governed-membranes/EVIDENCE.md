# Governed Membranes Release Evidence

Status: GM.22 publication overlay on exact integrated base
`c362d5d1043d3747c488ad74f1550c4a21cc7453`.

This pack publishes the deterministic Workspace v0 governance boundary as an
evidence-backed research reference implementation. It changes no kernel form,
surface syntax, HASH_V0 rule, effect identity, facade operation, membrane
behavior, host queue format, command contract, or runtime grant. Its product
posture is frozen in [DECISION.md](DECISION.md), individual decisions are in
[CLAIMS.md](CLAIMS.md), and non-claims are in [LIMITS.md](LIMITS.md).

## Artifact under review

The reviewed system is the exact composition of:

- the versioned governance values, policies, Call and Proposal encoders in
  `prelude/21-governance-core.jqd` through `23-governance-policy.jqd`;
- deterministic Judge, Audit, Approval, Secret, gate, Workspace, live, dry,
  and forwarding definitions in the released prelude;
- the GM.13A queue and GM.13B guarded host bridge;
- the GM.14 run-bundle and action-reconciliation verifiers;
- the GM.16 source gate and GM.17 explanation, effect-attribution, and typed
  review-diff implementations; and
- the GM.18 governed Workspace cookbook, transcript, and audit fixtures; and
- the GM.19 normalized decision-chain projection plus local offline viewer.

The exact overlay file set and byte hashes are in
[MANIFEST.sha256](MANIFEST.sha256). Predecessor GM.1-GM.18 manifests remain
historical and are not extended or rewritten.

## Claim-to-evidence matrix

The detailed D61-D73 matrix, including a negative boundary beside every
positive claim, is [CLAIMS.md](CLAIMS.md). The release-level proving lanes are:

| claim area | executable evidence | what the lane refuses or deliberately does not prove |
|---|---|---|
| Source admission | GM.16 `test_governance_source_check.ml` plus `governance-check.t` pin the isolated `workspace-v0` grammar, closed source-owned rows, exact environment/driver identities, no evaluation during checking, and accumulated hostile findings. | Raw effects, unexpected handlers, wrong identities/topology, higher-order ambiguity, and direct or handled `Eval` fail closed. Admission is for the exact Workspace profile only. |
| Identity and binding | `test_governance_core.ml`, `test_workspace.ml`, `test_governance_run_bundle.ml`, and native `g38` pin Call/Proposal stability, sensitivity, authority and precondition binding, canonical artifact recomputation, and ordered authority. | Forged hashes, changed fields, rebound names, wrong operation/name pairs, and cross-artifact mismatch are rejected. Hash equality is not correctness or approval. |
| Deterministic policy | GM.4's nine closed Warp properties, six exact numeric-edge checks, and compiled governance-core laws cover every risk class and confidence boundary. | Under-confidence never auto-allows; reversed thresholds and non-finite/out-of-range confidence fail. No posterior or model-truth claim follows. |
| Dry execution | GM.6's 300 gate cells, GM.10's 36 exhaustive Workspace handler cells, `test_workspace_dry_run.ml`, and GM.18's no-grant world cover missing, successful, and failing simulation. | The lanes pin no live fallback, no Approval or Secret row, and zero raw counters. They do not establish that the simulator matches reality. |
| Live execution | GM.7 and GM.11 compiled matrices cover Allow, Block, Ask/Approved, Denied, Escalate, stale consent, pre-action Audit failure, exact raw rows, raw counters, and late Secret resolution. | Non-executable branches have zero raw calls. Completion failure is surfaced after one action and is not rollback. External freshness remains outside the contract. |
| Composition | GM.12A verifies qualified layer topology. GM.12B executes unchanged re-performance, one shared Audit sequence, affine once behavior, native twins, and the mandatory 50,000-case attenuation law. | Wrong operation, skipped or recursive topology, argument transformation, raw effects in forwarding layers, and sequence resets are refused. All inner/outer policy pairs are valid; permission composes conjunctively, so one layer cannot override another layer's refusal. Runtime transformed forwarding is not claimed. |
| Approval delivery | GM.13A/13B restart, corruption, race, replay, actor/principal, Proposal/Decision binding, pre-action ordering, and concurrent-consumer cases exercise the durable queue and guarded bridge. | Delivery/resumption is at most once; outside-world action is not exactly once. Authentication is supplied by the trusted host. One rendezvous is supported; no continuation is persisted. |
| Audit and reconciliation | `test_audit_chain.ml`, GM.14 run-bundle/reconciliation suites, the two governance CLI transcripts, and GM.17A explanation cover ordering, published-head consistency, canonical linkage, tamper refusal, and explicit recovery-state classes. | Missing completion is not rollback; a hash-linked stream is not publisher/provider authenticity, a trusted clock, or a queue/Audit transaction. |
| Secret boundary | Workspace normalizer/summarizer cases and GM.11's non-vacuous fixed-secret run prove that review and Audit artifacts omit secret bytes; GM.18 pins live resolution order and zero access on strict refusal and queue denial. | Opaque `Secret` ends at explicit exposure. The language has no taint tracking or post-exposure exfiltration guarantee. |
| Failure and replay | GM.15 covers 349 reachable sites and 698 healthy/hostile paths, real interpreter boundary failures, eight exact healthy replay shapes, field-level drift refusal, and closed interpreter/native control parity. | It adds no production chaos seam, retry, compensation, provider-fault model, or broader native host integration. |
| Review surfaces | GM.16 emits deterministic source reports; GM.17A verifies and explains one exact Proposal; GM.17B derives conservative raw-effect chains; GM.17C classifies typed dynamic/static review facts with deterministic partial detail; GM.19 projects typed verified reports into one closed presentation schema and exercises six backend-generated decision-chain examples in an accessible local viewer. | Empty static attribution is not proof of runtime absence. GM.17C is a library seam, not a persisted package workflow or public package command. GM.19 fixtures are visibly illustrative; the browser does not verify bundles, recompute hashes or policy, authenticate reviewers, grant consent, execute actions, or establish provider truth. |
| Flagship | GM.18 runs one unchanged Workspace-only agent through no-grant dry simulation, nested strict refusal and permissive live execution, durable exact-proposal denial, 16 agent fault assignments, policy-only outcome change, verified Audit head, and supporting GM.15 evidence. | The demo is checkout-only. Its denial path is proposal-only and does not claim a complete approved operator workflow. Facade-prefix counters and raw-driver counters remain distinct evidence. |

## Trusted computing base

The claim assumes all of these are trusted and selected by exact identity or
reviewed host configuration:

1. the Jacquard checker, resolver, evaluator, affine-resume enforcement,
   canonical serializer, HASH_V0 implementation, and root grant installation;
2. the exact Workspace facade, normalizers, deterministic renderers,
   summarizers, policies, gates, and live/dry/forwarding membranes;
3. the chosen Judge, GovernanceApprovalV1, Audit, State, Secret, and raw-world
   handlers;
4. the live drivers and their provider adapters;
5. the GM.13 queue/bridge host, including its authenticated actor input,
   stable trusted parent directory, local POSIX locks, and durable-I/O
   behavior;
6. the GM.14 artifact decoders, canonical recomputation, run-bundle and
   reconciliation verifiers, and independently published Audit and
   action-journal heads when a conclusion relies on them;
7. the GM.16 source gate, including its exact environment, facade, handler,
   operation, and driver identity pins;
8. the GM.17 Proposal verifier, explanation and why-effect derivations,
   review-diff classifier, and deterministic renderers;
9. the GM.19 OCaml presentation projection and, for presentation accuracy
   only, the pinned client validator and renderer; and
10. the native compiler, generated C runtime, operating system, filesystem,
   OCaml runtime, C toolchain, and deployment configuration when a conclusion
   relies on native evidence.

The governed agent body, prompts, model output, mutable names, summaries it
requests, and external provider responses are not trusted merely because they
cross the membrane. A simulator is trusted only not to reach a live driver;
its fidelity is review evidence, not a theorem.

## Evidence inventory

At this overlay the expected inventory is:

- 799 compiled Alcotest/QCheck cases;
- 50 cram transcript files, including the GM.22 manifest check;
- 27 executable documentation examples across 8 documents;
- 19 client unit/accessibility tests and 9 browser tests across Chromium,
  Firefox, and WebKit;
- the dedicated GM.12B 50,000-case exhaustive attenuation lane; and
- the GM.15 349-site/698-path hostile lane plus selected native differential
  twins.

The inventory commands and all publication gates are in [REPRO.md](REPRO.md).
Generated transcripts belong under `.scratch/release/governed-membranes/` and
are not attested source.

## What the hashes establish

Canonical program and artifact hashes establish identity relative to the exact
canonical inputs. Audit, queue, and action-journal hashes establish internal
predecessor consistency relative to the independently trusted head and domain.
The release manifest establishes source-file bytes relative to the stated Git
base.

None of those hashes establishes semantic correctness, factual truth, safety,
authorization, reviewer identity, provider identity, freshness, or that a
human inspected the artifact. Those conclusions require the trusted components
and operational evidence listed above.
