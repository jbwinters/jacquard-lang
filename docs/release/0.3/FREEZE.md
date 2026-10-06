# Jacquard Core 0.3 Freeze

This file separates the 0.3 distribution boundary from independently
versioned semantic artifacts. A package version bump alone must not revise
those artifacts.

## Distribution

- CLI/package version: `0.3.0`
- release candidate tag: `jacquard-core-0.3.0-rc1`
- final tag: `jacquard-core-0.3.0`
- RC1 and final must name the exact same reviewed commit.
- binary targets: `linux-x86_64`, `macos-x86_64`, `macos-arm64`
- installed commands: `jacquard` and alias `jac`

## Retained Semantic Identities

The release preserves rather than renames:

- the 27 kernel forms and permanent `.jqd` kernel/debug carrier;
- `HASH_V0` canonical identity and SHA-256 implementation;
- the documented canonical serialization, store, trace, replay, effect,
  Workspace v0, Audit, Secret, Approval, Task, Channel, and policy artifact
  versions already frozen by their source specifications and evidence packs;
- OCaml native 63-bit integer wrapping, UTF-8 without normalization, the
  seedable splittable PRNG, and the uncurried final-call convention;
- released diagnostic codes and their established meanings.

0.3 adds versioned artifacts beside those boundaries rather than rewriting
them: `project-v1` manifests, `project-context-v1` pins, `bundle-v2`,
`interface-v1`, host protocol v0 and its conformance kit, `fuel-v1`,
`dist.enumerate-v1` and `dist.sample-lw-v1` outcomes, `observation-policy-v1`
policies and `observation-transcript-v1` transcripts, and the opaque
declaration tag `0x47`.
A transparent declaration keeps its `0x41` bytes, so no existing hash changes.

Any future change to one of those boundaries needs its own named migration or
version decision. The string `0.3.0` is not permission to reinterpret an old
artifact.

## Version-Bound Artifacts

The Core version is part of a project's context identity and of a bundle's
record. A `project-context-v1` pin or a bundle produced by a build reporting
another Core version (including unreleased builds after 0.2.0, which report
`0.2.0`) is refused (E1710, or E1712 for a transitive pin; E1720 for a
bundle); re-pin or rebuild it with 0.3.0. RC1 and the final release are the
same commit and version, so their pins and bundles are interchangeable.

## Compatibility Boundary

The public command families documented in `README.md` and `docs/SKILL.md` are
the 0.3 distribution surface. Exact flags, diagnostics, schemas, and identity
rules are pinned by their tests and detailed release packs.

This freeze does not promise that the evolving `.jac` v0 grammar is final, or
that excluded features in `LIMITS.md` will keep any particular future syntax.
