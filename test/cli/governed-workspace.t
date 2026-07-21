GM.18 runs one unchanged Workspace-only deployment agent through grant-free
simulation, nested live policies, the real durable approval bridge, a verified
audit chain, demo-specific Warp laws, and GM.15's existing hostile matrix.

  $ export TMPDIR=$TESTTMP
  $ sh ../../demos/governed-workspace/run.sh
  == unchanged Workspace-only agent ==
  governed-deploy-agent : () ->{Workspace} Result ToolError Response
  agent-id fab711efd085966134e843f93e201de04b8aeb966a54313ef414ff5997951e77
  == deterministic dry and nested live worlds ==
  ("agent/dry", "simulated", 202, 8, "raw-actions", 0)
  ("agent/live-nested/strict-outer", "refused", 3, "raw-actions", 0)
  ("agent/live-nested/permissive-outer", "allowed", 16, "raw-actions", 4)
  ("call-id/policy-id/proposal-id", ok(("e73e16e6f1659873b45eafdeb84f161180cd72d9e8e790369f44683bd63ab672", "94542d3681b9b6f6530545f93c391276bbca4813854c9f75e4d6f26407e1da6e", "0057b000967a9ee86a0fc792a31dfefeab06af5b1606f76c16fba311374ebf16")))
  == durable approval queue host bridge ==
  ("agent/queue-denial", "Governance_approval_bridge", "durable exact proposal", "Denied", "raw-actions", 0)
  == verified audit chain for inner pass then outer refusal ==
  ok 96b9bef50b9eaf21ffa1ed26bfc35eb37f433d1474892d3512c43205f1d4913a
  == Warp: sampled demo laws ==
  PASS governed-workspace-suite/governed workspace/dry run simulates all four calls without raw authority (2 checks)
  PASS governed-workspace-suite/governed workspace/inner allow forwards the same call to outer block (1 check)
  PASS governed-workspace-suite/governed workspace/a denial is bound to the exact deployment proposal (1 check)
  PASS governed-workspace-suite/governed workspace/changing only the outer policy changes the outcome (prop: 100 cases, seed 42)
  4 passed, 0 failed, 0 skipped, 0 refused
  == Warp: exhaustive strict/permissive policy worlds ==
  PASS governed-workspace-suite/governed workspace/dry run simulates all four calls without raw authority (2 checks)
  PASS governed-workspace-suite/governed workspace/inner allow forwards the same call to outer block (1 check)
  PASS governed-workspace-suite/governed workspace/a denial is bound to the exact deployment proposal (1 check)
  PASS governed-workspace-suite/governed workspace/changing only the outer policy changes the outcome (verified exhaustively (2 cases))
  4 passed, 0 failed, 0 skipped, 0 refused
  == GM.15 hostile fault space (existing executable lane) ==
  PASS governance-fault-path-count/literal 349-site and 698-path arithmetic (2 checks)
  PASS governance-hostile-matrix/immutable FaultPlan covers 698 typed-error/fail-stop paths (verified exhaustively (349 cases))
  2 passed, 0 failed, 0 skipped, 0 refused
