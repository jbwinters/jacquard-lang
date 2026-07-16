The committed transcript for demos/worlds/preflight.sh: generated agent plans
are quoted Code, alternate worlds are the observations, and the live policy
still needs a Net grant after the dreams pass. Weak outage-only evidence leaves
the prior intact; sharp three-world evidence proves the cautious plan.

  $ export JACQUARD_PRELUDE=../../prelude

  $ JACQUARD=jac sh ../../demos/worlds/preflight.sh
  == rows: dreams need eval; the live policy needs net ==
  cautious-plan : Code
  eager-plan : Code
  hold-plan : Code
  plan-prior : () ->{} Distribution Code
  run-plan : forall a. (Code) ->{Eval} a
  scripted : forall a. (Code, Response) ->{Eval} a
  passes-sharp? : (Code) ->{Eval} Bool
  passes-weak? : (Code) ->{Eval} Bool
  preflight : forall | e. ((Code) ->{| e} Bool) ->{Dist | e} Code
  preflight-weak : () ->{Dist, Eval} Code
  preflight-sharp : () ->{Dist, Eval} Code
  posterior-weak : () ->{Eval} List (Pair Code Real)
  posterior-sharp : () ->{Eval} List (Pair Code Real)
  surviving : forall a. (List (Pair a Real)) ->{} List (Pair a Real)
  plan-label : (Code) ->{} Text
  labeled-posterior : (List (Pair Code Real)) ->{} List (Pair Text Real)
  map-plan : (List (Pair Code Real)) ->{} Code
  live-policy : () ->{Net} Text
  _ : Int
  _ : List (Pair Text Real)
  _ : List (Pair Text Real)
  _ : Text
  _ : Text
  _ : Text
  == without grants the pure prefix runs; the first posterior refuses ==
  3
  error[E0814]: this program requires eval [meta/high] — run code constructed or loaded at runtime, which is not granted (performed via `posterior-weak`)
    hint: grant it with --allow eval, or handle the effect in the program
  exit code: 3
  == with eval: posteriors and diffs; live policy still refuses without net ==
  3
  cons(mk-pair("cautious", 0.5), cons(mk-pair("eager", 0.3), cons(mk-pair("hold", 0.2), nil)))
  cons(mk-pair("cautious", 1.0), nil)
  "at log/lam[1]/match[1]/clause[1]/match[2]/clause[1]: - (lit \"issue-refund\") + (match (app (var text.contains?) (var body) (lit \"refund\")) (clause (pcon true) (lit \"issue-refund\")) (clause (pcon false) (lit \"ask-more\")))"
  "at log/lam[1]/match[1]/clause[1]/match[2]/clause[1]: - (lit \"ask-more\") + (match (app (var text.contains?) (var body) (lit \"refund\")) (clause (pcon true) (lit \"issue-refund\")) (clause (pcon false) (lit \"ask-more\")))"
  error[E0814]: this program requires net [world/high] — reach a network endpoint through the granted handler, which is not granted (performed via `live-policy`)
    hint: grant it with --allow net, or handle the effect in the program
  exit code: 3
