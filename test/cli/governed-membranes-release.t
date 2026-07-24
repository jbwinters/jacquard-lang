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

The GM.21 successor checker reconstructs the exact predecessor when Git is
available, runs its immutable GM.19/GM.22 checker there, and then verifies the
complete GM.21 overlay and pinned predecessor attestations.

  $ ../../scripts/release/check-gm21-manifest.sh
  note: historical reconstruction unavailable; verified retained GM.22 files and pinned attestations
  GM.19/GM.22 predecessor attestations are preserved and byte-consistent
  GM.21 successor release pack is complete and byte-consistent
