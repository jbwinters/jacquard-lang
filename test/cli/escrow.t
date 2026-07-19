The executable escrow (release 0.1's narrative demo): a generated workflow's
authority, behavior, and identity are machine-checked before anything runs.
Every beat uses shipped machinery only. See demos/worlds/escrow/README.md.

  $ export JACQUARD_PRELUDE=$PWD/../../prelude
  $ cp -R -L ../../demos/worlds/escrow/* .
  $ printf 'cfg' > release-config.txt
  $ cat workflow.jqd main.jqd > approved-run.jqd

The row is the authority manifest: fs covers read/write, net covers fetch, and
console covers println. Eval is absent.

  $ jacquard check workflow.jqd --print-sigs
  escrow.workflow : () ->{Console, Fs, Net} Int
  $ jacquard check approved-run.jqd --print-sigs
  escrow.workflow : () ->{Console, Fs, Net} Int
  _ : Int
  $ jacquard run approved-run.jqd
  error[E0814]: The program requires an effect that was not granted
    Cause: This program requires console [world/low] — talk to the process terminal, which is not granted (performed via `escrow.workflow`).
    Next step: grant it with --allow console, or handle the effect in the program
  error[E0814]: The program requires an effect that was not granted
    Cause: This program requires fs [world/medium] — read or mutate the filesystem under the granted root handler, which is not granted (performed via `escrow.workflow`).
    Next step: grant it with --allow fs, or handle the effect in the program
  error[E0814]: The program requires an effect that was not granted
    Cause: This program requires net [world/high] — reach a network endpoint through the granted handler, which is not granted (performed via `escrow.workflow`).
    Next step: grant it with --allow net, or handle the effect in the program
  [3]

Dry-run forwards reads but audits writes/fetches; no receipt file is created.

  $ jacquard run approved-run.jqd --dry-run
  published: <dry-run response>
  200
  dry-run dispositions: console=forwarded clock=forwarded fs.read=forwarded fs.write=audited net.fetch=audited+simulated infer.complete=audited+simulated dist=simulated(seed 0) eval=refused
  dry-run: this run WOULD have:
    fetched http://registry/publish
    written receipt.txt (18 bytes)
  $ test ! -e receipt.txt && echo no-receipt-written
  no-receipt-written

The granted run performs the write against the stub net handler.

  $ jacquard run approved-run.jqd --allow fs --allow net --allow console
  published: <stub response for http://registry/publish>
  200
  $ cat receipt.txt
  <stub response for http://registry/publish>

Warp tests: hermetic tests run without grants, exhaustive mode proves the small
property, and the world lane only runs with world grants.

  $ jacquard test tests.jqd --seed 7 --cache-dir escrow-cache
  PASS fault-space-exhaustive/fault.all explores every single and double fault (1 check)
  PASS receipt-well-formed/receipt body round-trips the scripted world (1 check)
  PASS status-classifier-total/every status classifies (prop: 100 cases, seed 7)
  REFUSED world-smoke: requires --allow console,fs,clock,net
  3 passed, 0 failed, 0 skipped, 1 refused
  cache: 0 hit, 3 ran
  $ jacquard test tests.jqd --seed 7 --cache-dir escrow-cache --exhaustive
  PASS fault-space-exhaustive/fault.all explores every single and double fault (1 check) [cached]
  PASS receipt-well-formed/receipt body round-trips the scripted world (1 check) [cached]
  PASS status-classifier-total/every status classifies (verified exhaustively (400 cases))
  REFUSED world-smoke: requires --allow console,fs,clock,net
  3 passed, 0 failed, 0 skipped, 1 refused
  cache: 2 hit, 1 ran
  $ jacquard test tests.jqd --seed 7 --cache-dir escrow-cache --allow fs --allow clock --allow console --allow net
  PASS fault-space-exhaustive/fault.all explores every single and double fault (1 check) [cached]
  PASS receipt-well-formed/receipt body round-trips the scripted world (1 check) [cached]
  PASS status-classifier-total/every status classifies (prop: 100 cases, seed 7) [cached]
  PASS world-smoke/workflow runs against the real grants (1 check)
  4 passed, 0 failed, 0 skipped, 0 refused
  cache: 3 hit, 1 ran

Record/replay captures the scripted fetch; strict replay can render drift.

  $ cat > mklog.jqd <<'JACQUARD'
  > (app (var throw.catch)
  >   (lam ()
  >     (match
  >       (app (var net.scripted)
  >         (lam () (app (var net.record)
  >           (lam ()
  >             (match (app (var fetch) (app (var mk-request) (lit "http://registry/publish") (lit "cfg")))
  >               (clause (pcon mk-response (pwild) (pvar receipt)) (var receipt))))))
  >         (app (var cons) (app (var mk-response) (lit 200) (lit "R-77")) (var nil)))
  >       (clause (ptuple (pvar result) (pvar log)) (var log))))
  >   (lam ((pwild)) (quote (log))))
  > JACQUARD
  $ jacquard run mklog.jqd | sed -e 's/^(quote //' -e 's/)$//' > trace.jqd
  $ cat > replay-prog.jqd <<'JACQUARD'
  > (match (app (var fetch) (app (var mk-request) (lit "http://registry/publish") (lit "cfg")))
  >   (clause (pcon mk-response (pwild) (pvar receipt)) (var receipt)))
  > JACQUARD
  $ jacquard replay trace.jqd replay-prog.jqd
  "R-77"
  $ sed 's,http://registry/publish,http://evil/publish,' replay-prog.jqd > replay-drift.jqd
  $ jacquard replay trace.jqd replay-drift.jqd --compare
  "R-77"
  divergence report (original log vs fork):
    at op1/request[0]/lit[0]: - "http://registry/publish" + "http://evil/publish"

Comments and provenance sidecars do not change identity.

  $ cp workflow.jqd workflow-comment.jqd
  $ chmod u+w workflow-comment.jqd
  $ printf '\n; provenance note: reviewer saw this exact generated workflow\n' >> workflow-comment.jqd
  $ jacquard hash workflow.jqd > workflow.hash
  $ jacquard hash workflow-comment.jqd > workflow-comment.hash
  $ cmp workflow.hash workflow-comment.hash
  $ mkdir approved commented
  $ for f in "$JACQUARD_PRELUDE"/*.jqd; do jacquard store add approved "$f" >/dev/null; jacquard store add commented "$f" >/dev/null; done
  $ jacquard store add approved workflow.jqd
  ok
  $ jacquard store add commented workflow-comment.jqd --origin human:reviewer
  ok
  $ jacquard diff approved commented
  no semantic changes

A malicious variant adds eval. The signature exposes it, the escrow grant set
refuses it, and semantic diff localizes the escalation.

  $ cat workflow-escalated.jqd main.jqd > escalated-run.jqd
  $ jacquard check workflow-escalated.jqd --print-sigs
  escrow.workflow : () ->{Console, Fs, Eval, Net} Int
  $ jacquard check escalated-run.jqd --manifest fs,net,console
  error[E0814]: The program requires an effect that was not granted
    Cause: This program requires eval [meta/high] — run code constructed or loaded at runtime, which is not granted (performed via `eval-code`).
    Next step: grant it with --allow eval, or handle the effect in the program
  [1]
  $ mkdir escalated
  $ for f in "$JACQUARD_PRELUDE"/*.jqd; do jacquard store add escalated "$f" >/dev/null; done
  $ jacquard store add escalated workflow-escalated.jqd
  ok
  $ jacquard diff approved escalated | grep -E 'changed|receipt.txt'
  changed  escrow.workflow
      - (app (ref #543ff548b2d3f4fd32f78e8634a32d4d6217ad569816b8da33cac31686d9a43a op) (lit "receipt.txt") (var receipt))
      + (app (ref #543ff548b2d3f4fd32f78e8634a32d4d6217ad569816b8da33cac31686d9a43a op) (lit "receipt.txt") (var receipt))

Approval is by exact member hash; a semantic edit invalidates it.

  $ grep member-hash APPROVAL
  member-hash: 885689aad7921df4a5f3fb2eeda074792e09d1b20a189605987ab0e8898409cd
  $ awk '/0:escrow.workflow/ {print "workflow-hash:", $2}' workflow.hash
  workflow-hash: 885689aad7921df4a5f3fb2eeda074792e09d1b20a189605987ab0e8898409cd
  $ sed 's/(lit "receipt.txt")/(lit "receipt-v2.txt")/' workflow.jqd > workflow-changed.jqd
  $ jacquard hash workflow-changed.jqd | awk '/0:escrow.workflow/ {print "changed-hash:", $2}'
  changed-hash: 9a3a94589e7f1e658f02e2aac2aceca65c66f756c7358d9898abd537b0075dfe
