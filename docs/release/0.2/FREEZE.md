# Jacquard Core 0.2 Freeze

This file separates the 0.2 distribution boundary from independently
versioned semantic artifacts. A package version bump alone must not revise
those artifacts.

## Distribution

- CLI/package version: `0.2.0`
- release candidate tag: `jacquard-core-0.2.0-rc1`
- final tag: `jacquard-core-0.2.0`
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
  seed-required splittable PRNG, and the uncurried final-call convention;
- released diagnostic codes and their established meanings.

Any future change to one of those boundaries needs its own named migration or
version decision. The string `0.2.0` is not permission to reinterpret an old
artifact.

## Compatibility Boundary

The public command families documented in `README.md` and `docs/SKILL.md` are
the 0.2 distribution surface. Exact flags, diagnostics, schemas, and identity
rules are pinned by their tests and detailed release packs.

This freeze does not promise that the evolving `.jac` v0 grammar is final, or
that excluded features in `LIMITS.md` will keep any particular future syntax.
