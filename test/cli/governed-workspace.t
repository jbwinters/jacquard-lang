GM.18 runs one unchanged Workspace-only deployment agent through grant-free
simulation, nested live policies, the real durable approval bridge, a bounded
agent-specific fault world, a verified audit chain, and demo-specific Warp
laws. GM.15's existing hostile matrix remains supporting infrastructure.

  $ export TMPDIR=$TESTTMP
  $ sh ../../demos/governed-workspace/run.sh
  == unchanged Workspace-only agent ==
  governed-deploy-agent : () ->{Workspace} Result ToolError Response
  agent-id fab711efd085966134e843f93e201de04b8aeb966a54313ef414ff5997951e77
  == inferred dry/live authority ==
  dry-world : forall a. () ->{} Result a (Result ToolError Response, List AuditEntry)
  live-world : forall a. (Risk, Risk) ->{Secret, Fs, Net} Result a (Result ToolError Response, List AuditEntry)
  == deterministic world-free dry and agent fault worlds ==
  ("agent/dry", "simulated", 202, 8, "raw-actions", 0)
  ("call-id/policy-id/proposal-id", ok(("e73e16e6f1659873b45eafdeb84f161180cd72d9e8e790369f44683bd63ab672", "fc90806170e9d902775c96263539a673c1f440259d178c24dd42058a8ca75ec1", "90d9ca81e7e55d61d8176476589f15fb14a907ce67175f745552db2dc65bba38")))
  ("agent/fault-all", "all-prefixes-valid", "paths", 16, "prefixes", "manifest:8/artifact:4/write:2/deployment:1/healthy:1", "healthy", 1, "failing", 15, "deployment-max", 1)
  == deterministic nested live drivers ==
  ("agent/live-nested/strict-outer", "refused", "audit", 3, "fs.read", 0, "fs.write", 0, "net.fetch", 0, "secret.read", 0, "secret.expose", 0)
  ("agent/live-nested/permissive-outer", "allowed:202", "audit", 16, "fs.read", 1, "fs.write", 1, "net.fetch", 2, "secret.read", 2, "secret.expose", 2)
  live-driver-order fs.read>secret.read>secret.expose>net.fetch>fs.write>secret.read>secret.expose>net.fetch
  live-deploy-boundary proposal-id 90d9ca81e7e55d61d8176476589f15fb14a907ce67175f745552db2dc65bba38 validated-before-deployment-net
  ("semantic-policy-diff", "agent-id", "fab711efd085966134e843f93e201de04b8aeb966a54313ef414ff5997951e77", "strict-policy-id", "0940c2e81b1c82048f3b13c67e681c42eeafe288dc059d17cf8c493fd3dd63e1", "permissive-policy-id", "fc90806170e9d902775c96263539a673c1f440259d178c24dd42058a8ca75ec1", "strict", "refused", "permissive", "allowed:202", "agent-changed", false)
  == durable approval queue host bridge ==
  ("agent/queue-denial", "proposal-id", "90d9ca81e7e55d61d8176476589f15fb14a907ce67175f745552db2dc65bba38", "Denied", "queue-records", 3, "fs.read", 0, "fs.write", 0, "net.fetch", 0, "secret.read", 0, "secret.expose", 0)
  == verified audit chain for inner pass then outer refusal ==
  ok 96b9bef50b9eaf21ffa1ed26bfc35eb37f433d1474892d3512c43205f1d4913a
  == Warp: sampled demo laws ==
  PASS governed-workspace-suite/governed workspace/dry run simulates all four calls without raw authority (2 checks)
  PASS governed-workspace-suite/governed workspace/inner allow forwards the same call to outer block (1 check)
  PASS governed-workspace-suite/governed workspace/a denial is bound to the exact deployment proposal (1 check)
  PASS governed-workspace-suite/governed workspace/fault.all covers every governed agent failure prefix (3 checks)
  PASS governed-workspace-suite/governed workspace/changing only the outer policy changes the outcome (prop: 100 cases, seed 42)
  5 passed, 0 failed, 0 skipped, 0 refused
  == Warp: exhaustive policy and agent fault worlds ==
  PASS governed-workspace-suite/governed workspace/dry run simulates all four calls without raw authority (2 checks)
  PASS governed-workspace-suite/governed workspace/inner allow forwards the same call to outer block (1 check)
  PASS governed-workspace-suite/governed workspace/a denial is bound to the exact deployment proposal (1 check)
  PASS governed-workspace-suite/governed workspace/fault.all covers every governed agent failure prefix (3 checks)
  PASS governed-workspace-suite/governed workspace/changing only the outer policy changes the outcome (verified exhaustively (2 cases))
  5 passed, 0 failed, 0 skipped, 0 refused
  == GM.15 supporting hostile infrastructure ==
  PASS governance-fault-path-count/literal 349-site and 698-path arithmetic (2 checks)
  PASS governance-hostile-matrix/immutable FaultPlan covers 698 typed-error/fail-stop paths (verified exhaustively (349 cases))
  2 passed, 0 failed, 0 skipped, 0 refused
