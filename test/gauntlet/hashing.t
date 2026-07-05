Hashing gauntlet: hash/check/infer-style readers do not mutate model identity.

  $ export JACQUARD_PRELUDE=../../prelude

  $ cat > model.wft <<'EOF_WFT'
  > (let nonrec (pvar c) (app (var sample) (app (var bernoulli) (lit 0.5)))
  >   (var c))
  > EOF_WFT
  $ jacquard hash model.wft > h0
  $ jacquard check model.wft --manifest dist
  ok
  $ jacquard hash model.wft > h1
  $ cmp h0 h1
  $ jacquard infer enumerate model.wft
  0.500000  false
  0.500000  true
  $ jacquard hash model.wft > h2
  $ cmp h0 h2
