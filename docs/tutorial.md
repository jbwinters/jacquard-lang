# Weft tutorial: ten runnable examples

Every example here is a file checked into the repository and exercised by CI (the
conformance corpus, the signature corpus, or the demo transcripts). Commands assume the
repo root; `weft` is `dune exec weft --`.

## 1. A literal

`corpus/valid/lit-int.wft` — the whole language is `(head arg ...)` triples:

```lisp
(lit 1)
```

Run it: `weft run corpus/valid/lit-int.wft` prints `1`.

## 2. Application

`corpus/valid/app-add.wft`:

```lisp
(app (var add) (lit 1) (lit 2))
```

Calls are uncurried (decision D5): `add` takes exactly two arguments. `weft run` prints `3`.

## 3. Functions

`corpus/sigs/01-identity.wft`:

```lisp
(lam ((pvar x)) (var x))
```

`weft check corpus/sigs/01-identity.wft --print-sigs` prints the elaborated signature —
`forall a. (a) ->{} a`. The empty row `{}` is the whole story: this function can do
nothing but compute.

## 4. Recursion via defterm

`corpus/valid/fact.wft` — factorial as a content-addressed declaration:

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
renaming. `demos/m1-fact.wft` adds `(app (var fact) (lit 5))`; `weft run` prints `120`.

## 5. Pattern matching, no if

`corpus/valid/match-bool.wft` — `bool` is a library type and `if` is just sugar the kernel
does not have:

```lisp
(lam ((pvar b))
  (match (var b)
    (clause (pcon true) (lit 0))
    (clause (pcon false) (lit 1))))
```

Delete a clause and `weft check` rejects the match with the missing witness (E0813).

## 6. Effects and handlers

`corpus/sigs/09-hostile.wft` — failure is an effect, handled to `option`:

```lisp
(defterm ((binding safe-div ()
  (lam ((pvar n) (pvar d))
    (match (app (var eq) (var d) (lit 0))
      (clause (pcon true)  (app (var abort)))
      (clause (pcon false) (app (var div) (var n) (var d))))))))
```

`weft check --print-sigs` shows `safe-div : (int, int) ->{failure} int` — the signature
announces the failure — and `to-option : forall a e. (() ->{failure | e} a) ->{e} option a`
shows row polymorphism removing it.

## 7. Multi-shot handlers

`demos/m1-choose.wft` — one `choose` op, resumed twice by its handler, collecting both
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

`weft run demos/m1-choose.wft` prints `cons(1, cons(2, nil))`.

## 8. Capability grants

`demos/m1-gated.wft` — `eval` is a library effect; nothing runs code without the grant:

```
$ weft run demos/m1-gated.wft            # E0814 refusal, exit 3
$ weft run demos/m1-gated.wft --allow eval
42
```

The same gate covers `console` and `net`. A program's inferred row is its authority
manifest; `weft check FILE --manifest net,console` audits it without running.

## 9. Probabilistic programming

`demos/m3-two-coins.wft` — sample/observe are ordinary ops of the `dist` effect; inference
algorithms are handlers:

```
$ weft infer enumerate demos/m3-two-coins.wft
0.666667  true
0.333333  false
$ weft infer lw demos/m3-two-coins.wft --seed 42 --samples 100000
0.667898  true
0.332102  false
```

The model file is identical under both algorithms — only the handler changes.

## 10. Content addressing

A store is a content-addressed map from hashes to declarations; names are metadata. Store a
self-contained declaration, rename it (object files untouched), and diff semantically:

```
$ printf '(deftype color () (con red) (con green))\n' > color.wft
$ weft store add lib-v1 color.wft
ok
$ weft store add lib-v2 color.wft
ok
$ weft store rename lib-v2 color colour
$ weft diff lib-v1 lib-v2
renamed  color -> colour
```

`weft hash FILE` prints the canonical HASH_V0 hashes; formatting and comments never change
them (the metadata law). These commands are pinned in `test/cli/tutorial.t`.
