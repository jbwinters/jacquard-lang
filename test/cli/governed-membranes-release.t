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

The GM.22 release pack is indexed, has one D61-D73 claim row each, retains the
bounded product wording and hash caveats, and covers the complete source overlay.

  $ ../../scripts/release/check-governed-membranes-manifest.sh
  governed-membranes GM.22 release pack is complete and byte-consistent
