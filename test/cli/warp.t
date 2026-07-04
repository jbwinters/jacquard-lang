Warp (W6.2/W6.3/W6.8): type-directed discovery, two lanes, the hermetic result
cache, and semantic coverage.

  $ export WEFT_PRELUDE=$PWD/../../prelude

  $ cat > suite.wft <<'WEFT'
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
  > WEFT

Discovery is by checked type only (D12): the int named test-looking-name is not
a test; the group recurses; the prop reports skipped until W6.4; the world test
refuses without grants. Zero-check warning and failure detail render inline.

  $ weft test suite.wft --cache-dir wcache
  PASS a-group/grouped/inner (1 check)
  SKIP freq-prop/sampled (prop: driver pending (W6.4))
  WARN lazy-one/does nothing: made no checks
  REFUSED needs-world: requires --allow fs,clock,console,net
  PASS pure-math/arithmetic (1 check)
  PASS shout-appends/appends bang (1 check)
  4 passed, 0 failed, 1 skipped, 1 refused
  cache: 0 hit, 4 ran

The world lane runs under its grants (and is never cached):

  $ weft test suite.wft --cache-dir wcache --allow fs --allow clock --allow console --allow net | grep needs-world
  PASS needs-world/touches fs (1 check)
  $ ls wcache | wc -l
  4

DOC-MANDATED CACHE TEST 1 — a reformat/comment edit reruns ZERO tests: the
metadata law keeps hashes identical, so the second run is a full hit.

  $ cat >> suite.wft <<'WEFT'
  > ; a trailing comment: meta only, no hash changes anywhere
  > WEFT
  $ weft test suite.wft --cache-dir wcache | tail -2
  4 passed, 0 failed, 1 skipped, 1 refused
  cache: 4 hit, 0 ran

DOC-MANDATED CACHE TEST 2 — editing a leaf dependency reruns exactly the
transitively-dependent tests: shout's body changes, so shout-appends (and only
shout-appends) re-keys and reruns — and now fails, honestly.

  $ sed 's/(lit "!")/(lit "?")/' suite.wft > suite2.wft
  $ weft test suite2.wft --cache-dir wcache
  PASS a-group/grouped/inner (1 check) [cached]
  SKIP freq-prop/sampled (prop: driver pending (W6.4))
  WARN lazy-one/does nothing: made no checks [cached]
  REFUSED needs-world: requires --allow fs,clock,console,net
  PASS pure-math/arithmetic (1 check) [cached]
  FAIL shout-appends/appends bang
    - shout: expected hi!, got hi?
  3 passed, 1 failed, 1 skipped, 1 refused
  cache: 3 hit, 1 ran
  [1]

DOC-MANDATED CACHE TEST 3 — the cache is copy-portable because keys are
content: a copied directory in a fresh tree yields a full-hit run.

  $ mkdir fresh-tree && cp -r wcache fresh-tree/moved-cache && cp suite.wft fresh-tree/
  $ cd fresh-tree && weft test suite.wft --cache-dir moved-cache | tail -1 && cd ..
  cache: 4 hit, 0 ran

--no-cache bypasses; a corrupted entry is ignored and rerun, not fatal:

  $ weft test suite.wft --no-cache | tail -1
  4 passed, 0 failed, 1 skipped, 1 refused
  $ for f in wcache/*.wft; do echo garbage > $f; done
  $ weft test suite.wft --cache-dir wcache | tail -1
  cache: 0 hit, 4 ran

Coverage (W6.8): the complement of what tests executed, definition-level, from
the hash discipline alone — and a fully-cached run reports the same complement
because entries record their coverage sets.

  $ weft test suite.wft --cache-dir wcache --coverage | grep -E "coverage:|test-looking" | sed 's/[0-9][0-9]*/N/g'
  coverage: N of N definitions executed
    uncovered test-looking-name
  $ weft test suite.wft --no-cache --coverage > cold.txt
  $ weft test suite.wft --cache-dir wcache --coverage > warm.txt
  $ grep -c "cache: 4 hit" warm.txt
  1
  $ grep uncovered cold.txt > cold-cov.txt && grep uncovered warm.txt > warm-cov.txt
  $ diff cold-cov.txt warm-cov.txt && echo identical
  identical

A test file with a top-level expression is a mistake, named:

  $ echo '(app (var add) (lit 1) (lit 2))' > oops.wft
  $ weft test oops.wft
  error[E1001]: oops.wft: test files hold declarations only; found a top-level expression
  [1]
