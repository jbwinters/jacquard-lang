Ring 3 world effects (stdlib SL.8): real root handlers behind grants. The grant
is the sandbox boundary in this draft: --allow fs means the whole filesystem.

  $ export JACQUARD_PRELUDE=../../prelude

fs write-then-read round trip in the cram's scratch directory:

  $ cat > roundtrip.jqd <<'JACQUARD'
  > (let nonrec (pwild) (app (var write) (lit "note.txt") (lit "hello world"))
  >   (app (var read) (lit "note.txt")))
  > JACQUARD
  $ jacquard run roundtrip.jqd --allow fs
  "hello world"

Ungranted world effects refuse by name, before any IO happens:

  $ jacquard run roundtrip.jqd
  error[E0814]: this program requires the `fs` effect, which is not granted (performed via `write`)
    hint: grant it with --allow fs, or handle the effect in the program
  [3]
  $ cat > clocky.jqd <<'JACQUARD'
  > (let nonrec (pwild) (app (var sleep) (lit 0)) (app (var lt) (lit 0) (app (var now))))
  > JACQUARD
  $ jacquard run clocky.jqd
  error[E0814]: this program requires the `clock` effect, which is not granted (performed via `sleep`)
    hint: grant it with --allow clock, or handle the effect in the program
  [3]
  $ jacquard run clocky.jqd --allow clock
  true

THE interposition tutorial (example 11): under fs.read-only, reads pass and a
write becomes a thrown error — attenuation is just a wrapping handler. The
program still needs --allow fs (the handler forwards reads to the real world).

  $ cat > attenuated.jqd <<'JACQUARD'
  > (app (var throw.catch)
  >   (lam ()
  >     (app (var fs.read-only)
  >       (lam ()
  >         (let nonrec (pvar content) (app (var read) (lit "note.txt"))
  >           (let nonrec (pwild) (app (var write) (lit "note.txt") (lit "clobbered"))
  >             (var content))))))
  >   (lam ((pvar e)) (var e)))
  > JACQUARD
  $ jacquard run attenuated.jqd --allow fs
  "fs.read-only refused write: note.txt"
  $ jacquard run roundtrip.jqd --allow fs
  "hello world"

console gains read-line; console.ask pipes cleanly:

  $ cat > greet.jqd <<'JACQUARD'
  > (app (var println) (app (var text.concat) (lit "hello, ") (app (var console.ask) (lit "name?"))))
  > JACQUARD
  $ echo josh | jacquard run greet.jqd --allow console
  name?
  hello, josh
  ()

The infer effect (SL.10): stub completions behind the grant; ungranted refuses:

  $ cat > agent.jqd <<'JACQUARD'
  > (app (var complete) (app (var mk-prompt) (lit "write a haiku") (var none)))
  > JACQUARD
  $ jacquard run agent.jqd
  error[E0814]: this program requires the `infer` effect, which is not granted (performed via `complete`)
    hint: grant it with --allow infer, or handle the effect in the program
  [3]
  $ jacquard run agent.jqd --allow infer
  "<stub completion for: write a haiku>"

infer.cached: the first run misses and records; the second identical run is a
full hit, and the cache entry is a printed form jacquard fmt can read:

  $ jacquard run agent.jqd --allow infer --infer-cache icache 2>cache1.log
  "<stub completion for: write a haiku>"
  $ grep -c miss cache1.log
  1
  $ jacquard run agent.jqd --allow infer --infer-cache icache 2>cache2.log
  "<stub completion for: write a haiku>"
  $ grep -c hit cache2.log
  1
  $ jacquard fmt icache/*.jqd | head -2
  (infer-cache-entry
    (prompt "write a haiku")

infer.scripted: canned completions in order; exhaustion is a clean failure.
Swapping models is swapping a handler — same agent, different transcript:

  $ cat > swap.jqd <<'JACQUARD'
  > (defterm ((binding agent ()
  >   (lam () (app (var complete) (app (var mk-prompt) (lit "q") (var none)))))))
  > (app (var throw.catch)
  >   (lam ()
  >     (app (var infer.scripted) (lam () (app (var agent)))
  >       (app (var cons) (lit "model-a says yes") (var nil))))
  >   (lam ((pvar e)) (var e)))
  > (app (var throw.catch)
  >   (lam ()
  >     (app (var infer.scripted) (lam () (app (var agent)))
  >       (app (var cons) (lit "model-b says no") (var nil))))
  >   (lam ((pvar e)) (var e)))
  > (app (var throw.catch)
  >   (lam () (app (var infer.scripted) (lam () (app (var agent))) (var nil)))
  >   (lam ((pvar e)) (var e)))
  > JACQUARD
  $ jacquard run swap.jqd
  "model-a says yes"
  "model-b says no"
  "infer.scripted: out of canned completions"
