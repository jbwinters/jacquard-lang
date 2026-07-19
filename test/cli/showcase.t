
PROGRAM SYNTHESIS AS BAYESIAN INFERENCE (demos/inference/synthesis.jac): sample a
candidate program (code is data), observe that it passes the spec (running
candidates is the eval CAPABILITY — synthesis refuses without the grant), and
read the posterior over programs. One weak test leaves two survivors at the
renormalized prior; one more test proves the correct program at probability 1.

  $ export JACQUARD_PRELUDE=../../prelude
  $ D=../../demos/inference

  $ cat $D/synthesis.jac > syn.jac
  $ cat >> syn.jac <<'JACQUARD'
  > posterior-over-programs(weak-spec())
  > posterior-over-programs(sharp-spec())
  > JACQUARD
  $ jac run syn.jac 2>&1 | head -1
  error[E0814]: The program requires an effect that was not granted
  $ jac run syn.jac --allow eval
  cons(mk-pair((quote (lam ((pvar x)) (app (var add) (var x) (lit 1)))), 0.8), cons(mk-pair((quote (lam ((pvar x)) (app (var add) (var x) (lit 2)))), 0.0), cons(mk-pair((quote (lam ((pvar x)) (app (var sub) (var x) (lit 1)))), 0.0), cons(mk-pair((quote (lam ((pvar x)) (lit 1))), 0.2), nil))))
  cons(mk-pair((quote (lam ((pvar x)) (app (var add) (var x) (lit 1)))), 1.0), cons(mk-pair((quote (lam ((pvar x)) (app (var add) (var x) (lit 2)))), 0.0), cons(mk-pair((quote (lam ((pvar x)) (app (var sub) (var x) (lit 1)))), 0.0), cons(mk-pair((quote (lam ((pvar x)) (lit 1))), 0.0), nil))))
