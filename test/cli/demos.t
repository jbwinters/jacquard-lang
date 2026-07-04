The M1 demo programs stay green (milestone gate; demos/m1.sh runs these).

  $ export WEFT_PRELUDE=../../prelude

  $ weft run ../../demos/m1-fact.wft
  120
  $ weft run ../../demos/m1-choose.wft
  cons(1, cons(2, nil))
  $ weft run ../../demos/m1-gated.wft
  error[E0814]: this program requires the `eval` effect, which is not granted (performed via `eval-code`)
    hint: grant it with --allow eval, or handle the effect in the program
  [3]
  $ weft run ../../demos/m1-gated.wft --allow eval
  42

The stdlib worked example (SL.9): word frequency, top 3, console-only manifest.

  $ echo "the cat and the dog and the bird" | weft run ../../demos/word-count.wft --allow console
  text?
  the: 3
  and: 2
  dog: 1
  ()

Without the grant it refuses before reading anything:

  $ weft run ../../demos/word-count.wft
  error[E0814]: this program requires the `console` effect, which is not granted (performed via `main`)
    hint: grant it with --allow console, or handle the effect in the program
  [3]

The probabilistic cookbook (PB.1): VOI, dream mode, self-consistency, drift
monitoring — compositions on the M3 machinery, numbers hand-derived.

  $ cat > cookbook-drive.wft <<'WEFT'
  > (tuple (app (var voi)) (app (var ask?) (lit 1.0)) (app (var ask?) (lit 4.0)))
  > (app (var nested-enumeration))
  > (app (var dist.tally) (app (var dist.enumerate) (lam ()
  >   (app (var dream) (lam () (app (var cautious-agent)))
  >     (app (var categorical)
  >       (app (var cons) (app (var mk-pair) (app (var mk-response) (lit 200) (lit "")) (lit 0.8))
  >         (app (var cons) (app (var mk-pair) (app (var mk-response) (lit 503) (lit "")) (lit 0.2))
  >           (var nil)))))))
  >   (var text.eq))
  > (app (var dist.tally) (app (var dist.enumerate) (var majority3)) (var bool.eq))
  > (tuple
  >   (app (var drift-alarm?) (app (var bernoulli) (lit 0.5))
  >     (app (var cons) (var true) (app (var cons) (var true) (app (var cons) (var true)
  >       (app (var cons) (var true) (app (var cons) (var true) (app (var cons) (var true) (var nil)))))))
  >     (lit 0.05))
  >   (app (var drift-alarm?) (app (var bernoulli) (lit 0.5))
  >     (app (var cons) (var true) (app (var cons) (var true) (app (var cons) (var true) (var nil))))
  >     (lit 0.05)))
  > WEFT
  $ cat ../../demos/cookbook.wft cookbook-drive.wft > cookbook-all.wft
  $ weft run cookbook-all.wft
  (3.5, true, false)
  2.0
  cons(mk-pair("invest", 0.8), cons(mk-pair("hold", 0.2), nil))
  cons(mk-pair(true, 0.7839999999999999), cons(mk-pair(false, 0.21600000000000008), nil))
  (true, false)

The clarifying-question demo: exact value-of-information for interrupting the
user. The agent can answer fast or audit first under uncertainty; asking one
question reveals the user's need, but costs attention.

  $ weft run ../../demos/clarifying-question.wft
  (3.1000000000000005, 6.1, 6.1)
  (8.7, 2.5999999999999996)
  cons(mk-pair("needs-audit", 0.35), cons(mk-pair("quick-answer", 0.65), nil))
  cons(mk-pair("audit-first", 0.35), cons(mk-pair("fast-answer", 0.65), nil))
  ("ask-user", "audit-first", 7.699999999999999, 5.699999999999999)

Agent dream mode: the same policy runs under scripted worlds and a
probabilistic world handler. The policy row honestly says it needs net; the
demo outputs are produced by handlers around that unchanged policy.

  $ sh ../../demos/agent-dream.sh
  == policy authority ==
  support-policy : () ->{net} text
  == scripted worlds and probabilistic dream ==
  "issue-refund"
  "fallback-human"
  cons(mk-pair("issue-refund", 0.55), cons(mk-pair("ask-more", 0.25), cons(mk-pair("fallback-human", 0.2), nil)))

Ambiguity-preserving extraction: an OCR-ish date parse stays a Dist until a
human click is represented as an observation. Downstream routing re-enumerates.

  $ sh ../../demos/ambiguity-pipeline.sh
  cons(mk-pair("Mar 4, 2025", 0.56), cons(mk-pair("Apr 3, 2025", 0.41), cons(mk-pair("Unknown", 0.03), nil)))
  cons(mk-pair("escalate-overdue", 0.56), cons(mk-pair("schedule-followup", 0.41), cons(mk-pair("ask-human", 0.03), nil)))
  cons(mk-pair("escalate-overdue", 0.0), cons(mk-pair("schedule-followup", 0.9999999999999999), cons(mk-pair("ask-human", 0.0), nil)))

The same demos also have Warp tests. The runner reuses each demo's definitions,
strips the top-level output driver, appends `showcase-warp-tests.wft`, and runs
the result through `weft test`.

  $ sh ../../demos/showcase-warp-tests.sh
  PASS demo-ambiguity-click/date posterior survives until user observe (3 checks)
  PASS demo-dream-policy-dist/dream handler matches explicit world distribution (3 checks)
  PASS demo-dream-scripted/scripted worlds run the same policy (2 checks)
  PASS demo-voi-policy/clarifying question asks only when worth it (3 checks)
  4 passed, 0 failed, 0 skipped, 0 refused
