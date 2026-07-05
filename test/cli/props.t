Warp property lanes (W6.4 sampling + shrinking, W6.5 exhaustive, W6.9).

  $ export JACQUARD_PRELUDE=$PWD/../../prelude

  $ cat > props.jqd <<'JACQUARD'
  > (defterm ((binding rev-broken ()
  >   (app (var prop) (lit "rev is identity (mutated)")
  >     (lam ()
  >       (app (var prop.for)
  >         (lam () (app (var gen.list) (lam () (app (var sample) (app (var uniform-int) (lit 0) (lit 9)))) (lit 8)))
  >         (lam ((pvar xs))
  >           (app (var check.eq)
  >             (app (var list.reverse) (app (var list.reverse) (var xs)))
  >             (app (var list.take) (var xs) (lit 3))
  >             (app (var eq.for-list) (var int.eq))
  >             (app (var show.for-list) (var int.show))
  >             (lit "rev roundtrip")))))))))
  > (defterm ((binding needle ()
  >   (app (var prop) (lit "avoids 777")
  >     (lam ()
  >       (let nonrec (pvar x) (app (var sample) (app (var uniform-int) (lit 0) (lit 999)))
  >         (app (var check.true) (app (var bool.not) (app (var eq) (var x) (lit 777))) (lit "not 777"))))))))
  > JACQUARD

Sampling mode falsifies and SHRINKS: the choice log minimizes greedily (delete
spans, lower indices), and every candidate replays through the generator itself.
The minimal case here is the shortest list where take 3 diverges — length 4,
all-zero elements — found from a length-8 generator.

  $ jacquard test props.jqd --seed 42 --samples 50 --no-cache
  PASS needle/avoids 777 (prop: 50 cases, seed 42)
  FAIL rev-broken/rev is identity (mutated) (prop: falsified on case 1 of 50, seed 42; shrunk to 5 choices [4;0;0;0;0])
    - rev roundtrip: expected [0, 0, 0], got [0, 0, 0, 0]
  1 passed, 1 failed, 0 skipped, 0 refused
  [1]

The doc's whole argument in one run: needle PASSES sampling (seed-lucky above)
but exhaustive mode explores every support element and finds 777 — same Prop
bytes, different handler.

  $ jacquard test props.jqd --exhaustive --no-cache | grep needle
  FAIL needle/avoids 777 (prop: falsified exhaustively)

Exceeding the branch budget is a clean catalogued refusal, never a partial
pass posing as a proof:

  $ cat > small.jqd <<'JACQUARD'
  > (defterm ((binding coin-ok ()
  >   (app (var prop) (lit "boolean coin")
  >     (lam ()
  >       (let nonrec (pvar c) (app (var sample) (app (var bernoulli) (lit 0.5)))
  >         (app (var check.true) (app (var bool.or) (var c) (app (var bool.not) (var c))) (lit "t"))))))))
  > (defterm ((binding needle-too ()
  >   (app (var prop) (lit "needs branches")
  >     (lam ()
  >       (let nonrec (pvar x) (app (var sample) (app (var uniform-int) (lit 0) (lit 999)))
  >         (app (var check.true) (var true) (lit "t"))))))))
  > JACQUARD
  $ jacquard test small.jqd --exhaustive --budget 100 --no-cache
  PASS coin-ok/boolean coin (verified exhaustively (2 cases))
  FAIL needle-too/needs branches (prop: exhaustive refusal)
    ! error[E0905]: exhaustive verification exceeded its budget: 101 explorations (cap 100), last at a 1000-way sample site; raise --budget or shrink the generators
  1 passed, 1 failed, 0 skipped, 0 refused
  [1]

An exhaustive PASS is a proof for that content hash: the cache entry renders
distinctly and skips re-proving.

  $ jacquard test small.jqd --exhaustive --cache-dir pc | grep coin-ok
  PASS coin-ok/boolean coin (verified exhaustively (2 cases))
  $ jacquard test small.jqd --exhaustive --cache-dir pc | grep coin-ok
  PASS coin-ok/boolean coin (verified exhaustively (2 cases)) [cached proof]

W6.9: two formulations of the same model agree pointwise at 1e-9 — the
refactoring test for inference. A deliberately different model fails with the
per-outcome diff rendered through Show.

  $ cat > dists.jqd <<'JACQUARD'
  > (defterm ((binding sampler-ok ()
  >   (app (var case) (lit "optimized model matches reference")
  >     (lam ()
  >       (app (var check.same-dist)
  >         (lam () (let nonrec (pvar a) (app (var sample) (app (var bernoulli) (lit 0.5)))
  >           (let nonrec (pvar b) (app (var sample) (app (var bernoulli) (lit 0.5)))
  >             (match (tuple (var a) (var b))
  >               (clause (ptuple (pcon true) (pcon true)) (lit 2))
  >               (clause (ptuple (pcon false) (pcon false)) (lit 0))
  >               (clause (pwild) (lit 1))))))
  >         (lam () (app (var sample) (app (var categorical)
  >           (app (var cons) (app (var mk-pair) (lit 0) (lit 0.25))
  >             (app (var cons) (app (var mk-pair) (lit 1) (lit 0.5))
  >               (app (var cons) (app (var mk-pair) (lit 2) (lit 0.25)) (var nil)))))))
  >         (var int.eq) (var int.show) (lit 0.000000001)))))))
  > (defterm ((binding drifted ()
  >   (app (var case) (lit "drifted model caught")
  >     (lam ()
  >       (app (var check.posterior)
  >         (lam () (app (var sample) (app (var bernoulli) (lit 0.7))))
  >         (app (var cons) (app (var mk-pair) (var true) (lit 0.5))
  >           (app (var cons) (app (var mk-pair) (var false) (lit 0.5)) (var nil)))
  >         (var bool.eq) (var bool.show) (lit 0.01)))))))
  > JACQUARD
  $ jacquard test dists.jqd --no-cache --seed 1
  FAIL drifted/drifted model caught
    - posterior: P(true) = 0.7, expected 0.5
    - posterior: P(false) = 0.30000000000000004, expected 0.5
  PASS sampler-ok/optimized model matches reference (3 checks)
  1 passed, 1 failed, 0 skipped, 0 refused
  [1]
