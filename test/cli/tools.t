The CLI tooling tail (TL.1-TL.3, PV.1): consequences as data, counterfactuals,
posterior diffs.

  $ export JACQUARD_PRELUDE=$PWD/../../prelude

TL.2 --dry-run: the audit trail BEFORE the consequences. Reads and the clock
are real; writes and fetches become records; no grants required; nothing
mutates.

  $ cat > script.jqd <<'JACQUARD'
  > (let nonrec (pwild) (app (var write) (lit "report.txt") (lit "hello"))
  >   (let nonrec (pwild) (app (var write) (lit "backup.txt") (lit "world!"))
  >     (match (app (var fetch) (app (var mk-request) (lit "http://example.com/api") (lit "")))
  >       (clause (pcon mk-response (pwild) (pvar b)) (var b)))))
  > JACQUARD
  $ jacquard run script.jqd --dry-run
  "<dry-run response>"
  dry-run dispositions: console=forwarded clock=forwarded fs.read=forwarded fs.write=audited net.fetch=audited+simulated infer.complete=audited+simulated dist=simulated(seed 0) eval=refused
  dry-run: this run WOULD have:
    written report.txt (5 bytes)
    written backup.txt (6 bytes)
    fetched http://example.com/api
  $ ls report.txt
  ls: cannot access 'report.txt': No such file or directory
  [2]

The same script under real grants performs the writes:

  $ jacquard run script.jqd --allow fs --allow net > /dev/null
  $ cat report.txt
  hello

Read forwarding is real: the dry world serves actual file contents (reads are
observation, not consequence).

  $ printf 'fixture-content' > fixture.txt
  $ printf '(app (var read) (lit "fixture.txt"))\n' > reader.jqd
  $ jacquard run reader.jqd --dry-run | head -1
  "fixture-content"

A manifest that includes eval refuses --dry-run: eval'd code runs at root
authority and cannot be dried.

  $ printf '(app (var eval-code) (quote (lit 1)))\n' > evil.jqd
  $ jacquard run evil.jqd --dry-run
  error[E1002]: --dry-run cannot sandbox eval: eval'd code runs at root authority and bypasses the dry handlers
  [1]

TL.3 counterfactual replay: record once, then scrub and fork the trajectory.
The log is a readable form; the program is any .jqd; forked futures run under
the dry handlers (no world mutation).

  $ cat > mklog.jqd <<'JACQUARD'
  > (app (var throw.catch)
  >   (lam ()
  >     (match
  >       (app (var net.scripted)
  >         (lam () (app (var net.record)
  >           (lam ()
  >             (match (app (var fetch) (app (var mk-request) (lit "http://api/step1") (lit "")))
  >               (clause (pcon mk-response (pwild) (pwild))
  >                 (match (app (var fetch) (app (var mk-request) (lit "http://api/step2") (lit "")))
  >                   (clause (pcon mk-response (pwild) (pvar b2)) (var b2))))))))
  >         (app (var cons) (app (var mk-response) (lit 200) (lit "alpha."))
  >           (app (var cons) (app (var mk-response) (lit 200) (lit "beta.")) (var nil))))
  >       (clause (ptuple (pwild) (pvar log)) (var log))))
  >   (lam ((pwild)) (quote (log))))
  > JACQUARD
  $ jacquard run mklog.jqd | sed -e 's/^(quote //' -e 's/)$//' > trace.jqd

A status-SENSITIVE program: it retries against a fallback host when step1
fails. Straight replay reproduces the recorded world. A fork at op 1 sends the
trajectory down the other branch; serving stays POSITIONAL (op 2 still gets the
logged answer — "what if the world had answered the same"), and --compare is
what renders the request divergence.

  $ cat > prog.jqd <<'JACQUARD'
  > (match (app (var fetch) (app (var mk-request) (lit "http://api/step1") (lit "")))
  >   (clause (pcon mk-response (pvar status) (pwild))
  >     (match (app (var eq) (var status) (lit 200))
  >       (clause (pcon true)
  >         (match (app (var fetch) (app (var mk-request) (lit "http://api/step2") (lit "")))
  >           (clause (pcon mk-response (pwild) (pvar b)) (var b))))
  >       (clause (pcon false)
  >         (match (app (var fetch) (app (var mk-request) (lit "http://fallback/step1") (lit "")))
  >           (clause (pcon mk-response (pwild) (pvar b)) (var b)))))))
  > JACQUARD
  $ jacquard replay trace.jqd prog.jqd
  "beta."
  $ jacquard replay trace.jqd prog.jqd --fork '1=(response 500 "down")'
  "beta."
  $ jacquard replay trace.jqd prog.jqd --fork '1=(response 500 "down")' --compare
  "beta."
  divergence report (original log vs fork):
    op1: identical request
    at op2/request[0]/lit[0]: - "http://api/step2" + "http://fallback/step1"

