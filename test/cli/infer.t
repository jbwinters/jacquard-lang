jacquard infer (M3): inference algorithms are handlers over an unchanged model.
This cram is the checked-in transcript for demos/m3.sh.

  $ export JACQUARD_PRELUDE=../../prelude

Exact enumeration of the two-coins model (2/3, 1/3):

  $ jacquard hash ../../demos/m3-two-coins.jqd > model.before.hash
  $ sed 's/[0-9a-f]\{64\}/HASH/' model.before.hash
  0 HASH
  $ jacquard infer enumerate ../../demos/m3-two-coins.jqd
  0.666667  true
  0.333333  false
  $ jacquard hash ../../demos/m3-two-coins.jqd > model.after-enum.hash
  $ cmp model.before.hash model.after-enum.hash

Likelihood weighting with a fixed seed converges and is reproducible:

  $ jacquard infer lw ../../demos/m3-two-coins.jqd --seed 42 --samples 100000
  0.667898  true
  0.332102  false
  $ jacquard hash ../../demos/m3-two-coins.jqd > model.after-lw.hash
  $ cmp model.before.hash model.after-lw.hash
  $ jacquard infer lw ../../demos/m3-two-coins.jqd --seed 42 --samples 100000
  0.667898  true
  0.332102  false

A different seed differs:

  $ jacquard infer lw ../../demos/m3-two-coins.jqd --seed 7 --samples 1000 > a.txt
  $ jacquard infer lw ../../demos/m3-two-coins.jqd --seed 8 --samples 1000 > b.txt
  $ cmp -s a.txt b.txt; echo "same=$?"
  same=1

The seed is required (decision D4):

  $ jacquard infer lw ../../demos/m3-two-coins.jqd 2>&1 | grep -c 'required'
  1

An ungranted effect inside a model still refuses (dist itself is implicit):

  $ cat > naughty.jqd <<'EOF_JQD'
  > (let nonrec (pwild) (app (var print) (lit "leak"))
  >   (app (var sample) (app (var bernoulli) (lit 0.5))))
  > EOF_JQD
  $ jacquard infer enumerate naughty.jqd
  error[E0814]: this program requires the `console` effect, which is not granted (performed via `print`)
    hint: grant it with --allow console, or handle the effect in the program
  [1]
