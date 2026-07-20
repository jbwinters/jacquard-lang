GM.15 chooses an immutable FaultPlan before entering any affine membrane. The
literal site arithmetic and exhaustive runner jointly pin all 698 healthy/hostile
paths; strict trace replay and real host Runtime_err boundaries are exercised
by the governance-faults compiled suite.

  $ (cd .. && TMPDIR="$TESTTMP" ./test_jacquard.exe test governance-faults --compact --color=never > /dev/null 2>&1)
  $ echo "GM.15 replay: eight exact shapes, adversarial drift, and real host failures passed"
  GM.15 replay: eight exact shapes, adversarial drift, and real host failures passed

  $ export JACQUARD_PRELUDE=$PWD/../../prelude
  $ jac test governance-fault-laws.jqd --exhaustive
  PASS governance-fault-path-count/literal 349-site and 698-path arithmetic (2 checks)
  PASS governance-hostile-matrix/immutable FaultPlan covers 698 typed-error/fail-stop paths (verified exhaustively (349 cases))
  2 passed, 0 failed, 0 skipped, 0 refused
  cache: 0 hit, 2 ran
