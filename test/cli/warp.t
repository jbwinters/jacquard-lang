Warp (W6.2/W6.3/W6.8): type-directed discovery, two lanes, the hermetic result
cache, and semantic coverage.

  $ export JACQUARD_PRELUDE=$PWD/../../prelude

  $ cat > suite.wft <<'JACQUARD'
  > (defterm ((binding shout ()
  >   (lam ((pvar s)) (app (var text.concat) (var s) (lit "!"))))))
  > (defterm ((binding shout-appends ()
  >   (app (var case) (lit "appends bang")
  >     (lam () (app (var check.eq) (app (var shout) (lit "hi")) (lit "hi!") (var text.eq) (var text.show) (lit "shout")))))))
  > (defterm ((binding pure-math ()
  >   (app (var case) (lit "arithmetic")
  >     (lam () (app (var check.true) (app (var eq) (app (var add) (lit 1) (lit 1)) (lit 2)) (lit "1+1")))))))
  > (defterm ((binding a-group ()
  >   (app (var group) (lit "grouped")
  >     (app (var cons)
  >       (app (var case) (lit "inner") (lam () (app (var check.true) (var true) (lit "in"))))
  >       (var nil))))))
  > (defterm ((binding freq-prop ()
  >   (app (var prop) (lit "sampled")
  >     (lam () (let nonrec (pwild) (app (var sample) (app (var bernoulli) (lit 0.5))) (app (var check.true) (var true) (lit "t"))))))))
  > (defterm ((binding needs-world ()
  >   (app (var wcase) (lit "touches fs")
  >     (lam ()
  >       (let nonrec (pwild) (app (var write) (lit "w.txt") (lit "x"))
  >         (app (var check.eq) (app (var read) (lit "w.txt")) (lit "x") (var text.eq) (var text.show) (lit "roundtrip"))))))))
  > (defterm ((binding test-looking-name () (lit 42))))
  > (defterm ((binding lazy-one ()
  >   (app (var case) (lit "does nothing") (lam () (tuple))))))
  > JACQUARD

Discovery is by checked type only (D12): the int named test-looking-name is not
a test; the group recurses; the prop reports skipped until W6.4; the world test
refuses without grants. Zero-check warning and failure detail render inline.

  $ jacquard test suite.wft --seed 7 --cache-dir wcache
  PASS a-group/grouped/inner (1 check)
  PASS freq-prop/sampled (prop: 100 cases, seed 7)
  WARN lazy-one/does nothing: made no checks
  REFUSED needs-world: requires --allow fs,clock,console,net
  PASS pure-math/arithmetic (1 check)
  PASS shout-appends/appends bang (1 check)
  5 passed, 0 failed, 0 skipped, 1 refused
  cache: 0 hit, 5 ran

The world lane runs under its grants (and is never cached):

  $ jacquard test suite.wft --seed 7 --cache-dir wcache --allow fs --allow clock --allow console --allow net | grep needs-world
  PASS needs-world/touches fs (1 check)
  $ ls wcache | wc -l
  5

DOC-MANDATED CACHE TEST 1 — a reformat/comment edit reruns ZERO tests: the
metadata law keeps hashes identical, so the second run is a full hit.

  $ cat >> suite.wft <<'JACQUARD'
  > ; a trailing comment: meta only, no hash changes anywhere
  > JACQUARD
  $ jacquard test suite.wft --seed 7 --cache-dir wcache | tail -2
  5 passed, 0 failed, 0 skipped, 1 refused
  cache: 5 hit, 0 ran

DOC-MANDATED CACHE TEST 2 — editing a leaf dependency reruns exactly the
transitively-dependent tests: shout's body changes, so shout-appends (and only
shout-appends) re-keys and reruns — and now fails, honestly.

  $ sed 's/(lit "!")/(lit "?")/' suite.wft > suite2.wft
  $ jacquard test suite2.wft --seed 7 --cache-dir wcache
  PASS a-group/grouped/inner (1 check) [cached]
  PASS freq-prop/sampled (prop: 100 cases, seed 7) [cached]
  WARN lazy-one/does nothing: made no checks [cached]
  REFUSED needs-world: requires --allow fs,clock,console,net
  PASS pure-math/arithmetic (1 check) [cached]
  FAIL shout-appends/appends bang
    - shout: expected hi!, got hi?
  4 passed, 1 failed, 0 skipped, 1 refused
  cache: 4 hit, 1 ran
  [1]

