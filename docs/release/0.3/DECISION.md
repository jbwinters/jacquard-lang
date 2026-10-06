# Jacquard Core 0.3 Release Decision

Status: candidate is ready for RC1 only after the exact candidate reproduction
and required GitHub checks are green.

Test count: `1194`

Cram count: `78`

Documentation example count: `36` across `8` documents

## Decision

Publish `jacquard-core-0.3.0-rc1` from the reviewed merge commit when:

- the complete 0.3 manifest verifies against lineage base
  `f296ec1333072a1bdddb53f707eef836926cdb43`, and the 0.2 manifest still
  verifies at `jacquard-core-0.2.0`;
- development, Clang, GCC, governance, GM.12B, parser-depth, and release
  reproduction evidence are green for that exact commit;
- the binary workflow publishes three archives and three matching checksum
  files; and
- the downloaded Linux archive and public RC installer pass smoke validation.

Promote `jacquard-core-0.3.0` only by tagging that same commit after the RC
checks and assets pass. A source change requires a new reviewed commit and RC;
published tags are immutable.

## Rationale

Since 0.2.0, 81 reviewed changes have been integrated and tested together but
not shipped in a binary: local projects with manifests, dependency pins and
verifiable bundles; portable interface identities; the frozen host protocol v0
with its serial worker and conformance kit; surface named arguments, labeled
patterns, generated accessors and setters, field updates and Result
propagation; checked effect payloads and scoped effect instances;
deterministic computation fuel; typed inference outcomes; the typed
observation boundary and observation policies; and opaque types with checked
construction boundaries. Several of these change behaviour that 0.2 accepted,
so they are released together under one version with one set of upgrade notes
rather than left to accumulate.

## Conditions on the Public Claim

Release notes and announcements must link `CLAIMS.md`, `LIMITS.md`, and the
upgrade notes in `RELEASE-NOTES.md`. They must not call Jacquard a sandbox,
production authorization system, formally verified compiler, human-validated
readability improvement, native async runtime, package manager, or general
continuous probabilistic language.
