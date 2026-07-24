# Collect Surface Clarification

Status: current 0.1 contract clarification, July 2026.

## Context

The structured-concurrency design records schemas for fail-fast and Collect
homogeneous aggregation. Earlier prose called all three scope schemas APIs,
which could be read as saying that a Jacquard program can call
`async.scope-collect`. That term is not bound by the prelude, accepted by the
CLI as a policy selector, or exposed through Warp. The implemented language
surface has always provided `async.scope`, and nested language scopes select
fail-fast.

This note corrects that reachability claim. It does not add or remove a
language operation.

## Current contract

| name | status in Jacquard 0.1 |
|---|---|
| `async.scope` | shipped Jacquard term; always fail-fast |
| `async.scope-fail-fast` | OCaml/library design schema; not a Jacquard term |
| `async.scope-collect` | OCaml/library design schema; not a Jacquard term |
| `Concurrency_contract.Collect` | explicit OCaml embedding policy |

An OCaml caller that explicitly selects Collect gets one immutable
`TaskResult` per child in creation order. A child failure does not cancel its
siblings, and completion waits for all registered children. Fail-fast remains
the OCaml default and the only policy selected by Jacquard scopes.

Scheduling and failure policy are separate choices. FIFO, seeded, replay, and
exhaustive scheduling do not make Collect reachable from Jacquard and do not
silently change a scope's failure policy.

## Evidence

- The prelude binds `async.scope` and does not bind either homogeneous helper.
- Exposure regression coverage checks the shipped binding and both absences.
- The scope-policy transcript identifies its executable as an OCaml evidence
  helper rather than a `jacquard run` example.
- `Concurrency_contract.failure_policy` keeps both library policies and
  documents the explicit embedding seam.

## Deliberate exclusions

This clarification does not change the prelude, evaluator, scheduler, CLI,
Warp, trace format, `HASH_V0`, native runtime, or canonical identities. A
future public Collect operation would be a separate language and product
decision with its own typing, lowering, diagnostics, and cross-engine evidence.

The frozen structured-concurrency evidence documents and manifests remain
byte-for-byte historical publications. They are not rewritten by this
successor clarification. The historical-publication gate reconstructs and
checks them at their pinned commits.
