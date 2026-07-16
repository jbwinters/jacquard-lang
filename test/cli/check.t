jacquard check: grammar + resolution, no evaluation (W2.7).

  $ export JACQUARD_PRELUDE=../../prelude

  $ cat > good.jqd <<'EOF'
  > (defterm ((binding twice () (lam ((pvar x)) (app (var add) (var x) (var x))))))
  > (app (var twice) (lit 4))
  > EOF
  $ jacquard check good.jqd
  ok

An unknown name is a diagnostic with a near-miss suggestion:

  $ cat > typo.jqd <<'EOF'
  > (app (var ad) (lit 1) (lit 2))
  > EOF
  $ jacquard check typo.jqd
  typo.jqd:1:6-14: error[E0301]: unknown name `ad`
    hint: did you mean one of: add, ask, eq?
  [1]

Grammar violations are caught before resolution:

  $ cat > badgrammar.jqd <<'EOF'
  > (lam ((plit 1)) (lit 0))
  > EOF
  $ jacquard check badgrammar.jqd
  badgrammar.jqd:1:7-15: error[E0205]: `lam` parameters must be irrefutable patterns (pwild, pvar, or ptuple/pas of those)
  [1]
