The M1 demo programs stay green (milestone gate; demos/m1.sh runs these).

  $ export WEFT_PRELUDE=../../prelude

  $ weft run ../../demos/m1-fact.wft
  120
  $ weft run ../../demos/m1-choose.wft
  cons(1, cons(2, nil))
  $ weft run ../../demos/m1-gated.wft
  error[E0814]: this program requires the `eval` effect, which is not granted (performed via `eval-code`)
    hint: grant it with --allow eval, or handle the effect in the program
  [3]
  $ weft run ../../demos/m1-gated.wft --allow eval
  42
