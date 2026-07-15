# Release Decision

Status: RC

Candidate tag: `jacquard-core-0.1-rc1` (the tag resolves the exact reviewed commit)
Required lineage base: `738dc8e`
Version: `0.1.0`  
Test count: `632` Alcotest/QCheck cases
Cram count: `32` transcript files

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

Collect external feedback without widening the 0.1 feature surface; correctness,
portability, documentation, and evidence fixes remain in scope.

## Decision

Ready to tag as `jacquard-core-0.1-rc1`.

Verified in this hardening pass with:

```sh
opam exec -- dune build @all
opam exec -- dune runtest
opam exec -- dune fmt
scripts/release/reproduce-0.1.sh
```

The reproduction script records the exact checked-out commit in
`.scratch/release/0.1/commit.txt` and writes its generated evidence under
`.scratch/release/0.1/` by default. The claim matrix is
[CLAIMS.md](CLAIMS.md).