Both futures of a binary counterfactual, tabulated (the M1 Choose demo as a
debugger feature — one fork per answer; --to 1 sends everything past the fork
to the live-dry world so the futures are distinguishable):

  $ jacquard replay trace.jqd prog.jqd --fork '1=(response 200 "up")' --to 1 | tail -1
  "<live-after-log>"
  $ jacquard replay trace.jqd prog.jqd --fork '1=(response 503 "down")' --to 1 | tail -1
  "<live-after-log>"
  $ jacquard replay trace.jqd prog.jqd --fork '1=(response 200 "up")' --to 1 --compare | grep op2
    op2: identical request
  $ jacquard replay trace.jqd prog.jqd --fork '1=(response 503 "down")' --to 1 --compare | grep -c fallback
  1

Scrubbing: --to N serves the log through op N, then the dry world takes over.

  $ jacquard replay trace.jqd prog.jqd --to 1
  "<live-after-log>"

TL.1 dist-diff: posterior divergence between model versions. Deltas over
tolerance sorted by magnitude; hand-derived: prior 0.6 gives P(2)=0.36,
P(0)=0.16, P(1)=0.48.

  $ cat > coins-a.jqd <<'JACQUARD'
  > (defterm ((binding prior () (lit 0.5))))
  > (let nonrec (pvar c1) (app (var sample) (app (var bernoulli) (var prior)))
  >   (let nonrec (pvar c2) (app (var sample) (app (var bernoulli) (var prior)))
  >     (match (tuple (var c1) (var c2))
  >       (clause (ptuple (pcon true) (pcon true)) (lit 2))
  >       (clause (ptuple (pcon false) (pcon false)) (lit 0))
  >       (clause (pwild) (lit 1)))))
  > JACQUARD
  $ sed 's/(lit 0.5)/(lit 0.6)/' coins-a.jqd > coins-b.jqd
  $ jacquard dist-diff coins-a.jqd coins-b.jqd --tolerance 0.001 2>/dev/null
  P(2): 0.250000 -> 0.360000 (delta +0.110000)
  P(0): 0.250000 -> 0.160000 (delta -0.090000)
  P(1): 0.500000 -> 0.480000 (delta -0.020000)
  $ jacquard dist-diff coins-a.jqd coins-a.jqd 2>/dev/null
  no divergence

Support changes are the usual bug, so they render distinctly. Models whose
RESULT TYPES differ refuse before any probability is compared:

  $ cat > coin-support.jqd <<'JACQUARD'
  > (match (app (var sample) (app (var bernoulli) (lit 0.5)))
  >   (clause (pcon true) (lit 1))
  >   (clause (pcon false) (lit 3)))
  > JACQUARD
  $ jacquard dist-diff coins-a.jqd coin-support.jqd --tolerance 0.001 2>/dev/null | sort
  support gained: 3
  support lost:   0
  support lost:   2
  $ printf '(match (app (var sample) (app (var bernoulli) (lit 0.5))) (clause (pcon true) (lit "yes")) (clause (pcon false) (lit "no")))\n' > texty.jqd
  $ jacquard dist-diff coins-a.jqd texty.jqd 2>&1 | head -1
  error[E0801]: dist-diff: model result types differ (coins-a.jqd : int, texty.jqd : text); probabilities over different types are not comparable

Enumerations cache by content hash: the second identical diff is a full hit,
and a sweep value equal to the reference REUSES its cache entry (content
addressing, not bookkeeping).

  $ jacquard dist-diff coins-a.jqd coins-b.jqd --tolerance 0.001 2>&1 >/dev/null | grep -c cached
  2
  $ jacquard dist-diff coins-a.jqd coins-b.jqd --tolerance 0.001 --sweep prior=0.5,0.9 2>/dev/null
  -- sweep prior=0.5 --
  no divergence
  -- sweep prior=0.9 --
  P(2): 0.250000 -> 0.810000 (delta +0.560000)
  P(1): 0.500000 -> 0.180000 (delta -0.320000)
  P(0): 0.250000 -> 0.010000 (delta -0.240000)

PV.1 in review flow: --print-sigs shows the origin next to the signature (the
review story: "this change adds net, authored by agent X" — read first).

  $ printf '(defterm ((binding summarizer () (lam ((pvar u)) (app (var net.get) (var u))))))\n' > authored.jqd
  $ jacquard check authored.jqd --print-sigs --origin agent:jacquard-demo-5
  summarizer : (text) ->{net} text [agent:jacquard-demo-5]

TL.3: malformed --fork specs refuse instead of silently running the baseline.

  $ jacquard replay trace.jqd prog.jqd --fork 'garbage'
  error[E0104]: invalid --fork "garbage" (expected N=FORM with a parseable form)
  [1]
