The M1 demo programs stay green (milestone gate; demos/m1.sh runs these).

  $ export WEFT_PRELUDE=../../prelude

  $ weft run ../../demos/m1-fact.wft
  120
  $ weft run ../../demos/m1-choose.wft
  (1, 2)
  $ weft run ../../demos/m1-gated.wft
  unhandled effect eval: operation `eval-code` reached the root without a handler
  [3]
  $ weft run ../../demos/m1-gated.wft --allow eval
  42
