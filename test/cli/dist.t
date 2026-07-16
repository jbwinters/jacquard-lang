Granting dist installs the SAMPLING handler (stdlib SL.7): sample draws one
value; the seed makes runs reproducible.

  $ export JACQUARD_PRELUDE=../../prelude

  $ cat > die.jqd <<'JACQUARD'
  > (app (var sample) (app (var uniform-int) (lit 1) (lit 6)))
  > JACQUARD

  $ jacquard run die.jqd --allow dist --seed 42
  5
  $ jacquard run die.jqd --allow dist --seed 42
  5
  $ jacquard run die.jqd --allow dist --seed 7
  3

Without the grant, the manifest refuses to start (exit 3):

  $ jacquard run die.jqd
  error[E0814]: this program requires dist [uncertainty/none] — denote and condition finite possibilities, which is not granted (performed via `sample`)
    hint: grant it with --allow dist, or handle the effect in the program
  [3]

Observe reaching the sampling root is a defect (decision D7's default): jacquard
run cannot condition, only jacquard infer can.

  $ cat > obs.jqd <<'JACQUARD'
  > (app (var observe) (app (var bernoulli) (lit 0.5)) (var true))
  > JACQUARD

  $ jacquard run obs.jqd --allow dist --seed 1
  error[E0904]: observe reached the sampling root handler; observation requires an inference driver (use jacquard infer)
  [2]

The die model runs unchanged under exact enumeration — same program, different
handler (the M3 thesis):

  $ jacquard infer enumerate die.jqd
  0.166667  1
  0.166667  2
  0.166667  3
  0.166667  4
  0.166667  5
  0.166667  6
