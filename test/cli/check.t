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
  typo.jqd:1:6-14: error[E0301]: This reference names something that is not in scope.
    Cause: No name named `ad` is in scope; nearby names are `add`, `ask`, `eq`.
    Next step: Correct the reference to an in-scope name or declaration.
  [1]

Grammar violations are caught before resolution:

  $ cat > badgrammar.jqd <<'EOF'
  > (lam ((plit 1)) (lit 0))
  > EOF
  $ jacquard check badgrammar.jqd
  badgrammar.jqd:1:7-15: error[E0205]: A lambda parameter uses a refutable pattern.
    Cause: `lam` parameters must be irrefutable patterns (pwild, pvar, or ptuple/pas of those)
    Next step: Use an irrefutable variable, wildcard, tuple, or as-pattern parameter.
  [1]

DX.5 pins both input carriers at the structural boundary. Inputs at 10,000 active nodes are
accepted; one more node fails closed with a carrier-specific diagnostic and exit 1.

  $ awk 'BEGIN { for (i=0; i<9999; i++) printf "(tuple "; printf "(lit 0)"; for (i=0; i<9999; i++) printf ")"; printf "\n" }' > depth-at.jqd
  $ awk 'BEGIN { for (i=0; i<10000; i++) printf "(tuple "; printf "(lit 0)"; for (i=0; i<10000; i++) printf ")"; printf "\n" }' > depth-over.jqd
  $ jacquard check depth-at.jqd
  ok
  $ jacquard check depth-over.jqd > depth-over-jqd.out 2>&1; status=$?; grep -o 'error\[E0115\]:.*' depth-over-jqd.out; echo "exit:$status"
  error[E0115]: Bootstrap form nesting exceeds the structural limit.
  exit:1

  $ awk 'BEGIN { for (i=0; i<9999; i++) printf "("; printf "0"; for (i=0; i<9999; i++) printf ")"; printf "\n" }' > depth-at.jac
  $ awk 'BEGIN { for (i=0; i<10000; i++) printf "("; printf "0"; for (i=0; i<10000; i++) printf ")"; printf "\n" }' > depth-over.jac
  $ jacquard check depth-at.jac
  ok
  $ jacquard check depth-over.jac > depth-over-jac.out 2>&1; status=$?; grep -o 'error\[E1227\]:.*' depth-over-jac.out; echo "exit:$status"
  error[E1227]: Surface syntax nesting is too deep
  exit:1

The iterative postfix and pipe parsers build left-deep trees without recursive descent. Their
over-limit trees are quarantined before recovery checking, so `check` reports exactly E1227 instead
of overflowing or falling through to the E0003 backstop.

  $ awk 'BEGIN { printf "f"; for (i=0; i<10000; i++) printf "()"; printf "\n" }' > depth-over-postfix.jac
  $ awk 'BEGIN { printf "0"; for (i=0; i<10000; i++) printf " |> f"; printf "\n" }' > depth-over-pipe.jac
  $ for shape in postfix pipe; do out="depth-over-$shape.out"; jacquard check "depth-over-$shape.jac" > "$out" 2>&1; status=$?; e1227=$(grep -c 'error\[E1227\]' "$out"); errors=$(grep -c 'error\[' "$out"); if test "$status" -eq 1 && test "$e1227" -eq 1 && test "$errors" -eq 1 && ! grep -Eq 'E0003|Stack_overflow|internal error' "$out"; then echo "$shape: exact-E1227-exit-1"; else cat "$out"; exit 1; fi; done
  postfix: exact-E1227-exit-1
  pipe: exact-E1227-exit-1
