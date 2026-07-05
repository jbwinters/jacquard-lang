Formatter/diff gauntlet: formatting is idempotent, preserves content identity,
and produces no semantic diff.

  $ export JACQUARD_PRELUDE=../../prelude

  $ cat > ugly.wft <<'EOF_WFT'
  > (defterm ((binding id () (lam ((pvar x)) (var x)))))
  > EOF_WFT
  $ jacquard fmt ugly.wft > once.wft
  $ jacquard fmt once.wft > twice.wft
  $ cmp once.wft twice.wft

  $ jacquard hash ugly.wft > before.hash
  $ jacquard hash once.wft > after.hash
  $ cmp before.hash after.hash

  $ jacquard store add ugly ugly.wft
  ok
  $ jacquard store add pretty once.wft
  ok
  $ jacquard diff ugly pretty
  no semantic changes
