The task-71 leak gate: every effect-gauntlet program builds with
ASAN+LeakSanitizer and runs clean (docs/native-plan.md task 71 DoD — the
capture/resume machinery is where RC bugs live). The full harness including
the pure battery is scripts/native-leak-check.sh; this cram runs the effect
set so the dev gate enforces it.

  $ export JACQUARD_PRELUDE=../../prelude
  $ export JACQUARD_RUNTIME=../../runtime
  $ export CC=clang
  $ export JACQUARD=jacquard
  $ sh ../../scripts/native-leak-check.sh ../../test/native-gauntlet/g*.jqd ../../corpus/valid/to-option.jqd ../../corpus/valid/safe-div.jqd ../../demos/m1-choose.jqd 2>&1 | tail -1
  native leak check: PASS
