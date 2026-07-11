# Release Decision

Status: RC

Commit: successor merge base `d8b2147a3ad9`; inventory refreshed on the evolving successor
Version: `0.1.0`  
Test count: `554` Alcotest/QCheck cases
Cram count: `30` transcript files

## Known Blockers

None known in the release branch after the escrow transcript and syntax fixes.

## Non-Blocking Caveats

- Direct resolved refs inside eval payloads are allowed under matching grants.
- World grants are coarse whole-effect grants.
- The implemented `.jac` projection and native compiler are research-prototype
  surfaces, not frozen syntax or a production VM/runtime. There is no package
  manager, typed staging, gradients, macro expansion, self-hosting, or formal
  soundness proof.
- Warp cache has comment/reformat and semantic dependency edit proofs; top-level
  rename cache behavior is not separately pinned.

## Recommended Tag

`jacquard-core-0.1-rc1`

## Recommended Next Milestone

External rejection review: have a reviewer try to disprove the claim matrix and
reproduction script before tagging.

## Decision

Ready to tag as `jacquard-core-0.1-rc1`.

Verified in this hardening pass with:

```sh
opam exec -- dune build @all
opam exec -- dune runtest
opam exec -- dune fmt
scripts/release/reproduce-0.1.sh
```

The reproduction script passed from this release branch checkout and writes its
generated evidence under `.scratch/release/0.1/` by default. The next step
before final tagging is an external rejection review against
[CLAIMS.md](CLAIMS.md).
