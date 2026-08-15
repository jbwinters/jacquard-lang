# Jacquard Core 0.2 Evidence

Status: release evidence for `jacquard-core-0.2.0-rc1` and, after promotion of
the same reviewed commit, `jacquard-core-0.2.0`.

Required lineage base: `c0f570501b751865c0c0584d9b15be08b6ec1cde`

Exact candidate commit: recorded by `scripts/release/reproduce-0.2.sh` in
`.scratch/release/0.2/commit.txt`.

Distribution version: `jacquard --version` and `jac --version` print `0.2.0`.
This distribution bump does not rename or revise `HASH_V0`, the 27-form
kernel, canonical store formats, trace schemas, or other independently
versioned semantic artifacts.

## Built Artifact

The release is the OCaml package and three packaged binary targets in this
repository:

- `linux-x86_64`;
- `macos-x86_64`;
- `macos-arm64`.

Each archive contains the `jacquard` executable and `jac` alias, prelude,
runnable demos, native C runtime, and licensing files. The checksum-verifying
installer defaults to the final `jacquard-core-0.2.0` tag. An RC installation
must select `JACQUARD_INSTALL_VERSION=jacquard-core-0.2.0-rc1` explicitly.

## Test Inventory

The candidate inventory is discovered by the checked-in test runner and file
tree, not estimated from task history:

- Alcotest/QCheck cases: `868`
- Cram transcript files: `58`
- Documentation examples: `28` named examples across `8` documents

The development suite also includes corpus goldens, release-manifest checks,
native interpreter/compiler differential cases, leak and memory checks,
seeded fuzzing, and demo transcripts. GM.12B's separate workflow executes the
complete 50,000-case forwarding grid. The parser-depth guard rejects unsafe or
slow handling of the canonical depth-100,000 inputs.

## Evidence Lineage

0.2 is an additive roll-up. It does not rewrite earlier publications:

- `../0.1/` retains the historical core candidate boundary;
- `../surface-syntax/` and `../dx-jac-export/` cover public `.jac`, formatting,
  direct native build, export, and parser hardening;
- `../explicit-dictionaries/` covers explicit `Eq`, `Ord`, `Show`, and `Num`
  values;
- `../effect-linearity/` and `../effect-taxonomy/` cover affine `once`
  continuations and the Audit, Secret, and Approval boundaries;
- `../structured-concurrency/` covers the interpreted scoped Task and typed
  Channel runtime, including the SC.17 transitive-cancellation correction;
- `../relational-warp/` covers schedule, Secret, and grant-variation lanes;
- `../governed-membranes/` covers the frozen typed Workspace v0 governance
  reference boundary and its explicit security and product limits.

The 0.2 manifest hashes the complete change set from the required lineage base
except for the manifest itself. `scripts/release/check-0.2-manifest.sh`
requires that inventory to match the Git diff exactly and verifies every blob.

## Reproduction Gate

`scripts/release/reproduce-0.2.sh` checks the candidate commit rather than an
uncommitted worktree. It verifies all registered historical publications and
the 0.2 manifest, builds all code and documentation, runs the complete suite,
doctests, depth guard, GM.12B proof, both compiler lanes, installer smoke,
public demos, selected release crams, and the gauntlet. It finishes only after
formatting leaves the checkout clean and the version surface is exactly
`0.2.0`.

The native evidence is genuinely compiler-specific: both `CC=clang` and
`CC=gcc` flow into runtime memory checks, differential tests, leak checks, and
the seeded fuzz target.

## Claim Boundary

Passing these gates establishes conformance to the tests and frozen contracts
identified in `CLAIMS.md`. It is not a formal soundness proof, security audit,
human readability study, production-readiness certification, or claim that
canonical hash equality means arbitrary behavioral equivalence. Read
`LIMITS.md` alongside every public claim.
