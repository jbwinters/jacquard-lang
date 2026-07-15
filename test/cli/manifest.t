The capability manifest (W3.6): a program's inferred row is its authority
manifest; running or checking against a grant set enforces it.

  $ export JACQUARD_PRELUDE=../../prelude

The hostile demo: a generated-looking function that reaches for the network
taints every caller's row.

  $ cat > hostile.jqd <<'EOF_JQD'
  > (defterm ((binding fetch-title ()
  >   (lam ((pvar url)) (app (var net.get) (var url))))))
  > (defterm ((binding summarize ()
  >   (lam ((pvar url)) (app (var fetch-title) (var url))))))
  > (app (var summarize) (lit "http://example.com"))
  > EOF_JQD
  $ jacquard check hostile.jqd --print-sigs
  fetch-title : (Text) ->{Net} Text
  summarize : (Text) ->{Net} Text
  _ : Text

Checking against a grant set that lacks net refuses at the type level, naming
the effect and the call-chain endpoint:

  $ jacquard check hostile.jqd --manifest console
  error[E0814]: this program requires net [world/high] — reach a network endpoint through the granted handler, which is not granted (performed via `net.get`)
    hint: grant it with --allow net, or handle the effect in the program
  [1]

With the grant it passes, and the granted run succeeds against the stub
handler:

  $ jacquard check hostile.jqd --manifest net,console
  ok
  $ jacquard run hostile.jqd --allow net
  "<stub response for http://example.com>"

Running without the net grant is the capability refusal (exit 3), even when
some other runtime handler is granted:

  $ jacquard run hostile.jqd --allow console
  error[E0814]: this program requires net [world/high] — reach a network endpoint through the granted handler, which is not granted (performed via `summarize`)
    hint: grant it with --allow net, or handle the effect in the program
  [3]
  $ jacquard run hostile.jqd
  error[E0814]: this program requires net [world/high] — reach a network endpoint through the granted handler, which is not granted (performed via `summarize`)
    hint: grant it with --allow net, or handle the effect in the program
  [3]

Pure effects are never grantable, so the hint must not suggest a --allow flag
that would only bounce with E0703:

  $ cat > pure.jqd <<'JACQUARD'
  > (app (var option.get!) (var none))
  > JACQUARD
  $ jacquard run pure.jqd
  error[E0814]: this program requires abort [control/none] — stop a computation without an error payload, which is not granted (performed via `option.get!`)
    hint: handle the effect in the program (this effect is pure and cannot be granted)
  [3]
  $ jacquard run pure.jqd --allow abort
  error[E0703]: effect `abort` is not grantable
  [1]

A user effect that reuses an official short name does not inherit its risk or grant:

  $ cat > spoof.jqd <<'JACQUARD'
  > (defeffect net () (op package.fetch once () (tref text)))
  > (app (var package.fetch))
  > JACQUARD
  $ jacquard check spoof.jqd --manifest console
  error[E0814]: this program requires unpackaged:a46cb801752d/net [unrated user effect #a46cb801752d15e51f6c46c91d0c4fa874b337d7186f8b3003230442baad74f1], which is not granted (performed via `package.fetch`)
    hint: handle the effect in the program (unregistered user effects have no built-in --allow grant)
  [1]
