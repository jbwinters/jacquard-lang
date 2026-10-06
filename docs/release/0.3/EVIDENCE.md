# Jacquard Core 0.3 Evidence

Status: release evidence for `jacquard-core-0.3.0-rc1` and, after promotion of
the same reviewed commit, `jacquard-core-0.3.0`.

Required lineage base: `f296ec1333072a1bdddb53f707eef836926cdb43`

Exact candidate commit: recorded by `scripts/release/reproduce-0.3.sh` in
`.scratch/release/0.3/commit.txt`.

Distribution version: `jacquard --version` and `jac --version` print `0.3.0`.
This distribution bump does not rename or revise `HASH_V0`, the 27-form
kernel, canonical store formats, trace schemas, or other independently
versioned semantic artifacts. The Core version does enter project context
identities and bundle records (`FREEZE.md`).

## Built Artifact

The release is the OCaml package and three packaged binary targets in this
repository:

- `linux-x86_64`;
- `macos-x86_64`;
- `macos-arm64`.

Each archive contains the `jacquard` executable and `jac` alias, prelude,
runnable demos, native C runtime, and licensing files. The checksum-verifying
installer defaults to the final `jacquard-core-0.3.0` tag. An RC installation
must select `JACQUARD_INSTALL_VERSION=jacquard-core-0.3.0-rc1` explicitly.

## Test Inventory

The candidate inventory is discovered by the checked-in test runner and file
tree, not estimated from task history:

- Alcotest/QCheck cases: `1194`
- Cram transcript files: `78`
- Documentation examples: `36` named examples across `8` documents

The host protocol v0 conformance kit's `kit.json` records `core_version`
`0.3.0`; its SHA-256 is
`a01b9401d7c2df4e17771b9c0d22f9ea5ce1a923dfb7d3396c27821c0e058a61`
(`a286328c457696a898aaa6731f0044fb90c78d8657d57270384a76976b070b53` at the
lineage base). `transcripts.json` is unchanged.

0.2.0 shipped `868 / 58 / 28`. The development suite also includes corpus
goldens, release-manifest checks, native interpreter/compiler differential
cases, leak and memory checks, seeded fuzzing, the host protocol conformance
kit, and demo transcripts. GM.12B's separate workflow executes the complete
50,000-case forwarding grid. The parser-depth guard rejects unsafe or slow
handling of the canonical depth-100,000 inputs.

## Evidence Lineage

0.3 is an additive roll-up over 0.2. It does not rewrite earlier publications:

- `../0.2/` retains the 0.2.0 boundary, restored here to its published bytes;
  its manifest is verified at the `jacquard-core-0.2.0` tag;
- `../named-call-arguments/` covers named call arguments and the call-label
  companion;
- `../api-identities/` covers `interface-v1` emit, verify and diff, and how
  opaque types bind interface and context pins;
- `../host-boundary/` covers the frozen host protocol v0, its codecs,
  preflight, session accounting, the serial `jacquard host worker`, and the
  conformance kit;
- `../authority-requirements/` records the host authority intake and the
  attenuation decisions;
- `../inference-outcomes/` covers typed `dist.enumerate-v1` and
  `dist.sample-lw-v1` outcomes;
- `../abstract-types/` covers opaque types, checked construction boundaries,
  and their upgrade notes;
- `../surface-syntax/FOLLOWUPS.md` records the accessor, setter and field
  update eligibility decisions;
- `SLICES.md` keeps the per-change evidence log for everything integrated
  between 0.2.0 and the lineage base.

The 0.3 manifest hashes the complete change set from the required lineage base
except for the manifest itself. `scripts/release/check-0.3-manifest.sh`
requires that inventory to match the Git diff exactly and verifies every blob.

## Reproduction Gate

`scripts/release/reproduce-0.3.sh` checks the candidate commit rather than an
uncommitted worktree: it refuses staged or unstaged changes to tracked files
before it starts and requires the checkout to equal the candidate afterwards. It verifies all registered historical publications, the
0.2 manifest at its tag and the 0.3 manifest, builds all code and
documentation, runs the complete suite, doctests, depth guard, GM.12B proof,
both compiler lanes, installer smoke, public demos, selected release crams,
and the gauntlet. It finishes only after formatting leaves the checkout clean
and the version surface is exactly `0.3.0`.

The native evidence is genuinely compiler-specific: both `CC=clang` and
`CC=gcc` flow into runtime memory checks, differential tests, leak checks, and
the seeded fuzz target.

## Claim Boundary

Passing these gates establishes conformance to the tests and frozen contracts
identified in `CLAIMS.md`. It is not a formal soundness proof, security audit,
human readability study, production-readiness certification, or claim that
canonical hash equality means arbitrary behavioral equivalence. Read
`LIMITS.md` alongside every public claim.
