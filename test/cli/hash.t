weft hash: canonical HASH_V0 hashes per top-level form (W2.7). Hashes are pinned by the
corpus goldens; here we check the shape and determinism.

  $ export WEFT_PRELUDE=../../prelude

  $ cat > one.wft <<'EOF'
  > (defterm ((binding one () (lit 1))))
  > (lit 2)
  > EOF
  $ weft hash one.wft | sed 's/[0-9a-f]\{64\}/HASH/'
  0 HASH
  0:one HASH
  1 HASH

Determinism: two runs agree byte for byte.

  $ weft hash one.wft > a.txt && weft hash one.wft > b.txt && cmp a.txt b.txt

Parse failures exit 1:

  $ printf '(' > bad.wft
  $ weft hash bad.wft
  bad.wft:1:1-2: error[E0106]: unexpected end of input inside a form
  [1]

Resolution failures exit 1 too:

  $ printf '(app (var zzz-missing))\n' > unresolved.wft
  $ weft hash unresolved.wft
  unresolved.wft:1:6-23: error[E0301]: unknown name `zzz-missing`
  [1]
