jacquard diff: semantic comparison of two stores (W5.2).

  $ cat > lib.jqd <<'EOF_JQD'
  > (deftype color () (con red) (con green))
  > (defterm ((binding pick () (lam ((pvar b)) (match (var b) (clause (pcon red) (lit 1)) (clause (pcon green) (lit 2)))))))
  > EOF_JQD
  $ jacquard store add a lib.jqd
  ok
  $ jacquard store add b lib.jqd
  ok

A rename is exactly a rename:

  $ jacquard store rename b pick choose
  $ jacquard diff a b
  renamed  pick -> choose

A literal edit localizes to the changed leaf and lists dependents:

  $ cat > lib2.jqd <<'EOF_JQD'
  > (deftype color () (con red) (con green))
  > (defterm ((binding pick () (lam ((pvar b)) (match (var b) (clause (pcon red) (lit 9)) (clause (pcon green) (lit 2)))))))
  > EOF_JQD
  $ jacquard store add c lib2.jqd
  ok
  $ jacquard diff a c | grep -E 'changed|lit'
  changed  pick
    at pick/defterm[0]/group[0]/binding[2]/lam[1]/match[1]/clause[1]/lit[0]:

Identical stores have no semantic changes:

  $ jacquard diff a a
  no semantic changes
