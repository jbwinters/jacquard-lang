Checked State payloads must agree before either execution engine starts.

  $ export JACQUARD_PRELUDE=../../prelude
  $ cat > state-payload.jac <<'EOF'
  > bad : () ->{} (Text, Int)
  > bad() = state.run(fn () -> { put("hi"); get() }, 0)
  > bad()
  > EOF
  $ for command in check run build; do if test "$command" = build; then set -- -o rejected-native; else set --; fi; jacquard "$command" state-payload.jac "$@" > "$command.stdout" 2> "$command.stderr"; status=$?; if test "$status" = 1 && test ! -s "$command.stdout" && grep -q 'error\[E0801\]' "$command.stderr"; then echo "$command: static refusal"; else cat "$command.stdout" "$command.stderr"; echo "$command: unexpected exit $status"; exit 1; fi; done
  check: static refusal
  run: static refusal
  build: static refusal

Partial payload handlers are refused before their omitted operation can reach
an outer region with another payload type.

  $ cat > partial-state.jac <<'EOF'
  > bad : () ->{} (Text, Int)
  > bad() = state.run(fn () -> handle { put("hi"); get() } {
  > | return value -> value
  > | get() resume k -> k("inner")
  > }, 0)
  > bad()
  > EOF
  $ for command in check run build; do
  >   if test "$command" = build; then set -- -o partial-native; else set --; fi
  >   jacquard "$command" partial-state.jac "$@" > stdout 2> stderr; status=$?
  >   if test "$status" = 1 && test ! -s stdout && grep -q 'partial handler for state' stderr && grep -q 'Add a clause for every operation' stderr; then echo "$command: partial handler refusal"; else cat stdout stderr; exit 1; fi
  > done
  check: partial handler refusal
  run: partial handler refusal
  build: partial handler refusal
  $ test ! -e partial-native

Throw and Emit mismatches use the same checked entry points.

  $ echo 'throw.catch(fn () -> throw("hi"), fn (n) -> add(n, 1))' > throw-payload.jac
  $ echo '(emit.collect(fn () -> emit("hi")) : ((), List Int))' > emit-payload.jac
  $ for effect in throw emit; do
  >   for command in check run build; do
  >     if test "$command" = build; then set -- -o rejected-native; else set --; fi
  >     jacquard "$command" "$effect-payload.jac" "$@" > stdout 2> stderr; status=$?
  >     if test "$status" = 1 && test ! -s stdout && grep -Eq 'error\[E080[14]\]' stderr; then echo "$effect $command: static refusal"; else cat stdout stderr; echo "unexpected exit $status"; exit 1; fi
  >   done
  > done
  throw check: static refusal
  throw run: static refusal
  throw build: static refusal
  emit check: static refusal
  emit run: static refusal
  emit build: static refusal

Typed handlers, aliases, higher-order calls, and independent regions agree
across execution engines.

  $ export JACQUARD_RUNTIME=../../runtime
  $ export CC=clang
  $ cat > supported-payloads.jac <<'EOF'
  > apply(f, x) = f(x)
  > store-payload(s) = apply(put, s)
  > state.run(fn () -> { store-payload(42); get() }, 0)
  > state.run(fn () -> { state.run(fn () -> { put(2); get() }, 0); get() }, "outer")
  > state.run(fn () -> handle { put(42); get() } { | return value -> value | get() resume k -> k(7) | put(value) resume k -> { put(value); k(()) } }, 0)
  > throw.catch(fn () -> throw("hi"), fn (message) -> text.length(message))
  > (throw.to-result(fn () -> throw(1)), throw.to-result(fn () -> throw("hi")))
  > (emit.collect(fn () -> apply(emit, 1)), emit.collect(fn () -> emit("hi")))
  > EOF
  $ jacquard run supported-payloads.jac > interpreter.out
  $ jacquard build supported-payloads.jac -o supported-native > /dev/null
  $ ./supported-native > native.out
  $ diff -u interpreter.out native.out && cat native.out
  (42, 42)
  ("outer", "outer")
  (7, 42)
  2
  (err(1), err("hi"))
  (((), cons(1, nil)), ((), cons("hi", nil)))
