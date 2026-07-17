Warp (W6.2/W6.3/W6.8): type-directed discovery, two lanes, the hermetic result
cache, and semantic coverage.

  $ export JACQUARD_PRELUDE=$PWD/../../prelude

Warp accepts the public surface syntax selected by the `.jac` extension. The
test command still enforces its declarations-only boundary after lowering.

SC.11's optional schedule lane requires an explicit seed, validates its count,
uses the same bytes for repeated runs, and puts the scheduler version, count,
and root seed in the hermetic cache identity.

  $ cat > seeded-schedules.jac <<'JACQUARD'
  > seeded-case =
  >   Case("seeded pass", fn () -> {
  >     let _ = async.scope(fn () -> {
  >       let left = async.spawn(fn () -> { async.yield(); 1 })
  >       let right = async.spawn(fn () -> { async.yield(); 2 })
  >       let _ = async.await(left)
  >       async.await(right)
  >     })
  >     check.true(True, "scheduled")
  >   })
  > JACQUARD
  $ jacquard test seeded-schedules.jac --schedules 0 --seed 73 --no-cache
  error[E0908]: --schedules must be positive
    hint: pass --schedules N with N greater than zero
  [1]
  $ jacquard test seeded-schedules.jac --schedules 3 --no-cache
  error[E0908]: --schedules requires --seed so every interleaving is reproducible
    hint: add an explicit --seed S
  [1]
  $ jacquard test seeded-schedules.jac --schedules 3 --seed nope --no-cache 2>&1 | head -2
  Usage: jacquard test [--help] [OPTION]… [FILES]…
  jacquard: option '--seed': invalid value 'nope', expected an integer
  $ jacquard test seeded-schedules.jac --schedules 3 --seed 73 --no-cache
  PASS seeded-case/seeded pass (schedules: 3, seed 73)
  1 passed, 0 failed, 0 skipped, 0 refused
  $ jacquard test seeded-schedules.jac --schedules 3 --seed 73 --no-cache > schedule-a.txt
  $ jacquard test seeded-schedules.jac --schedules 3 --seed 73 --no-cache > schedule-b.txt
  $ diff schedule-a.txt schedule-b.txt && echo identical
  identical
  $ jacquard test seeded-schedules.jac --schedules 3 --seed 73 --cache-dir schedule-cache | tail -1
  cache: 0 hit, 1 ran
  $ jacquard test seeded-schedules.jac --schedules 3 --seed 73 --cache-dir schedule-cache | tail -1
  cache: 1 hit, 0 ran
  $ jacquard test seeded-schedules.jac --schedules 3 --seed 74 --cache-dir schedule-cache | tail -1
  cache: 0 hit, 1 ran
  $ jacquard test seeded-schedules.jac --schedules 4 --seed 73 --cache-dir schedule-cache | tail -1
  cache: 0 hit, 1 ran

A failing run prints the exact root replay command, the failing decision seed,
and the canonical log. Repeating the printed command reproduces byte for byte.

  $ sed 's/check.true(True/check.true(False/' seeded-schedules.jac > failing-schedule.jac
  $ jacquard test failing-schedule.jac --schedules 3 --seed 73 --no-cache > failure-a.txt 2>&1; test $? = 1
  $ jacquard test failing-schedule.jac --schedules 3 --seed 73 --no-cache > failure-b.txt 2>&1; test $? = 1
  $ diff failure-a.txt failure-b.txt && echo identical
  identical
  $ grep -E '^(FAIL|  ! random schedule|replay: jacquard|schedule log:|jacquard-schedule format=1|decision sequence=)' failure-a.txt | head -6
  FAIL seeded-case/seeded pass (schedule: failed 1/3, seed 73)
    ! random schedule 1 of 3 failed (decision seed -1984518348094897688)
  replay: jacquard test 'failing-schedule.jac' --prelude '$TESTCASE_ROOT/../../prelude' --schedules 3 --seed 73 --no-cache
  schedule log:
  jacquard-schedule format=1 scheduler=seeded-random-v0 program=c1d0128d5bb67fccdb81466e42aa7d02fb9217b13fa19d2951f751a55967601c policy=fail-fast max-tasks=1024 max-decisions=100000 fork=-
  decision sequence=0 runnable=0#0 chosen=0#0 operation=async.scope

  $ cat > surface-suite.jac <<'JACQUARD'
  > double(n) = mul(n, 2)
  > surface-case =
  >   Case("surface test", fn () ->
  >     check.eq(double(3), 6, int.eq, int.show, "double"))
  > JACQUARD
  $ jacquard test surface-suite.jac --seed 7 --no-cache
  PASS surface-case/surface test (1 check)
  1 passed, 0 failed, 0 skipped, 0 refused

  $ printf 'answer = 42\nanswer\n' > surface-oops.jac
  $ jacquard test surface-oops.jac
  error[E1001]: surface-oops.jac: test files hold declarations only; found a top-level expression
  [1]

  $ cat > suite.jqd <<'JACQUARD'
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

  $ jacquard test suite.jqd --seed 7 --cache-dir wcache
  PASS a-group/grouped/inner (1 check)
  PASS freq-prop/sampled (prop: 100 cases, seed 7)
  WARN lazy-one/does nothing: made no checks
  REFUSED needs-world: requires --allow console,fs,clock,net
  PASS pure-math/arithmetic (1 check)
  PASS shout-appends/appends bang (1 check)
  5 passed, 0 failed, 0 skipped, 1 refused
  cache: 0 hit, 5 ran

