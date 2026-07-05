Hashing gauntlet: hash/check/infer-style readers do not mutate model identity.

  $ export JACQUARD_PRELUDE=../../prelude

  $ cat > model.jqd <<'EOF_JQD'
  > (let nonrec (pvar c) (app (var sample) (app (var bernoulli) (lit 0.5)))
  >   (var c))
  > EOF_JQD
  $ jacquard hash model.jqd > h0
  $ jacquard check model.jqd --manifest dist
  ok
  $ jacquard hash model.jqd > h1
  $ cmp h0 h1
  $ jacquard infer enumerate model.jqd
  0.500000  false
  0.500000  true
  $ jacquard hash model.jqd > h2
  $ cmp h0 h2
