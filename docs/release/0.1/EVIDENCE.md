# Weft Core 0.1 Evidence

Status: release-candidate evidence pack for `release/0.1-evidence`.

Candidate base: `3609a67`  
Evidence branch predecessor: `7d7733f`  
Version surface: `weft --version` prints `0.1.0`

This pack describes Weft core as implemented on the release branch: the kernel
triple reader/validator/resolver, HASH_V0 canonical identity, the content store,
the CPS evaluator with deep multi-shot handlers, row inference and capability
manifests, Dist inference handlers, the ringed standard library, Warp tests,
record/replay, fault injection, dry-run, dist-diff, formatter, semantic diff, and
the executable-escrow demo.

## Built Artifact

The build is the OCaml package in this repository:

- package metadata: `weft.opam`
- binary: `weft`
- library: `src/`
- prelude: `prelude/*.wft`
- CLI tests: `test/cli/*.t` and `test/gauntlet/*.t`
- unit/property tests: `test/test_weft.exe`

The branch is intentionally not a feature branch. Changes after the candidate
base are limited to release hardening, escrow demo completion, and evidence
documentation.

## Test Inventory

Exact counts collected with:

```sh
opam exec -- dune build test/test_weft.exe
cd _build/default/test
./test_weft.exe list --color=never 2>/dev/null | wc -l
find ../../../test -name '*.t' | wc -l
```

Current inventory:

- Alcotest/QCheck cases: `308`
- Cram transcript files: `21`
- Gauntlet cram files: `4`
- Escrow transcript: `test/cli/escrow.t`

## Commands

Release verification commands:

```sh
eval "$(opam env)"
opam exec -- dune build @all
opam exec -- dune runtest
opam exec -- dune fmt
_build/default/bin/main.exe --version
opam exec -- dune runtest test/cli/escrow.t
opam exec -- dune runtest test/gauntlet
cd _build/default/test && ./test_weft.exe test 'gauntlet-.*' --compact --color=never
```

The reproduction script [reproduce-0.1.sh](../../../scripts/release/reproduce-0.1.sh)
runs the same checks and writes demo transcripts under `logs/release/0.1/`.

## Claim Proofs

The claim matrix is [CLAIMS.md](CLAIMS.md). The short version:

- identity claims are pinned by `test/test_canon.ml`, `test/cli/hash.t`,
  `test/cli/warp.t`, `test/gauntlet/hashing.t`, and `test/cli/escrow.t`
- handler claims are pinned by `test/test_handlers.ml` and
  `test/test_gauntlet_handlers.ml`
- capability claims are pinned by `test/cli/manifest.t`,
  `test/cli/world.t`, `test/gauntlet/eval-capabilities.t`, and
  `test/cli/escrow.t`
- Dist claims are pinned by `test/test_infer.ml`, `test/test_dist_lib.ml`,
  `test/test_gauntlet_dist.ml`, and `test/cli/infer.t`
- Warp/dry-run/replay/dist-diff claims are pinned by `test/cli/warp.t`,
  `test/cli/tools.t`, `test/test_replay.ml`, and `test/cli/escrow.t`

## Claims Not Made

Weft core 0.1 does not claim:

- production compiler maturity
- a stable surface syntax beyond bootstrap S-expressions
- a VM, optimizer, or native backend
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
git checkout release/0.1-evidence
git merge-base --is-ancestor 3609a67 HEAD
opam install --deps-only . --with-test --with-dev-setup --with-doc -y
opam exec -- dune build @all
opam exec -- dune runtest
opam exec -- dune fmt
_build/default/bin/main.exe --version
scripts/release/reproduce-0.1.sh
```
