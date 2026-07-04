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

The stdlib worked example (SL.9): word frequency, top 3, console-only manifest.

  $ echo "the cat and the dog and the bird" | weft run ../../demos/word-count.wft --allow console
  text?
  the: 3
  and: 2
  dog: 1
  ()

Without the grant it refuses before reading anything:

  $ weft run ../../demos/word-count.wft
  error[E0814]: this program requires the `console` effect, which is not granted (performed via `main`)
    hint: grant it with --allow console, or handle the effect in the program
  [3]
