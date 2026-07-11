# Jacquard tutorial: ten runnable examples

Every example here is a file checked into the repository and exercised by CI (the
conformance corpus, the signature corpus, or the demo transcripts). Commands assume the
repo root; `jacquard` is `dune exec jacquard --`.

## 1. A literal

`corpus/valid/lit-int.jqd` — the whole language is `(head arg ...)` triples:

```lisp
(lit 1)
```

Run it: `jacquard run corpus/valid/lit-int.jqd` prints `1`.

## 2. Application

`corpus/valid/app-add.jqd`:

```lisp
(app (var add) (lit 1) (lit 2))
```

Calls are uncurried (decision D5): `add` takes exactly two arguments. `jacquard run` prints `3`.

## 3. Functions

`corpus/sigs/01-identity.jqd`:

```lisp
(lam ((pvar x)) (var x))
```

`jacquard check corpus/sigs/01-identity.jqd --print-sigs` prints the elaborated signature —
`forall a. (a) ->{} a`. The empty row `{}` is the whole story: this function can do
nothing but compute.

## 4. Recursion via defterm

`corpus/valid/fact.jqd` — factorial as a content-addressed declaration:

```lisp
(defterm ((binding fact ()
  (lam ((pvar n))
    (match (var n)
      (clause (plit 0) (lit 1))
      (clause (pvar m)
        (app (var mul) (var m)
          (app (var fact) (app (var sub) (var m) (lit 1))))))))))
```

Self-reference resolves to a group-local marker, so the definition's hash is stable under
renaming. `demos/m1-fact.jqd` adds `(app (var fact) (lit 5))`; `jacquard run` prints `120`.

## 5. Pattern matching, no if

`corpus/valid/match-bool.jqd` — `bool` is a library type and `if` is just sugar the kernel
does not have:

```lisp
(lam ((pvar b))
  (match (var b)
    (clause (pcon true) (lit 0))
    (clause (pcon false) (lit 1))))
```

Delete a clause and `jacquard check` rejects the match with the missing witness (E0813).

## 6. Effects and handlers

`corpus/sigs/09-hostile.jqd` — aborting is an effect, handled to `option`:

```lisp
(defterm ((binding safe-div ()
  (lam ((pvar n) (pvar d))
    (match (app (var eq) (var d) (lit 0))
      (clause (pcon true)  (app (var abort)))
      (clause (pcon false) (app (var div) (var n) (var d))))))))
```

`jacquard check --print-sigs` shows `safe-div : (Int, Int) ->{Abort} Int` — the signature
announces the possible abort — and `to-option : forall a | e. (() ->{Abort | e} a) ->{| e} Option a`
shows row polymorphism removing it.

## 7. Multi-shot handlers

`demos/m1-choose.jqd` — one `choose` op, resumed twice by its handler, collecting both
branches:

```lisp
(handle
  (match (app (var choose))
    (clause (pcon true) (lit 1))
    (clause (pcon false) (lit 2)))
  (ret (pvar x) (app (var cons) (var x) (var nil)))
  (opclause choose () k
    (app (var append) (app (var k) (var true)) (app (var k) (var false)))))
```

`jacquard run demos/m1-choose.jqd` prints `cons(1, cons(2, nil))`.

## 8. Capability grants

`demos/m1-gated.jqd` — `eval` is a library effect; nothing runs code without the grant:

```
$ jacquard run demos/m1-gated.jqd            # E0814 refusal, exit 3
$ jacquard run demos/m1-gated.jqd --allow eval
42
```

The same gate covers `console` and `net`. A program's inferred row is its authority
manifest; `jacquard check FILE --manifest net,console` audits it without running.

## 9. Probabilistic programming

`demos/m3-two-coins.jqd` — sample/observe are ordinary ops of the `dist` effect; inference
algorithms are handlers:

```
$ jacquard infer enumerate demos/m3-two-coins.jqd
0.666667  true
0.333333  false
$ jacquard infer lw demos/m3-two-coins.jqd --seed 42 --samples 100000
0.667898  true
0.332102  false
```

The model file is identical under both algorithms — only the handler changes.

## 10. Content addressing

A store is a content-addressed map from hashes to declarations; names are metadata. Store a
self-contained declaration, rename it (object files untouched), and diff semantically:

```
$ printf '(deftype color () (con red) (con green))\n' > color.jqd
$ jacquard store add lib-v1 color.jqd
ok
$ jacquard store add lib-v2 color.jqd
ok
$ jacquard store rename lib-v2 color colour
$ jacquard diff lib-v1 lib-v2
renamed  color -> colour
```

`jacquard hash FILE` prints the canonical HASH_V0 hashes; formatting and comments never change
them (the metadata law). These commands are pinned in `test/cli/tutorial.t`.

## 11. Interposition: attenuating authority with a handler

Capability security in Jacquard is not a special mechanism — it is the effect system used
deliberately. `--allow fs` grants the whole filesystem (the grant is the sandbox boundary
in this draft), but any code can narrow what it passes on by wrapping a handler.
`fs.read-only` from the prelude forwards `read` and `list-dir` to the real world and turns
`write` into a thrown error:

```lisp
(app (var fs.read-only)
  (lam ()
    (let nonrec (pvar c) (app (var read) (lit "note.txt"))
      (let nonrec (pwild) (app (var write) (lit "note.txt") (lit "clobbered"))
        (var c)))))
```

Under `jacquard run --allow fs`, the read succeeds and the write becomes
`"fs.read-only refused write: note.txt"` (catch it with `throw.catch`). The handler
re-performs the reads, so `fs` honestly stays in the row: attenuated code still needs the
grant, it just cannot write through this handler. Pinned in `test/cli/world.t`.

One asymmetry, documented until the owner decision lands: `eval`'d code runs at root
authority and bypasses interposed handlers, so `fs.read-only` does **not** confine
`eval-code` payloads.
