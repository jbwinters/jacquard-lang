Ring 3 world effects (stdlib SL.8): real root handlers behind grants. The grant
is the sandbox boundary in this draft: --allow fs means the whole filesystem.

  $ export WEFT_PRELUDE=../../prelude

fs write-then-read round trip in the cram's scratch directory:

  $ cat > roundtrip.wft <<'WEFT'
  > (let nonrec (pwild) (app (var write) (lit "note.txt") (lit "hello world"))
  >   (app (var read) (lit "note.txt")))
  > WEFT
  $ weft run roundtrip.wft --allow fs
  "hello world"

Ungranted world effects refuse by name, before any IO happens:

  $ weft run roundtrip.wft
  error[E0814]: this program requires the `fs` effect, which is not granted (performed via `write`)
    hint: grant it with --allow fs, or handle the effect in the program
  [3]
  $ cat > clocky.wft <<'WEFT'
  > (let nonrec (pwild) (app (var sleep) (lit 0)) (app (var lt) (lit 0) (app (var now))))
  > WEFT
  $ weft run clocky.wft
  error[E0814]: this program requires the `clock` effect, which is not granted (performed via `sleep`)
    hint: grant it with --allow clock, or handle the effect in the program
  [3]
  $ weft run clocky.wft --allow clock
  true

THE interposition tutorial (example 11): under fs.read-only, reads pass and a
write becomes a thrown error — attenuation is just a wrapping handler. The
program still needs --allow fs (the handler forwards reads to the real world).

  $ cat > attenuated.wft <<'WEFT'
  > (app (var throw.catch)
  >   (lam ()
  >     (app (var fs.read-only)
  >       (lam ()
  >         (let nonrec (pvar content) (app (var read) (lit "note.txt"))
  >           (let nonrec (pwild) (app (var write) (lit "note.txt") (lit "clobbered"))
  >             (var content))))))
  >   (lam ((pvar e)) (var e)))
  > WEFT
  $ weft run attenuated.wft --allow fs
  "fs.read-only refused write: note.txt"
  $ weft run roundtrip.wft --allow fs
  "hello world"

console gains read-line; console.ask pipes cleanly:

  $ cat > greet.wft <<'WEFT'
  > (app (var println) (app (var text.concat) (lit "hello, ") (app (var console.ask) (lit "name?"))))
  > WEFT
  $ echo josh | weft run greet.wft --allow console
  name?
  hello, josh
  ()

The infer effect (SL.10): stub completions behind the grant; ungranted refuses:

  $ cat > agent.wft <<'WEFT'
  > (app (var complete) (app (var mk-prompt) (lit "write a haiku") (var none)))
  > WEFT
  $ weft run agent.wft
  error[E0814]: this program requires the `infer` effect, which is not granted (performed via `complete`)
    hint: grant it with --allow infer, or handle the effect in the program
  [3]
  $ weft run agent.wft --allow infer
  "<stub completion for: write a haiku>"

infer.cached: the first run misses and records; the second identical run is a
full hit, and the cache entry is a printed form weft fmt can read:

  $ weft run agent.wft --allow infer --infer-cache icache 2>cache1.log
  "<stub completion for: write a haiku>"
  $ grep -c miss cache1.log
  1
  $ weft run agent.wft --allow infer --infer-cache icache 2>cache2.log
  "<stub completion for: write a haiku>"
  $ grep -c hit cache2.log
  1
  $ weft fmt icache/*.wft | head -2
  (infer-cache-entry
    (prompt "write a haiku")

infer.scripted: canned completions in order; exhaustion is a clean failure.
Swapping models is swapping a handler — same agent, different transcript:

  $ cat > swap.wft <<'WEFT'
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
  > WEFT
  $ weft run swap.wft
  "model-a says yes"
  "model-b says no"
  "infer.scripted: out of canned completions"