DOC-MANDATED CACHE TEST 3 — the cache is copy-portable because keys are
content: a copied directory in a fresh tree yields a full-hit run.

  $ mkdir fresh-tree && cp -r wcache fresh-tree/moved-cache && cp suite.wft fresh-tree/
  $ cd fresh-tree && jacquard test suite.wft --seed 7 --cache-dir moved-cache | tail -1 && cd ..
  cache: 5 hit, 0 ran

--no-cache bypasses; a corrupted entry is ignored and rerun, not fatal:

  $ jacquard test suite.wft --seed 7 --no-cache | tail -1
  5 passed, 0 failed, 0 skipped, 1 refused
  $ for f in wcache/*.wft; do echo garbage > $f; done
  $ jacquard test suite.wft --seed 7 --cache-dir wcache | tail -1
  cache: 0 hit, 5 ran

Coverage (W6.8): the complement of what tests executed, definition-level, from
the hash discipline alone — and a fully-cached run reports the same complement
because entries record their coverage sets.

  $ jacquard test suite.wft --seed 7 --cache-dir wcache --coverage | grep -E "coverage:|test-looking" | sed 's/[0-9][0-9]*/N/g'
  coverage: N of N definitions executed
    uncovered test-looking-name
  $ jacquard test suite.wft --seed 7 --no-cache --coverage > cold.txt
  $ jacquard test suite.wft --seed 7 --cache-dir wcache --coverage > warm.txt
  $ grep -c "cache: 4 hit" warm.txt
  0
  [1]
  $ grep uncovered cold.txt > cold-cov.txt && grep uncovered warm.txt > warm-cov.txt
  $ diff cold-cov.txt warm-cov.txt && echo identical
  identical

A test file with a top-level expression is a mistake, named:

  $ echo '(app (var add) (lit 1) (lit 2))' > oops.wft
  $ jacquard test oops.wft
  error[E1001]: oops.wft: test files hold declarations only; found a top-level expression
  [1]

W6.6's load-bearing move: a fixture is a store object referenced by hash, so
EDITING THE FIXTURE re-keys every referencing test — cache invalidation with
zero new machinery.

  $ cat > fixture-suite.wft <<'JACQUARD'
  > (defterm ((binding my-fixture ()
  >   (quote (log (op (lit "fetch") (request (lit "http://a") (lit "")) (response (lit 200) (lit "pinned"))))))))
  > (defterm ((binding replay-case ()
  >   (app (var case) (lit "replays the fixture")
  >     (lam ()
  >       (let nonrec (pvar body)
  >         (app (var throw.catch)
  >           (lam () (app (var test.replay) (var my-fixture)
  >             (lam () (match (app (var fetch) (app (var mk-request) (lit "http://a") (lit "")))
  >               (clause (pcon mk-response (pwild) (pvar b)) (var b))))))
  >           (lam ((pvar e)) (var e)))
  >         (app (var check.eq) (var body) (lit "pinned") (var text.eq) (var text.show) (lit "served"))))))))
  > JACQUARD
  $ jacquard test fixture-suite.wft --seed 7 --cache-dir fcache | tail -1
  cache: 0 hit, 1 ran
  $ jacquard test fixture-suite.wft --seed 7 --cache-dir fcache | tail -1
  cache: 1 hit, 0 ran

Edit ONE response text in the fixture: the test re-keys and reruns (and now
fails honestly, since the body pins the old text).

  $ sed 's/pinned/EDITED/' fixture-suite.wft > fixture-suite2.wft
  $ sed -i 's/(var body) (lit "EDITED")/(var body) (lit "pinned")/' fixture-suite2.wft
  $ jacquard test fixture-suite2.wft --seed 7 --cache-dir fcache
  FAIL replay-case/replays the fixture
    - served: expected pinned, got EDITED
  0 passed, 1 failed, 0 skipped, 0 refused
  cache: 0 hit, 1 ran
  [1]
