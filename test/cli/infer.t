weft infer (M3): inference algorithms are handlers over an unchanged model.
This cram is the checked-in transcript for demos/m3.sh.

  $ export WEFT_PRELUDE=../../prelude

Exact enumeration of the two-coins model (2/3, 1/3):

  $ weft infer enumerate ../../demos/m3-two-coins.wft
  0.666667  true
  0.333333  false

Likelihood weighting with a fixed seed converges and is reproducible:

  $ weft infer lw ../../demos/m3-two-coins.wft --seed 42 --samples 100000
  0.667898  true
  0.332102  false
  $ weft infer lw ../../demos/m3-two-coins.wft --seed 42 --samples 100000
  0.667898  true
  0.332102  false

A different seed differs:

  $ weft infer lw ../../demos/m3-two-coins.wft --seed 7 --samples 1000 > a.txt
  $ weft infer lw ../../demos/m3-two-coins.wft --seed 8 --samples 1000 > b.txt
  $ cmp -s a.txt b.txt; echo "same=$?"
  same=1

The seed is required (decision D4):

  $ weft infer lw ../../demos/m3-two-coins.wft 2>&1 | grep -c 'required'
  1

An ungranted effect inside a model still refuses (dist itself is implicit):

  $ cat > naughty.wft <<'EOF_WFT'
  > (let nonrec (pwild) (app (var print) (lit "leak"))
  >   (app (var sample) (app (var bernoulli) (lit 0.5))))
  > EOF_WFT
  $ weft infer enumerate naughty.wft
  error[E0814]: this program requires the `console` effect, which is not granted (performed via `print`)
    hint: grant it with --allow console, or handle the effect in the program
  [1]
