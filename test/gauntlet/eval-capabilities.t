Capability gauntlet: eval is a separate grant, and eval does not install net.

  $ export JACQUARD_PRELUDE=../../prelude

Eval can create code that performs net, but granting eval alone does not install
the net root handler.

  $ cat > eval-net.jqd <<'EOF_JQD'
  > (app (var eval-code) (quote (app (var net.get) (lit "https://example.com"))))
  > EOF_JQD
  $ jacquard run eval-net.jqd --allow eval
  unhandled effect net: operation `fetch` reached the root without a handler
  [3]
  $ jacquard run eval-net.jqd --allow eval --allow net
  "<stub response for https://example.com>"

Granting net without eval still fails before runtime because the surface program's
manifest requires eval.

  $ jacquard run eval-net.jqd --allow net
  error[E0814]: this program requires eval [meta/high] — run code constructed or loaded at runtime, which is not granted (performed via `eval-code`)
    hint: grant it with --allow eval, or handle the effect in the program
  [3]

Even pure eval is gated; there is no pure-code shortcut around the capability.

  $ cat > pure-eval.jqd <<'EOF_JQD'
  > (app (var eval-code) (quote (lit 1)))
  > EOF_JQD
  $ jacquard run pure-eval.jqd
  error[E0814]: this program requires eval [meta/high] — run code constructed or loaded at runtime, which is not granted (performed via `eval-code`)
    hint: grant it with --allow eval, or handle the effect in the program
  [3]

The surface spelling has the same gate. Quoting ordinary surface syntax does not
resolve or execute the payload early.

  $ cat > pure-eval.jac <<'EOF_JAC'
  > eval-code(quote { add(40, 2) })
  > EOF_JAC
  $ jacquard run pure-eval.jac
  error[E0814]: this program requires eval [meta/high] — run code constructed or loaded at runtime, which is not granted (performed via `eval-code`)
    hint: grant it with --allow eval, or handle the effect in the program
  [3]
  $ jacquard run pure-eval.jac --allow eval
  42

A malicious surface payload cannot hide console authority from the outer Eval
manifest. Granting console without Eval refuses before the payload can print.

  $ cat > hidden-console.jac <<'EOF_JAC'
  > eval-code(quote { print("AUTHORITY LEAK\n") })
  > EOF_JAC
  $ jacquard run hidden-console.jac --allow console
  error[E0814]: this program requires eval [meta/high] — run code constructed or loaded at runtime, which is not granted (performed via `eval-code`)
    hint: grant it with --allow eval, or handle the effect in the program
  [3]

Eval alone installs only Eval. Each hidden world operation still reaches an
unhandled root; no fs, clock, console, or net handler is installed implicitly.

  $ jacquard run hidden-console.jac --allow eval
  unhandled effect console: operation `print` reached the root without a handler
  [3]
  $ cat > hidden-fs.jac <<'EOF_JAC'
  > eval-code(quote { `op:read`("/definitely-not-read-by-eval") })
  > EOF_JAC
  $ jacquard run hidden-fs.jac --allow eval
  unhandled effect fs: operation `read` reached the root without a handler
  [3]
  $ cat > hidden-clock.jac <<'EOF_JAC'
  > eval-code(quote { `op:now`() })
  > EOF_JAC
  $ jacquard run hidden-clock.jac --allow eval
  unhandled effect clock: operation `now` reached the root without a handler
  [3]
  $ cat > hidden-net.jac <<'EOF_JAC'
  > eval-code(quote { net.get("https://example.com") })
  > EOF_JAC
  $ jacquard run hidden-net.jac --allow eval
  unhandled effect net: operation `fetch` reached the root without a handler
  [3]

The operation runs only when both authorities are explicit.

  $ jacquard run hidden-console.jac --allow eval --allow console
  AUTHORITY LEAK
  ()

The runtime splice guard is deterministic even when handler typing erases the
non-Code value. This is a language diagnostic, not an OCaml exception.

  $ cat > non-code-splice.jac <<'EOF_JAC'
  > handle { quote { f(unquote(get())) } } {
  >   | return x -> x
  >   | get() resume k -> k(5)
  > }
  > EOF_JAC
  $ jacquard run non-code-splice.jac
  type error: unquote splice evaluated to 5, not code
  [2]
