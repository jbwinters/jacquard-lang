Scoped effect instances, slices 2 and 2b (docs/designs/scoped-effect-instances.md §10, §11
A2, A3): `state.scoped` runs on the interpreter, where each scope serves only its own
capability's operations. Native builds run them identically (slice 3, §12 A4).

  $ export JACQUARD_PRELUDE=../../prelude
  $ export JACQUARD_RUNTIME=../../runtime
  $ export CC=clang
  $ cat > two-stores.jqd <<'EOF_JQD'
  > (app (var state.scoped) (lit 10)
  >   (lam ((pvar outer))
  >     (app (var state.scoped) (lit 20)
  >       (lam ((pvar inner))
  >         (let nonrec (pwild) (app (var state.put-at) (var outer) (lit 11))
  >           (tuple (app (var state.get-at) (var outer)) (app (var state.get-at) (var inner))))))))
  > EOF_JQD
  $ jacquard run two-stores.jqd
  (11, 20)
  $ jacquard build two-stores.jqd -o two-stores > /dev/null
  $ jacquard run two-stores.jqd > two-stores-i.out 2>&1
  $ ./two-stores > two-stores-n.out 2>&1
  $ diff two-stores-i.out two-stores-n.out && echo identical
  identical

Throw and Emit scopes (§11 A3) run on the interpreter too: a throw on an outer
capability forwards through an inner scope, and emissions keep their order.

  $ cat > throw-emit.jqd <<'EOF_JQD'
  > (tuple
  >   (app (var throw.scoped) (lam ((pvar outer))
  >     (app (var throw.scoped) (lam ((pvar inner))
  >       (app (var throw.throw-at) (var outer) (lit "outer"))))))
  >   (app (var emit.scoped) (lam ((pvar e))
  >     (let nonrec (pwild) (app (var emit.emit-at) (var e) (lit 1))
  >       (app (var emit.emit-at) (var e) (lit 2))))))
  > EOF_JQD
  $ jacquard run throw-emit.jqd
  (err("outer"), ((), cons(1, cons(2, nil))))
  $ jacquard build throw-emit.jqd -o throw-emit > /dev/null
  $ jacquard run throw-emit.jqd > throw-emit-i.out 2>&1
  $ ./throw-emit > throw-emit-n.out 2>&1
  $ diff throw-emit-i.out throw-emit-n.out && echo identical
  identical

A builtin marker naming a hidden token builtin is a builtin only at its frozen
identity (A4.2). A copy made with a raw quote is a code value in the interpreter
and is refused by the native build. An explicit hash reference to the hidden
builtin is refused identically by both engines.

A copy identical to the prelude's marker has the prelude's hidden identity, so
the copy below sits in a different definition group. Applying it is a type
error on both engines (code is not callable). A reference reaches native
lowering, where it is refused.

  $ cat > forged.jqd <<'EOF_JQD'
  > (defterm ((binding forged-fresh () (quote (builtin-marker instance.fresh-v0)))
  >           (binding forged-other () (lit 0))))
  > (var forged-fresh)
  > EOF_JQD
  $ jacquard run forged.jqd
  (quote (builtin-marker instance.fresh-v0))
  $ jacquard build forged.jqd -o forged
  error[E1101]: Program is outside the native v1 compilation subset
    Cause: Not yet compilable in native v1: top-level expression 0 a builtin marker for the private `instance.fresh-v0` outside its frozen identity
    Next step: Run the program with the interpreter or rewrite the unsupported construct.
  [1]
  $ cat > hidden-ref.jqd <<'EOF_JQD'
  > (app (ref #e148cc2fcadc1f54ce9d168c763074ea45a52c43a1fbc86dfd223ca0e8ca5572 term))
  > EOF_JQD
  $ jacquard run hidden-ref.jqd > hidden-i.out 2>&1; echo "run $?"
  run 1
  $ jacquard build hidden-ref.jqd -o hidden > hidden-n.out 2>&1; echo "build $?"
  build 1
  $ diff hidden-i.out hidden-n.out && head -1 hidden-i.out
  hidden-ref.jqd:1:6-82: error[E0805]: A referenced declaration has the wrong kind or is unavailable

A group-local reference to a forged marker is refused the same way, and a group
that holds an unused forged marker still compiles.

  $ cat > forged-group.jqd <<'EOF_JQD'
  > (defterm ((binding forged () (quote (builtin-marker instance.same-v0)))
  >           (binding reveal () (lam () (var forged)))))
  > (app (var reveal))
  > EOF_JQD
  $ jacquard run forged-group.jqd
  (quote (builtin-marker instance.same-v0))
  $ jacquard build forged-group.jqd -o forged-group
  error[E1101]: Program is outside the native v1 compilation subset
    Cause: Not yet compilable in native v1: reveal a builtin marker for the private `instance.same-v0` outside its frozen identity
    Next step: Run the program with the interpreter or rewrite the unsupported construct.
  [1]
  $ cat > forged-unused.jqd <<'EOF_JQD'
  > (defterm ((binding forged () (quote (builtin-marker instance.fresh-v0)))
  >           (binding answer () (lam () (lit 42)))))
  > (app (var answer))
  > EOF_JQD
  $ jacquard build forged-unused.jqd -o forged-unused > /dev/null && ./forged-unused
  42
