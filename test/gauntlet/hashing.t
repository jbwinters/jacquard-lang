Hashing gauntlet: hash/check/infer-style readers do not mutate model identity.

  $ export WEFT_PRELUDE=../../prelude

  $ cat > model.wft <<'EOF_WFT'
  > (let nonrec (pvar c) (app (var sample) (app (var bernoulli) (lit 0.5)))
  >   (var c))
  > EOF_WFT
  $ weft hash model.wft > h0
  $ weft check model.wft --manifest dist
  ok
  $ weft hash model.wft > h1
  $ cmp h0 h1
  $ weft infer enumerate model.wft
  0.500000  false
  0.500000  true
  $ weft hash model.wft > h2
  $ cmp h0 h2
