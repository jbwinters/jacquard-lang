# Jacquard Core 0.1 Evidence

Status: release-candidate evidence for `jacquard-core-0.1-rc1`.

Distribution note: RC2 repaired installed demo launchers. RC3 added an explicit
runtime/generated-output license exception and packaged the native C runtime.
The current successor distribution relicenses Jacquard under Apache License
2.0, retaining an Apache-specific runtime/generated-output permission. These
successor changes do not change the language semantics evidenced here.

Required lineage base: `738dc8e`
Exact candidate commit: recorded by `scripts/release/reproduce-0.1.sh` in
`.scratch/release/0.1/commit.txt`
Version surface: `jacquard --version` prints `0.1.0`

This pack describes Jacquard core as implemented in the current successor checkout:
the kernel triple reader/validator/resolver, `.jac` surface projection, HASH_V0
canonical identity, the content store, CPS evaluator and native compiler, deep
mode-aware handlers (multi-shot for Multi operations and affine for Once), row inference and capability manifests, Dist inference
handlers, the ringed standard library, Warp tests, record/replay, fault injection,
dry-run, dist-diff, formatter, canonical structural diff, and the
executable-escrow demo.

## Built Artifact

The build is the OCaml package in this repository:

- package metadata: `jacquard.opam`
- binary: `jacquard`
- library: `src/`
- prelude: `prelude/*.jqd`
- CLI tests: `test/cli/*.t` and `test/gauntlet/*.t`
- unit/property tests: `test/test_jacquard.exe`

The inventory and limits below describe the tagged candidate. Later development
must publish separate evidence rather than silently reusing this pack.

## Test Inventory

Exact counts collected with:

```sh
opam exec -- dune build test/test_jacquard.exe
cd _build/default/test
./test_jacquard.exe list --color=never 2>/dev/null | wc -l
find ../../../test -name '*.t' | wc -l
```

Current inventory:

- Alcotest/QCheck cases: `632`
- Cram transcript files: `32`
- Gauntlet cram files: `4`
- Escrow transcript: `test/cli/escrow.t`
- Larger case-study transcript: `test/cli/case-studies.t`

`test/test_surface_laws.ml` validates the two evolving counts above against the
compiled Alcotest list and the recursive `test/**/*.t` inventory, and requires
this evidence file and `DECISION.md` to agree.

## Commands

Release verification commands:

```sh
eval "$(opam env)"
opam exec -- dune build @all
opam exec -- dune runtest
runtime/check.sh
CC=clang opam exec -- sh scripts/native-diff.sh
CC=clang opam exec -- sh scripts/native-leak-check.sh
CC=clang opam exec -- dune build @native-fuzz
opam exec -- dune fmt
_build/default/bin/main.exe --version
opam exec -- dune runtest test/cli/escrow.t
opam exec -- dune runtest test/gauntlet
cd _build/default/test && ./test_jacquard.exe test 'gauntlet-.*' --compact --color=never
```

The reproduction script [reproduce-0.1.sh](../../../scripts/release/reproduce-0.1.sh)
runs the same checks and writes generated evidence under
`.scratch/release/0.1/` by default.
Public demo transcripts run `.jac` programs through the `jac` alias; the demo
and inference crams also execute retained `.jqd` carriers and compare paired
semantic hashes. Bootstrap remains the internal/debug kernel format of record.

## Claim Proofs

The claim matrix is [CLAIMS.md](CLAIMS.md). The short version:

- identity claims are pinned by `test/test_canon.ml`, `test/cli/hash.t`,
  `test/cli/warp.t`, `test/gauntlet/hashing.t`, and `test/cli/escrow.t`
- handler claims are pinned by `test/test_handlers.ml` and
  `test/test_gauntlet_handlers.ml`
- capability claims are pinned by `test/cli/manifest.t`,
  `test/cli/world.t`, `test/cli/native.t`, `test/gauntlet/eval-capabilities.t`, and
  `test/cli/escrow.t`
- Dist claims are pinned by `test/test_infer.ml`, `test/test_dist_lib.ml`,
  `test/test_gauntlet_dist.ml`, and `test/cli/infer.t`
- Warp/dry-run/replay/dist-diff claims are pinned by `test/cli/warp.t`,
  `test/cli/tools.t`, `test/test_replay.ml`, and `test/cli/escrow.t`
- product-scale alternate-world examples are pinned by
  `test/cli/case-studies.t`, including exhaustive 18- and 27-world Warp runs

## Claims Not Made

Jacquard core 0.1 does not claim:

- production compiler maturity
- that the implemented `.jac` surface syntax is frozen or a second semantics
- a production optimizer, VM, or native runtime; the tested native compiler has
  documented unsupported grants and slow paths
- continuous distributions, gradients, or differentiable inference
- typed staging or macro expansion
- package management or self-hosting
- a formal proof of row soundness
- path-scoped filesystem/network authority
- per-value object capabilities

See [LIMITS.md](LIMITS.md).

## Known Caveats

- `eval-code` runs at root authority once `eval` is granted. Granting `eval`
  alone does not install `net`/`fs`, but eval payloads may contain direct
  resolved hash refs if the corresponding world grant is also present.
- `fs` and `net` grants are coarse in 0.1; interposition exists but the root
  grant is whole-effect.
- Top-level effectful definitions are rejected by the checker (`E0815`) rather
  than supported through implicit eta-expansion.
- The Warp cache has strong coverage for reformat/comment changes and semantic
  dependency edits; a top-level rename cache case is not separately pinned.
- Direct resolved refs inside eval payloads are documented as a policy risk, not
  rejected in 0.1.

## Reproduction

Fresh-clone instructions are in [REPRO.md](REPRO.md). The minimal shape is:

```sh
git checkout jacquard-core-0.1-rc1
git merge-base --is-ancestor 738dc8e HEAD
opam install --deps-only . --with-test --with-dev-setup --with-doc -y
opam exec -- dune build @all
opam exec -- dune runtest
opam exec -- dune fmt
_build/default/bin/main.exe --version
JACQUARD_RELEASE_REF=HEAD JACQUARD_RELEASE_BASE=738dc8e \
  scripts/release/reproduce-0.1.sh
```
