Capability gauntlet: eval is a separate grant, and eval does not install net.

  $ export WEFT_PRELUDE=../../prelude

Eval can create code that performs net, but granting eval alone does not install
the net root handler.

  $ cat > eval-net.wft <<'EOF_WFT'
  > (app (var eval-code) (quote (app (var net.get) (lit "https://example.com"))))
  > EOF_WFT
  $ weft run eval-net.wft --allow eval
  unhandled effect net: operation `fetch` reached the root without a handler
  [3]
  $ weft run eval-net.wft --allow eval --allow net
  "<stub response for https://example.com>"

Granting net without eval still fails before runtime because the surface program's
manifest requires eval.

  $ weft run eval-net.wft --allow net
  error[E0814]: this program requires the `eval` effect, which is not granted (performed via `eval-code`)
    hint: grant it with --allow eval, or handle the effect in the program
  [3]

Even pure eval is gated; there is no pure-code shortcut around the capability.

  $ cat > pure-eval.wft <<'EOF_WFT'
  > (app (var eval-code) (quote (lit 1)))
  > EOF_WFT
  $ weft run pure-eval.wft
  error[E0814]: this program requires the `eval` effect, which is not granted (performed via `eval-code`)
    hint: grant it with --allow eval, or handle the effect in the program
  [3]
