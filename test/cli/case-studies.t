The larger public case studies run through surface syntax and pin their Warp
evidence, including exhaustive world enumeration.

  $ export JACQUARD_PRELUDE=$PWD/../../prelude
  $ export TMPDIR=$PWD/.scratch/tmp
  $ mkdir -p "$TMPDIR"
  $ D=../../demos/case-studies

Release risk runs one policy under a concrete telemetry snapshot and a
probabilistic handler, then proves the safety property over all 18 worlds.

  $ JACQUARD=jac sh "$D/release-risk/run.sh"
  == inferred authority ==
  release-assessment : () ->{Telemetry} Assessment
  with-snapshot : forall a | e. (Health, Health, Bool, () ->{Telemetry | e} a) ->{| e} a
  with-risk-model : forall a | e. (() ->{Dist, Telemetry | e} a) ->{Dist | e} a
  conditioned-release-risk : () ->{Dist} Decision
  == the same policy under a concrete snapshot handler ==
  assessment(healthy, degraded, false, canary(5))
  == the policy under a probabilistic telemetry handler ==
  0.305077  canary(5)
  0.295394  hold("inventory-down")
  0.184621  canary(10)
  0.155903  hold("payments-down")
  0.059005  ship
  == Warp: cases plus sampled property ==
  PASS release-risk-suite/release risk/the concrete snapshot chooses a five-percent canary (1 check)
  PASS release-risk-suite/release risk/the conditioned posterior is normalized with five decisions (2 checks)
  PASS release-risk-suite/release risk/a down service is never approved to ship (prop: 100 cases, seed 42)
  3 passed, 0 failed, 0 skipped, 0 refused
  == Warp: exhaustive proof over all 18 telemetry worlds ==
  PASS release-risk-suite/release risk/the concrete snapshot chooses a five-percent canary (1 check)
  PASS release-risk-suite/release risk/the conditioned posterior is normalized with five decisions (2 checks)
  PASS release-risk-suite/release risk/a down service is never approved to ship (verified exhaustively (18 cases))
  3 passed, 0 failed, 0 skipped, 0 refused

Stormglass compares naive and resilient checkout policies under the exact same
27-world service forecast. Pin the headline posteriors, then the Warp evidence.

  $ jac run "$D/stormglass/model.jac" | head -2
  cons(mk-pair("clear", 0.72675), cons(mk-pair("choppy", 0.17632), cons(mk-pair("blackout", 0.09693), nil)))
  cons(mk-pair("clear", 0.72675), cons(mk-pair("choppy", 0.25325), cons(mk-pair("blackout", 0.020000000000000004), nil)))

  $ JACQUARD=jac sh "$D/stormglass/run.sh" | sed -n '/^== Warp/,$p'
  == Warp: cases plus sampled properties ==
  PASS stormglass-suite/stormglass/sunny day is deterministic to the millisecond (2 checks)
  PASS stormglass-suite/stormglass/shipping outage: resilient ships anyway, naive gives up (2 checks)
  PASS stormglass-suite/stormglass/resilient strictly beats naive on blackout mass (1 check)
  PASS stormglass-suite/stormglass/no world drives resilient past its fetch budget (prop: 100 cases, seed 42)
  PASS stormglass-suite/stormglass/payment down is never sold as a clear day (prop: 100 cases, seed 42)
  5 passed, 0 failed, 0 skipped, 0 refused
  == Warp: exhaustive proof over all 27 service worlds ==
  PASS stormglass-suite/stormglass/sunny day is deterministic to the millisecond (2 checks)
  PASS stormglass-suite/stormglass/shipping outage: resilient ships anyway, naive gives up (2 checks)
  PASS stormglass-suite/stormglass/resilient strictly beats naive on blackout mass (1 check)
  PASS stormglass-suite/stormglass/no world drives resilient past its fetch budget (verified exhaustively (27 cases))
  PASS stormglass-suite/stormglass/payment down is never sold as a clear day (verified exhaustively (27 cases))
  5 passed, 0 failed, 0 skipped, 0 refused
