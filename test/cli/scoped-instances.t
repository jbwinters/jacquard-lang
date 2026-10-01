Scoped effect instances, slice 2 (docs/designs/scoped-effect-instances.md §10
A2): `state.scoped` runs on the interpreter, where each scope serves only its own
capability's operations. The native backend refuses it until slice 3 gives the
instance-token builtins native intrinsics (E1101).

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
  $ jacquard build two-stores.jqd -o two-stores
  error[E1101]: Program is outside the native v1 compilation subset
    Cause: Not yet compilable in native v1: be8cdc305501d4d20b599fe43bbb1520bec8b22685262b185f3453cf0556d7d9 reachable member is not a term binding
    Next step: Run the program with the interpreter or rewrite the unsupported construct.
  error[E1101]: Program is outside the native v1 compilation subset
    Cause: Not yet compilable in native v1: e148cc2fcadc1f54ce9d168c763074ea45a52c43a1fbc86dfd223ca0e8ca5572 reachable member is not a term binding
    Next step: Run the program with the interpreter or rewrite the unsupported construct.
  [1]
