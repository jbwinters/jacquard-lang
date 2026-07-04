The capability manifest (W3.6): a program's inferred row is its authority
manifest; running or checking against a grant set enforces it.

  $ export WEFT_PRELUDE=../../prelude

The hostile demo: a generated-looking function that reaches for the network
taints every caller's row.

  $ cat > hostile.wft <<'EOF_WFT'
  > (defterm ((binding fetch-title ()
  >   (lam ((pvar url)) (app (var net.get) (var url))))))
  > (defterm ((binding summarize ()
  >   (lam ((pvar url)) (app (var fetch-title) (var url))))))
  > (app (var summarize) (lit "http://example.com"))
  > EOF_WFT
  $ weft check hostile.wft --print-sigs
  fetch-title : (text) ->{net} text
  summarize : (text) ->{net} text
  _ : text

Checking against a grant set that lacks net refuses at the type level, naming
the effect and the call-chain endpoint:

  $ weft check hostile.wft --manifest console
  error[E0814]: this program requires the `net` effect, which is not granted (performed via `net.get`)
    hint: grant it with --allow net, or handle the effect in the program
  [1]

With the grant it passes, and the granted run succeeds against the stub
handler:

  $ weft check hostile.wft --manifest net,console
  ok
  $ weft run hostile.wft --allow net
  "<stub response for http://example.com>"

Running without the net grant is the capability refusal (exit 3), even when
some other runtime handler is granted:

  $ weft run hostile.wft --allow console
  error[E0814]: this program requires the `net` effect, which is not granted (performed via `summarize`)
    hint: grant it with --allow net, or handle the effect in the program
  [3]
  $ weft run hostile.wft
  error[E0814]: this program requires the `net` effect, which is not granted (performed via `summarize`)
    hint: grant it with --allow net, or handle the effect in the program
  [3]

Pure effects are never grantable, so the hint must not suggest a --allow flag
that would only bounce with E0703:

  $ cat > pure.wft <<'WEFT'
  > (app (var option.get!) (var none))
  > WEFT
  $ weft run pure.wft
  error[E0814]: this program requires the `abort` effect, which is not granted (performed via `option.get!`)
    hint: handle the effect in the program (this effect is pure and cannot be granted)
  [3]
  $ weft run pure.wft --allow abort
  error[E0703]: effect `abort` is not grantable
  [1]
