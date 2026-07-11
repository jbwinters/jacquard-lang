# Jacquard tutorial: runnable examples

Every Jacquard source fence here is extracted to the named fixture under
`test/docs-doctest/fixtures/`, compared byte-for-byte, and checked or run by
`dune runtest`. Commands assume the repo root; `jacquard` is
`dune exec jacquard --`.

## 1. A literal

`test/docs-doctest/fixtures/tutorial-literal.jac`:

```jacquard doctest=tutorial-literal mode=run fixture=tutorial-literal.jac stdout=tutorial-literal.stdout stderr=empty exit=0
1
```

Run it: `jacquard run test/docs-doctest/fixtures/tutorial-literal.jac` prints `1`.

## 2. Application

`test/docs-doctest/fixtures/tutorial-application.jac`:

```jacquard doctest=tutorial-application mode=run fixture=tutorial-application.jac stdout=tutorial-application.stdout stderr=empty exit=0
add(1, 2)
```

Calls are uncurried (decision D5): `add` takes exactly two arguments. `jacquard run` prints `3`.

## 3. Functions

`test/docs-doctest/fixtures/tutorial-identity.jac`:

```jacquard doctest=tutorial-identity mode=check fixture=tutorial-identity.jac stdout=tutorial-identity.stdout stderr=empty exit=0
fn (x) -> x
```

`jacquard check test/docs-doctest/fixtures/tutorial-identity.jac --print-sigs`
prints the elaborated signature —
`forall a. (a) ->{} a`. The empty row `{}` is the whole story: this function can do
nothing but compute.

## 4. Recursion

`test/docs-doctest/fixtures/tutorial-factorial.jac` — factorial as a
content-addressed declaration followed by a top-level expression:

```jacquard doctest=tutorial-factorial mode=run fixture=tutorial-factorial.jac stdout=tutorial-factorial.stdout stderr=empty exit=0
fact(n) = match n {
  | 0 -> 1
  | m -> mul(m, fact(sub(m, 1)))
}

fact(5)
```

Self-reference resolves to a group-local marker, so the definition's hash is stable under
renaming. `jacquard run test/docs-doctest/fixtures/tutorial-factorial.jac`
prints `120`.

## 5. Pattern matching, no if

`test/docs-doctest/fixtures/tutorial-bool-match.jac` — `Bool` is a library type and `if` is just sugar the kernel
does not have:

```jacquard doctest=tutorial-bool-match mode=check fixture=tutorial-bool-match.jac stdout=tutorial-bool-match.stdout stderr=empty exit=0
fn (b) -> match b {
  | True -> 0
  | False -> 1
}
```

Delete a clause and `jacquard check` rejects the match with the missing witness (E0813).
The negative companion pins that stable diagnostic and its nonzero exit status:

```jacquard doctest=tutorial-nonexhaustive mode=check fixture=tutorial-nonexhaustive.jac stdout=empty stderr=tutorial-nonexhaustive.stderr exit=1
fn (b) -> match b {
  | True -> 0
}
```

## 6. Effects and handlers

`test/docs-doctest/fixtures/tutorial-safe-div.jac` — aborting is an effect:

```jacquard doctest=tutorial-safe-div mode=check fixture=tutorial-safe-div.jac stdout=tutorial-safe-div.stdout stderr=empty exit=0
safe-div(n, d) = if eq(d, 0) then abort() else div(n, d)
```

`jacquard check --print-sigs` shows `safe-div : (Int, Int) ->{Abort} Int` — the signature
announces the possible abort — and `to-option : forall a | e. (() ->{Abort | e} a) ->{| e} Option a`
shows row polymorphism removing it.

## 7. Multi-shot handlers

The README fixture uses one `choose` operation and resumes its continuation for
both branches:

`jacquard run test/docs-doctest/fixtures/readme-multishot.jac` prints `3`.

## 8. Capability grants

`demos/m1-gated.jqd` — `eval` is a library effect; nothing runs code without the grant:

```console
$ jacquard run demos/m1-gated.jqd            # E0814 refusal, exit 3
$ jacquard run demos/m1-gated.jqd --allow eval
42
```

The same gate covers `console` and `net`. A program's inferred row is its authority
manifest; `jacquard check FILE --manifest net,console` audits it without running.

## 9. Probabilistic programming

`demos/m3-two-coins.jqd` — sample/observe are ordinary ops of the `dist` effect; inference
algorithms are handlers:

```console
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

```console
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

```jacquard doctest=tutorial-read-only mode=check fixture=tutorial-read-only.jac stdout=tutorial-read-only.stdout stderr=empty exit=0
read-note() = fs.read-only(fn () -> {
  let contents = read("note.txt")
  write("note.txt", "clobbered")
  contents
})
```

Under `jacquard run --allow fs`, the read succeeds and the write becomes
`"fs.read-only refused write: note.txt"` (catch it with `throw.catch`). The handler
re-performs the reads, so `Fs` visibly stays in
`read-note : () ->{Fs, Throw} Text`; `Throw` records the refused write. Attenuated
code still needs the grant, but it cannot write through this handler. The signature
is pinned by this doctest and the runtime behavior by `test/cli/world.t`.

One asymmetry, documented until the owner decision lands: `eval`'d code runs at root
authority and bypasses interposed handlers, so `fs.read-only` does **not** confine
`eval-code` payloads.
