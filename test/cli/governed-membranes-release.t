  $ export JACQUARD_PRELUDE=$PWD/../../prelude

GM.20 freezes only a pure exact-posterior reference calculation. The fixture
proves the inclusive tail boundary, non-discardable Forbidden mass,
conservative baseline join, numeric refusals, and the fact that approximate
evidence cannot produce an assessment. It does not install a Judge handler or
change the live gate.

  $ jac test ../../docs/release/governed-membranes/GM20-FIXTURE.jqd --exhaustive --no-cache
  PASS gm20-boundary-examples/exact projection boundaries (6 checks)
  PASS gm20-invalid-and-nonauthorizing/invalid and approximate inputs fail closed (8 checks)
  PASS gm20-monotone-join/posterior projection never lowers baseline risk (verified exhaustively (16 cases))
  3 passed, 0 failed, 0 skipped, 0 refused

SC.17 preserves the GM.21 manifest and checker as historical anchors because
its cancellation correction supersedes two shared integration files. The
SC.17 successor checker owns full reconstruction; this transcript pins the
retained anchors while keeping the GM.20/GM.21 semantic probes here.

  $ (cd ../.. && test "$(sha256sum docs/release/governed-membranes/GM21-MANIFEST.sha256 | awk '{print $1}')" = 19603651590eb6de890a7e3597b009403f03234d6d5f022b076497d8a638e45f)
  $ (cd ../.. && test "$(sha256sum scripts/release/check-gm21-manifest.sh | awk '{print $1}')" = 14fcc2ec9274d1dde793ef534591c4d757934089d0510424e52187e9b0fd5a82)
  $ echo "GM.21 historical attestation anchors are byte-consistent"
  GM.21 historical attestation anchors are byte-consistent
