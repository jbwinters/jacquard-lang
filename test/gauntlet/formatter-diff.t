Formatter/diff gauntlet: formatting is idempotent, preserves content identity,
and produces no semantic diff.

  $ export WEFT_PRELUDE=../../prelude

  $ cat > ugly.wft <<'EOF_WFT'
  > (defterm ((binding id () (lam ((pvar x)) (var x)))))
  > EOF_WFT
  $ weft fmt ugly.wft > once.wft
  $ weft fmt once.wft > twice.wft
  $ cmp once.wft twice.wft

  $ weft hash ugly.wft > before.hash
  $ weft hash once.wft > after.hash
  $ cmp before.hash after.hash

  $ weft store add ugly ugly.wft
  ok
  $ weft store add pretty once.wft
  ok
  $ weft diff ugly pretty
  no semantic changes
