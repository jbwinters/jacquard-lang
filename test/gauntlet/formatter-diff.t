Formatter/diff gauntlet: formatting is idempotent, preserves content identity,
and produces no semantic diff.

  $ export JACQUARD_PRELUDE=../../prelude

  $ cat > ugly.jqd <<'EOF_JQD'
  > (defterm ((binding id () (lam ((pvar x)) (var x)))))
  > EOF_JQD
  $ jacquard fmt ugly.jqd > once.jqd
  $ jacquard fmt once.jqd > twice.jqd
  $ cmp once.jqd twice.jqd

  $ jacquard hash ugly.jqd > before.hash
  $ jacquard hash once.jqd > after.hash
  $ cmp before.hash after.hash

  $ jacquard store add ugly ugly.jqd
  ok
  $ jacquard store add pretty once.jqd
  ok
  $ jacquard diff ugly pretty
  no semantic changes