The world lane runs under its grants (and is never cached):

  $ jacquard test suite.jqd --seed 7 --cache-dir wcache --allow fs --allow clock --allow console --allow net | grep needs-world
  PASS needs-world/touches fs (1 check)
  $ ls wcache | wc -l
  5

DOC-MANDATED CACHE TEST 1 — a reformat/comment edit reruns ZERO tests: the
metadata law keeps hashes identical, so the second run is a full hit.

  $ cat >> suite.jqd <<'JACQUARD'
  > ; a trailing comment: meta only, no hash changes anywhere
  > JACQUARD
  $ jacquard test suite.jqd --seed 7 --cache-dir wcache | tail -2
  5 passed, 0 failed, 0 skipped, 1 refused
  cache: 5 hit, 0 ran

DOC-MANDATED CACHE TEST 2 — editing a leaf dependency reruns exactly the
transitively-dependent tests: shout's body changes, so shout-appends (and only
shout-appends) re-keys and reruns — and now fails, honestly.

  $ sed 's/(lit "!")/(lit "?")/' suite.jqd > suite2.jqd
  $ jacquard test suite2.jqd --seed 7 --cache-dir wcache
  PASS a-group/grouped/inner (1 check) [cached]
  PASS freq-prop/sampled (prop: 100 cases, seed 7) [cached]
  WARN lazy-one/does nothing: made no checks [cached]
  REFUSED needs-world: requires --allow console,fs,clock,net
  PASS pure-math/arithmetic (1 check) [cached]
  FAIL shout-appends/appends bang
    - shout: expected hi!, got hi?
  4 passed, 1 failed, 0 skipped, 1 refused
  cache: 4 hit, 1 ran
  [1]

DOC-MANDATED CACHE TEST 3 — the cache is copy-portable because keys are
content: a copied directory in a fresh tree yields a full-hit run.

  $ mkdir fresh-tree && cp -r wcache fresh-tree/moved-cache && cp suite.jqd fresh-tree/
  $ cd fresh-tree && jacquard test suite.jqd --seed 7 --cache-dir moved-cache | tail -1 && cd ..
  cache: 5 hit, 0 ran

--no-cache bypasses; a corrupted entry is ignored and rerun, not fatal:

  $ jacquard test suite.jqd --seed 7 --no-cache | tail -1
  5 passed, 0 failed, 0 skipped, 1 refused
  $ for f in wcache/*.jqd; do echo garbage > $f; done
  $ jacquard test suite.jqd --seed 7 --cache-dir wcache | tail -1
  cache: 0 hit, 5 ran

Coverage (W6.8): the complement of what tests executed, definition-level, from
the hash discipline alone — and a fully-cached run reports the same complement
because entries record their coverage sets.

  $ jacquard test suite.jqd --seed 7 --cache-dir wcache --coverage | grep -E "coverage:|test-looking" | sed 's/[0-9][0-9]*/N/g'
  coverage: N of N definitions executed
    uncovered test-looking-name
  $ jacquard test suite.jqd --seed 7 --no-cache --coverage > cold.txt
  $ jacquard test suite.jqd --seed 7 --cache-dir wcache --coverage > warm.txt
  $ grep -c "cache: 4 hit" warm.txt
  0
  [1]
  $ grep uncovered cold.txt > cold-cov.txt && grep uncovered warm.txt > warm-cov.txt
  $ diff cold-cov.txt warm-cov.txt && echo identical
  identical

A test file with a top-level expression is a mistake, named:

  $ echo '(app (var add) (lit 1) (lit 2))' > oops.jqd
  $ jacquard test oops.jqd
  error[E1001]: oops.jqd: test files hold declarations only; found a top-level expression
  [1]

W6.6's load-bearing move: a fixture is a store object referenced by hash, so
EDITING THE FIXTURE re-keys every referencing test — cache invalidation with
zero new machinery.

  $ cat > fixture-suite.jqd <<'JACQUARD'
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
  $ jacquard test fixture-suite.jqd --seed 7 --cache-dir fcache | tail -1
  cache: 0 hit, 1 ran
  $ jacquard test fixture-suite.jqd --seed 7 --cache-dir fcache | tail -1
  cache: 1 hit, 0 ran

Edit ONE response text in the fixture: the test re-keys and reruns (and now
fails honestly, since the body pins the old text).

  $ sed 's/pinned/EDITED/' fixture-suite.jqd > fixture-suite2.jqd
  $ sed -i 's/(var body) (lit "EDITED")/(var body) (lit "pinned")/' fixture-suite2.jqd
  $ jacquard test fixture-suite2.jqd --seed 7 --cache-dir fcache
  FAIL replay-case/replays the fixture
    - served: expected pinned, got EDITED
  0 passed, 1 failed, 0 skipped, 0 refused
  cache: 0 hit, 1 ran
  [1]
