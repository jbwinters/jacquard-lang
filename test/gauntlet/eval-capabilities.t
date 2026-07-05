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
  error[E0814]: this program requires the `eval` effect, which is not granted (performed via `eval-code`)
    hint: grant it with --allow eval, or handle the effect in the program
  [3]

Even pure eval is gated; there is no pure-code shortcut around the capability.

  $ cat > pure-eval.jqd <<'EOF_JQD'
  > (app (var eval-code) (quote (lit 1)))
  > EOF_JQD
  $ jacquard run pure-eval.jqd
  error[E0814]: this program requires the `eval` effect, which is not granted (performed via `eval-code`)
    hint: grant it with --allow eval, or handle the effect in the program
  [3]
