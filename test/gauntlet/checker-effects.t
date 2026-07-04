Checker/effect gauntlet: higher-order rows leak authority, and handlers remove
only the effect they handle.

  $ export WEFT_PRELUDE=../../prelude

Higher-order effect leak: the argument function reaches for net, so the caller's
ambient row must include net.

  $ cat > ho-net.wft <<'EOF_WFT'
  > (defterm ((binding call-twice ()
  >   (lam ((pvar f)) (tuple (app (var f) (lit 1)) (app (var f) (lit 2)))))))
  > (app (var call-twice) (lam ((pvar x)) (app (var net-fetch) (lit "https://x"))))
  > EOF_WFT
  $ weft check ho-net.wft --print-sigs
  call-twice : forall a e. ((int) ->{e} a) ->{e} (a, a)
  _ : (text, text)
  $ weft check ho-net.wft --manifest console
  error[E0814]: this program requires the `net` effect, which is not granted (performed via `net-fetch`)
    hint: grant it with --allow net, or handle the effect in the program
  [1]
  $ weft check ho-net.wft --manifest net
  ok

Grant order and duplicates do not change the manifest decision.

  $ weft check ho-net.wft --manifest net,console
  ok
  $ weft check ho-net.wft --manifest console,net
  ok
  $ weft check ho-net.wft --manifest net,net,console
  ok

A handler for console removes console, but the net effect remains in the manifest.

  $ cat > handle-net.wft <<'EOF_WFT'
  > (handle
  >   (tuple (app (var print) (lit "x")) (app (var net-fetch) (lit "https://example.com")))
  >   (ret (pvar x) (var x))
  >   (opclause print ((pvar msg)) k (app (var k) (tuple))))
  > EOF_WFT
  $ weft check handle-net.wft --print-sigs
  _ : ((), text)
  $ weft check handle-net.wft --manifest console
  error[E0814]: this program requires the `net` effect, which is not granted (performed via `net-fetch`)
    hint: grant it with --allow net, or handle the effect in the program
  [1]
  $ weft check handle-net.wft --manifest net
  ok
