Checker/effect gauntlet: higher-order rows leak authority, and handlers remove
only the effect they handle.

  $ export JACQUARD_PRELUDE=../../prelude

Higher-order effect leak: the argument function reaches for net, so the caller's
ambient row must include net.

  $ cat > ho-net.jqd <<'EOF_JQD'
  > (defterm ((binding call-twice ()
  >   (lam ((pvar f)) (tuple (app (var f) (lit 1)) (app (var f) (lit 2)))))))
  > (app (var call-twice) (lam ((pvar x)) (app (var net.get) (lit "https://x"))))
  > EOF_JQD
  $ jacquard check ho-net.jqd --print-sigs
  call-twice : forall a e. ((int) ->{e} a) ->{e} (a, a)
  _ : (text, text)
  $ jacquard check ho-net.jqd --manifest console
  error[E0814]: this program requires the `net` effect, which is not granted (performed via `net.get`)
    hint: grant it with --allow net, or handle the effect in the program
  [1]
  $ jacquard check ho-net.jqd --manifest net
  ok

Grant order and duplicates do not change the manifest decision.

  $ jacquard check ho-net.jqd --manifest net,console
  ok
  $ jacquard check ho-net.jqd --manifest console,net
  ok
  $ jacquard check ho-net.jqd --manifest net,net,console
  ok

A handler for console removes console, but the net effect remains in the manifest.

  $ cat > handle-net.jqd <<'EOF_JQD'
  > (handle
  >   (tuple (app (var print) (lit "x")) (app (var net.get) (lit "https://example.com")))
  >   (ret (pvar x) (var x))
  >   (opclause print ((pvar msg)) k (app (var k) (tuple))))
  > EOF_JQD
  $ jacquard check handle-net.jqd --print-sigs
  _ : ((), text)
  $ jacquard check handle-net.jqd --manifest console
  error[E0814]: this program requires the `net` effect, which is not granted (performed via `net.get`)
    hint: grant it with --allow net, or handle the effect in the program
  [1]
  $ jacquard check handle-net.jqd --manifest net
  ok
