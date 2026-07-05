
PROGRAM SYNTHESIS AS BAYESIAN INFERENCE (demos/synthesis.wft): sample a
candidate program (code is data), observe that it passes the spec (running
candidates is the eval CAPABILITY — synthesis refuses without the grant), and
read the posterior over programs. One weak test leaves two survivors at the
renormalized prior; one more test proves the correct program at probability 1.

  $ export WEFT_PRELUDE=../../prelude
  $ D=../../demos

  $ cat $D/synthesis.wft > syn.wft
  $ cat >> syn.wft <<'WEFT'
  > (app (var posterior-over-programs) (app (var weak-spec)))
  > (app (var posterior-over-programs) (app (var sharp-spec)))
  > WEFT
  $ weft run syn.wft 2>&1 | head -1
  error[E0814]: this program requires the `eval` effect, which is not granted (performed via `posterior-over-programs`)
  $ weft run syn.wft --allow eval
  cons(mk-pair((quote (lam ((pvar x)) (app (var add) (var x) (lit 1)))), 0.8), cons(mk-pair((quote (lam ((pvar x)) (app (var add) (var x) (lit 2)))), 0.0), cons(mk-pair((quote (lam ((pvar x)) (app (var sub) (var x) (lit 1)))), 0.0), cons(mk-pair((quote (lam ((pvar x)) (lit 1))), 0.2), nil))))
  cons(mk-pair((quote (lam ((pvar x)) (app (var add) (var x) (lit 1)))), 1.0), cons(mk-pair((quote (lam ((pvar x)) (app (var add) (var x) (lit 2)))), 0.0), cons(mk-pair((quote (lam ((pvar x)) (app (var sub) (var x) (lit 1)))), 0.0), cons(mk-pair((quote (lam ((pvar x)) (lit 1))), 0.0), nil))))
