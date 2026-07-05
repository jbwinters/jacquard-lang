jacquard hash: canonical HASH_V0 hashes per top-level form (W2.7). Hashes are pinned by the
corpus goldens; here we check the shape and determinism.

  $ export JACQUARD_PRELUDE=../../prelude

  $ cat > one.jqd <<'EOF'
  > (defterm ((binding one () (lit 1))))
  > (lit 2)
  > EOF
  $ jacquard hash one.jqd | sed 's/[0-9a-f]\{64\}/HASH/'
  0 HASH
  0:one HASH
  1 HASH

Determinism: two runs agree byte for byte.

  $ jacquard hash one.jqd > a.txt && jacquard hash one.jqd > b.txt && cmp a.txt b.txt

Parse failures exit 1:

  $ printf '(' > bad.jqd
  $ jacquard hash bad.jqd
  bad.jqd:1:1-2: error[E0106]: unexpected end of input inside a form
  [1]

Resolution failures exit 1 too:

  $ printf '(app (var zzz-missing))\n' > unresolved.jqd
  $ jacquard hash unresolved.jqd
  unresolved.jqd:1:6-23: error[E0301]: unknown name `zzz-missing`
  [1]
