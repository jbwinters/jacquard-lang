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

DX.5 pins both input carriers at the structural boundary. Inputs at 10,000 active nodes are
accepted; one more node fails closed with a carrier-specific diagnostic and exit 1.

  $ awk 'BEGIN { for (i=0; i<9999; i++) printf "(tuple "; printf "(lit 0)"; for (i=0; i<9999; i++) printf ")"; printf "\n" }' > depth-at.jqd
  $ awk 'BEGIN { for (i=0; i<10000; i++) printf "(tuple "; printf "(lit 0)"; for (i=0; i<10000; i++) printf ")"; printf "\n" }' > depth-over.jqd
  $ jacquard check depth-at.jqd
  ok
  $ jacquard check depth-over.jqd > depth-over-jqd.out 2>&1; status=$?; grep -o 'error\[E0115\]:.*' depth-over-jqd.out; echo "exit:$status"
  error[E0115]: bootstrap form nesting exceeds the limit of 10000
  exit:1

  $ awk 'BEGIN { for (i=0; i<9999; i++) printf "("; printf "0"; for (i=0; i<9999; i++) printf ")"; printf "\n" }' > depth-at.jac
  $ awk 'BEGIN { for (i=0; i<10000; i++) printf "("; printf "0"; for (i=0; i<10000; i++) printf ")"; printf "\n" }' > depth-over.jac
  $ jacquard check depth-at.jac
  ok
  $ jacquard check depth-over.jac > depth-over-jac.out 2>&1; status=$?; grep -o 'error\[E1227\]:.*' depth-over-jac.out; echo "exit:$status"
  error[E1227]: surface syntax nesting exceeds the limit of 10000
  exit:1
