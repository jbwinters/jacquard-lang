The committed transcript for demos/repair.sh: program repair as Bayesian
inference. Candidate patches are computed from the shipped program's quoted
AST (code.un-form to descend, code.form to splice back — pure, and the rows
say so); a bug report is an observation; running a candidate is the eval
capability. One failing test leaves two survivors — the intended fix at 0.75
and an overfitting patch at 0.25; one regression test proves the intended
patch at probability 1. The Warp suite covers the pure machinery: the
posterior itself needs eval, which Warp's closed {check} row cannot grant.

  $ export JACQUARD_PRELUDE=../../prelude

  $ sh ../../demos/repair.sh
  == the rows announce the authority: mutation is pure, running candidates is eval ==
  buggy-sum-to : code
  intended-fix : code
  op-swaps : list code
  op-mutants : (code) ->{} list code
  lit-mutants : (code) ->{} list code
  leaf-edits : (code) ->{} list (code, text)
  set-nth : forall a. (list a, int, a) ->{} list a
  code-mutants : (code) ->{} list (code, text)
  patch-weight : (text) ->{} real
  patch-prior : (code) ->{} distribution code
  passes? : forall a. (code, list (a, int)) ->{eval} bool
  repair : forall a. (code, list (a, int)) ->{dist, eval} code
  posterior-over-patches : forall a. (code, list (a, int)) ->{eval} list (pair code real)
  surviving-patches : forall a. (list (pair a real)) ->{} list (pair a real)
  map-patch : forall a. (a, list (pair a real)) ->{} a
  bug-report : list (int, int)
  regression-spec : list (int, int)
  _ : int
  _ : list (pair code real)
  _ : text
  _ : list (pair code real)
  _ : text
  == without the grant the pure prefix runs; the first posterior refuses ==
  8
  error[E0814]: this program requires the `eval` effect, which is not granted (performed via `posterior-over-patches`)
    hint: grant it with --allow eval, or handle the effect in the program
  exit code: 3
  == the granted run: mutant count, posteriors, and the MAP patch ==
  8
  cons(mk-pair((quote (lam ((pvar n)) (app (var div) (app (var mul) (var n) (app (var add) (var n) (lit 1))) (lit 2)))), 0.75), cons(mk-pair((quote (lam ((pvar n)) (app (var div) (app (var mul) (var n) (app (var sub) (var n) (lit 1))) (lit 1)))), 0.25), nil))
  "at log/lam[1]/app[1]/app[2]/app[0]/var[0]: - sub + add"
  cons(mk-pair((quote (lam ((pvar n)) (app (var div) (app (var mul) (var n) (app (var add) (var n) (lit 1))) (lit 2)))), 1.0), nil)
  "at log/lam[1]/app[1]/app[2]/app[0]/var[0]: - sub + add"
  == Warp tests over the pure machinery ==
  PASS repair-mutation-space/single edits of the shipped program (4 checks)
  PASS repair-patch-rendering/the patch is one readable divergence (1 check)
  PASS repair-prior-shape/prior centers on the shipped program (4 checks)
  PASS repair-prior-support/sampled patches stay one edit away (prop: 100 cases, seed 7)
  4 passed, 0 failed, 0 skipped, 0 refused

The prop lane also proves its property exhaustively over the prior's nine
support points:

  $ awk '/^; --- demo driver ---$/ { exit } { print }' ../../demos/repair.jqd > repair-defs.jqd
  $ cat repair-defs.jqd ../../demos/repair-warp-tests.jqd > repair-suite.jqd
  $ jacquard test repair-suite.jqd --exhaustive --no-cache | grep repair-prior-support
  PASS repair-prior-support/sampled patches stay one edit away (verified exhaustively (9 cases))
