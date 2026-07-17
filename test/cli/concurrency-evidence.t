SC.16 runs one checked task program under all four shipped C2 scheduler seams.
The checker output proves that spawning keeps Async and the child's Net effect,
while async.scope removes only Async. The exhaustive tree has exactly eight
complete, unique, replayable schedules.

  $ export JACQUARD_PRELUDE=$PWD/../../prelude
  $ JACQUARD=jac sh ../../demos/concurrency/run.sh
  == child authority stays visible ==
  spawn-net : () ->{Async, Net} Task Text
  scoped-net : () ->{Net} TaskResult (TaskResult Text)
  == one task program, four scheduler handlers ==
  program-hash=0c6c2bb245f0fd38e47abfd04313156954f74e7a1ca2eb4d0ca553c93ce1098a
  trace-format=1
  round-robin scheduler=fifo-round-robin-v0 result=0 tasks=3 decisions=5 trace=13b32f8467e9d40e38117f9d46ca47e6ab9665fe68272efa8a9082c63aab94a8
  seeded scheduler=seeded-random-v0 seed=20260717 result=0 tasks=3 decisions=5 trace=f911e0e95e08a9b1c1e312381a7f8c6ae6d07101d1e2e9a4ddfecf0216044327
  exhaustive completeness=complete explored=8 worlds-started=8 unique-traces=8 all-zero=true
  replay source=round-robin result=0 byte-identical=true
  exhaustive-replay worlds=8 byte-identical=true
