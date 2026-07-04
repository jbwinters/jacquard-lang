Granting dist installs the SAMPLING handler (stdlib SL.7): sample draws one
value; the seed makes runs reproducible.

  $ export WEFT_PRELUDE=../../prelude

  $ cat > die.wft <<'WEFT'
  > (app (var sample) (app (var uniform-int) (lit 1) (lit 6)))
  > WEFT

  $ weft run die.wft --allow dist --seed 42
  5
  $ weft run die.wft --allow dist --seed 42
  5
  $ weft run die.wft --allow dist --seed 7
  3

Without the grant, the manifest refuses to start (exit 3):

  $ weft run die.wft
  error[E0814]: this program requires the `dist` effect, which is not granted (performed via `sample`)
    hint: grant it with --allow dist, or handle the effect in the program
  [3]

Observe reaching the sampling root is a defect (decision D7's default): weft
run cannot condition, only weft infer can.

  $ cat > obs.wft <<'WEFT'
  > (app (var observe) (app (var bernoulli) (lit 0.5)) (var true))
  > WEFT

  $ weft run obs.wft --allow dist --seed 1
  error[E0904]: observe reached the sampling root handler; observation requires an inference driver (use weft infer)
  [2]

The die model runs unchanged under exact enumeration — same program, different
handler (the M3 thesis):

  $ weft infer enumerate die.wft
  0.166667  1
  0.166667  2
  0.166667  3
  0.166667  4
  0.166667  5
  0.166667  6
