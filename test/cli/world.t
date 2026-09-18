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
  error[E0814]: The program requires an effect that was not granted
    Cause: This program requires fs [world/medium] — read or mutate the filesystem under the granted root handler, which is not granted (performed via `write`).
    Next step: grant it with --allow fs, or handle the effect in the program
  [3]
  $ cat > clocky.jqd <<'JACQUARD'
  > (let nonrec (pwild) (app (var sleep) (lit 0)) (app (var lt) (lit 0) (app (var now))))
  > JACQUARD
  $ jacquard run clocky.jqd
  error[E0814]: The program requires an effect that was not granted
    Cause: This program requires clock [world/low] — observe wall-clock milliseconds or wait, which is not granted (performed via `sleep`).
    Next step: grant it with --allow clock, or handle the effect in the program
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

End-of-input-aware input (APP.7): `next-line` is a separately declared
`ConsoleInput` operation covered by the same `--allow console` grant. It resumes
with `some(line)`, or `none` once standard input has ended, so a loop can skip
blank lines and still stop at the end. The end is sticky, a final line without a
newline is still delivered, and `read-line` keeps reading end of input as "".

  $ cat > entries.jac <<'JACQUARD'
  > loop(count) = match next-line() {
  >   | None -> { println($"end of input after {text.from-int(count)} entries"); count }
  >   | Some(line) -> match text.trim(line) {
  >     | "" -> loop(count)
  >     | "quit" -> { println("bye"); count }
  >     | entry -> { println($"entry: {entry}"); loop(add(count, 1)) }
  >   }
  > }
  > (loop(0), next-line(), next-line(), read-line())
  > JACQUARD
  $ jacquard run entries.jac --allow console < /dev/null
  end of input after 0 entries
  (0, none, none, "")
  $ printf '\n' | jacquard run entries.jac --allow console
  end of input after 0 entries
  (0, none, none, "")
  $ printf 'a\n\n   \nb' | jacquard run entries.jac --allow console
  entry: a
  entry: b
  end of input after 2 entries
  (2, none, none, "")
  $ printf 'a\nquit\nrest\n' | jacquard run entries.jac --allow console
  entry: a
  bye
  (1, some("rest"), none, "")

The legacy operation is unchanged: an empty line and end of input both read as
"", and its identity and Console's are the released ones.

  $ cat > legacy.jac <<'JACQUARD'
  > (read-line(), read-line(), read-line())
  > JACQUARD
  $ printf 'x\n\n' | jacquard run legacy.jac --allow console
  ("x", "", "")
  $ jacquard hash ../../prelude/03-effects.jqd | grep -E ':(console|print|read-line) '
  5:console 73e8a208eb7fadc43e3bd7aef1474884cf99ce86f8108ddf0e3baff0a74b3fc9
  5:print 28570e6bcdeb8646a90b31971204be7007f658bee65154b96e587c47a6585d5e
  5:read-line cb5c1dabdfcf64756fdda61747f5e4c067e7f50923648b4e820b09048f8a952d

Without the grant the manifest check refuses both effects and names the one
grant that covers them; a handler written in the public syntax discharges
ConsoleInput with no grant at all, and `console.scripted-input` is the library's
scripted boundary (one shared line list, as real standard input is):

  $ jacquard run entries.jac < /dev/null 2>&1 | grep -E 'Cause|Next step'
    Cause: This program requires console [world/low] — talk to the process terminal, which is not granted (performed via `loop`).
    Next step: grant it with --allow console, or handle the effect in the program
    Cause: This program requires console-input [world/low] — read process terminal input with an explicit end-of-input result, which is not granted (performed via `loop`).
    Next step: grant it with --allow console, or handle the effect in the program
  $ cat > handled.jac <<'JACQUARD'
  > echo-lines() = match next-line() {
  >   | None -> println("<end>")
  >   | Some(line) -> { println($"[{line}]"); echo-lines() }
  > }
  > capture(thunk, inputs) =
  >   state.run(
  >     fn () ->
  >       handle thunk() {
  >         | return _ -> ()
  >         | print(message) resume k -> {
  >           let (remaining, output) = get()
  >           put((remaining, Cons(message, output)))
  >           k(())
  >         }
  >         | next-line() resume k -> {
  >           let (remaining, output) = get()
  >           match remaining {
  >             | Cons(line, more) -> { put((more, output)); k(Some(line)) }
  >             | Nil -> k(None)
  >           }
  >         }
  >       },
  >     (inputs, Nil),
  >   )
  > (capture(echo-lines, ["a", "", "b"]), console.scripted-input(fn () -> (next-line(), read-line(), next-line(), next-line(), read-line()), ["a", ""]))
  > JACQUARD
  $ jacquard run handled.jac
  (((), (nil, cons("<end>\n", cons("[b]\n", cons("[]\n", cons("[a]\n", nil)))))), (some("a"), "", none, none, ""))

Resuming a `next-line` continuation twice is refused like any other `once`
operation:

  $ cat > twice.jac <<'JACQUARD'
  > handle next-line() {
  >   | return line -> [line]
  >   | next-line() resume k -> list.append(k(None), k(Some("again")))
  > }
  > JACQUARD
  $ jacquard run twice.jac 2>&1 | head -1
  twice.jac:3:50-66: error[E0816]: A once resumption may be consumed twice on one execution path.

The infer effect (SL.10): stub completions behind the grant; ungranted refuses:

  $ cat > agent.jqd <<'JACQUARD'
  > (app (var complete) (app (var mk-prompt) (lit "write a haiku") (var none)))
  > JACQUARD
  $ jacquard run agent.jqd
  error[E0814]: The program requires an effect that was not granted
    Cause: This program requires infer [model/medium] — request a model completion selected by the handler, which is not granted (performed via `complete`).
    Next step: grant it with --allow infer, or handle the effect in the program
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
