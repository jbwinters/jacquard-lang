weft diff: semantic comparison of two stores (W5.2).

  $ cat > lib.wft <<'EOF_WFT'
  > (deftype color () (con red) (con green))
  > (defterm ((binding pick () (lam ((pvar b)) (match (var b) (clause (pcon red) (lit 1)) (clause (pcon green) (lit 2)))))))
  > EOF_WFT
  $ weft store add a lib.wft
  ok
  $ weft store add b lib.wft
  ok

A rename is exactly a rename:

  $ weft store rename b pick choose
  $ weft diff a b
  renamed  pick -> choose

A literal edit localizes to the changed leaf and lists dependents:

  $ cat > lib2.wft <<'EOF_WFT'
  > (deftype color () (con red) (con green))
  > (defterm ((binding pick () (lam ((pvar b)) (match (var b) (clause (pcon red) (lit 9)) (clause (pcon green) (lit 2)))))))
  > EOF_WFT
  $ weft store add c lib2.wft
  ok
  $ weft diff a c | grep -E 'changed|lit'
  changed  pick
    at pick/defterm[0]/group[0]/binding[2]/lam[1]/match[1]/clause[1]/lit[0]:

Identical stores have no semantic changes:

  $ weft diff a a
  no semantic changes
