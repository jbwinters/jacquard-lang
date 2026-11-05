A handler discharges an effect only when it has a clause for every one of the
effect's operations. A partial handler forwards the operations it omits to the
next handler out, so its effect stays in the residual row.

  $ export JACQUARD_PRELUDE=../../prelude
  $ cat > two.jac <<'EOF'
  > once effect Two where { first : (Int) -> Int; second : (Int) -> Int }
  > only-first(thunk) = handle thunk() {
  > | return v -> v
  > | first(n) resume k -> k(n)
  > }
  > EOF

Claiming the partial handler's caller is pure is a check-time refusal, in every
command, before either engine runs.

  $ cat two.jac - > leak.jac <<'EOF'
  > leak : () ->{} Int
  > leak() = only-first(fn () -> second(1))
  > leak()
  > EOF
  $ for command in check run build; do
  >   if test "$command" = build; then set -- -o leak-native; else set --; fi
  >   jacquard "$command" leak.jac "$@" > stdout 2> stderr; status=$?
  >   if test "$status" = 1 && test ! -s stdout && grep -q 'error\[E0804\]' stderr && grep -q 'got () ->{two | e} int' stderr; then echo "$command: static refusal"; else cat stdout stderr; echo "$command: unexpected exit $status"; exit 1; fi
  > done
  check: static refusal
  run: static refusal
  build: static refusal
  $ test ! -e leak-native

The inferred signature names the forwarded effect.

  $ cat two.jac - > inferred.jac <<'EOF'
  > leak() = only-first(fn () -> second(1))
  > EOF
  $ jacquard check inferred.jac --print-sigs > sigs
  $ grep '^leak' sigs
  leak : () ->{Two} Int

A complete handler still discharges the effect.

  $ cat two.jac - > complete.jac <<'EOF'
  > both : () ->{} Int
  > both() = handle { add(first(1), second(2)) } {
  > | return v -> v
  > | first(n) resume k -> k(n)
  > | second(n) resume k -> k(mul(n, 10))
  > }
  > both()
  > EOF
  $ jacquard run complete.jac
  21

A complete outer handler receives the forwarded operation, and the program is
pure again. Both engines agree.

  $ cat two.jac - > outer.jac <<'EOF'
  > outer : () ->{} Int
  > outer() = handle only-first(fn () -> add(first(1), second(2))) {
  > | return v -> v
  > | first(n) resume k -> k(mul(n, 100))
  > | second(n) resume k -> k(mul(n, 10))
  > }
  > outer()
  > EOF
  $ jacquard run outer.jac
  21
  $ jacquard build outer.jac -o outer-native
  native: compiled 3 unit(s)
  $ ./outer-native
  21
