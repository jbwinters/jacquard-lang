jac infer (M3): inference algorithms are handlers over an unchanged model.
This cram is the checked-in transcript for demos/inference/m3.sh.

  $ export JACQUARD_PRELUDE=../../prelude

Exact enumeration of the two-coins model (2/3, 1/3):

  $ jac hash ../../demos/inference/m3-two-coins.jac > model.before.hash
  $ sed 's/[0-9a-f]\{64\}/HASH/' model.before.hash
  0 HASH
  $ jac infer enumerate ../../demos/inference/m3-two-coins.jac
  0.666667  true
  0.333333  false
  $ jac hash ../../demos/inference/m3-two-coins.jac > model.after-enum.hash
  $ cmp model.before.hash model.after-enum.hash

Likelihood weighting with a fixed seed converges and is reproducible:

  $ jac infer lw ../../demos/inference/m3-two-coins.jac --seed 42 --samples 100000
  0.667898  true
  0.332102  false
  $ jac hash ../../demos/inference/m3-two-coins.jac > model.after-lw.hash
  $ cmp model.before.hash model.after-lw.hash
  $ jac infer lw ../../demos/inference/m3-two-coins.jac --seed 42 --samples 100000
  0.667898  true
  0.332102  false

A different seed differs:

  $ jac infer lw ../../demos/inference/m3-two-coins.jac --seed 7 --samples 1000 > a.txt
  $ jac infer lw ../../demos/inference/m3-two-coins.jac --seed 8 --samples 1000 > b.txt
  $ cmp -s a.txt b.txt; echo "same=$?"
  same=1

The seed is required (decision D4):

  $ jac infer lw ../../demos/inference/m3-two-coins.jac 2>&1 | grep -c 'required'
  1

The bootstrap model remains an equivalent inference carrier.

  $ jac hash ../../demos/inference/m3-two-coins.jqd > model.bootstrap.hash
  $ cmp model.before.hash model.bootstrap.hash
  $ jac infer enumerate ../../demos/inference/m3-two-coins.jqd
  0.666667  true
  0.333333  false

An ungranted effect inside a model still refuses (dist itself is implicit):

  $ cat > naughty.jqd <<'EOF_JQD'
  > (let nonrec (pwild) (app (var print) (lit "leak"))
  >   (app (var sample) (app (var bernoulli) (lit 0.5))))
  > EOF_JQD
  $ jac infer enumerate naughty.jqd
  error[E0814]: The program requires an effect that was not granted
    Cause: This program requires console [world/low] — talk to the process terminal, which is not granted (performed via `print`).
    Next step: grant it with --allow console, or handle the effect in the program
  [1]
