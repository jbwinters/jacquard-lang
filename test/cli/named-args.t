SX.23 named calls use explicit labels and lower to the existing positional App. Reordered
arguments retain source evaluation order while the final application uses declaration order.

  $ export JACQUARD_PRELUDE=../../prelude
  $ export JACQUARD_RUNTIME=../../runtime
  $ export CC=clang
  $ cat > named-order.jac <<'EOF'
  > ordered(left: first, right: second) = (first, second)
  > ordered(
  >   right: { print("R"); 2 },
  >   left: { print("L"); 1 },
  > )
  > EOF
  $ jac run named-order.jac --allow console > interpreted.out
  $ jac build named-order.jac -o named-order-native > /dev/null
  $ ./named-order-native --allow console > native.out
  $ cmp interpreted.out native.out && echo identical
  identical
  $ cat interpreted.out
  RL(1, 2)

Formatting retains labels and is idempotent. Explicit bootstrap export contains only positional
kernel application, and both carriers have identical hashes and behavior.

  $ jac fmt named-order.jac > named-order-formatted.jac
  $ jac fmt named-order-formatted.jac > named-order-twice.jac
  $ cmp named-order-formatted.jac named-order-twice.jac && grep -o 'right:' named-order-formatted.jac | wc -l | tr -d ' '
  2
  $ jac export named-order.jac -o named-order.jqd
  $ jac hash named-order.jac > named-order.jac.hash
  $ jac hash named-order.jqd > named-order.jqd.hash
  $ cmp named-order.jac.hash named-order.jqd.hash && echo hash-identical
  hash-identical
  $ jac run named-order.jqd --allow console
  RL(1, 2)

Constructors reuse their declared field labels. Operations and top-level terms declare their own
labels explicitly; each may keep an unlabeled positional prefix.

  $ cat > supported.jac <<'EOF'
  > type Packet = | Packet(Int, body: Int)
  > once effect Sending where {
  >   send : (Int, body: Int) -> Int
  > }
  > resize(image, scale: ratio) = (image, ratio)
  > (
  >   Packet(1, body: 2),
  >   resize(3, scale: 4),
  >   handle `op:send`(5, body: 6) {
  >     | return value -> value
  >     | send(path, body) resume continue -> continue(path)
  >   },
  > )
  > EOF
  $ jac check supported.jac
  ok
  $ jac run supported.jac
  (packet(1, 2), (3, 4), 5)

Unknown, duplicate, missing, opaque/local, malformed-schema, and quoted labels fail closed with
one focused diagnostic. The unknown-label message names a concrete repair.

  $ cat > bad-unknown.jac <<'EOF'
  > choose(left: x, right: y) = (x, y)
  > choose(left: 1, wrong: 2)
  > EOF
  $ jac check bad-unknown.jac > bad-unknown.out 2>&1; status=$?; grep -E 'error\[E0310\]|Next step:' bad-unknown.out; echo "exit:$status"
  bad-unknown.jac:2:17-25: error[E0310]: This callable has no slot with the selected label.
    Next step: Use one of the callable's declared external labels.
  exit:1
  $ sed 's/wrong: 2/left: 2/' bad-unknown.jac > bad-duplicate.jac
  $ jac check bad-duplicate.jac > duplicate.out 2>&1; status=$?; grep -o 'error\[E0311\]' duplicate.out; echo "exit:$status"
  error[E0311]
  exit:1
  $ sed 's/, wrong: 2//' bad-unknown.jac > bad-missing.jac
  $ jac check bad-missing.jac > missing.out 2>&1; status=$?; grep -o 'error\[E0312\]' missing.out; echo "exit:$status"
  error[E0312]
  exit:1
  $ cat > bad-local.jac <<'EOF'
  > { let local = fn (x) -> x; local(value: 1) }
  > EOF
  $ jac check bad-local.jac > local.out 2>&1; status=$?; grep -o 'error\[E0309\]' local.out; echo "exit:$status"
  error[E0309]
  exit:1
  $ cat > bad-schema.jac <<'EOF'
  > type Mixed = | Mixed(left: Int, Int)
  > Mixed(left: 1, other: 2)
  > EOF
  $ jac check bad-schema.jac > schema.out 2>&1; status=$?; grep -o 'error\[E0314\]' schema.out; echo "exit:$status"
  error[E0314]
  exit:1
  $ cat > bad-quote.jac <<'EOF'
  > quote { unquote(choose(left: 1)) }
  > EOF
  $ jac check bad-quote.jac > quote.out 2>&1; status=$?; grep -o 'error\[E1238\]' quote.out; echo "exit:$status"
  error[E1238]
  exit:1

When a direct API exposes an applicable label, the checker warns about a positional Bool constructor
literal, or one definite run of repeated parameter types when no Bool warning already owns the call.
Named calls and purpose-specific sum types avoid these review warnings.

  $ cat > warnings.jac <<'EOF'
  > choose-flag(flag: value) = value
  > sum-pair : (Int, Int) ->{} Int
  > sum-pair(left: x, right: y) = x
  > choose-flag(True)
  > sum-pair(1, 2)
  > EOF
  $ jac check warnings.jac > warnings.out 2>&1
  $ grep -o 'warning\[W120[67]\]' warnings.out
  warning[W1206]
  warning[W1207]
  $ cat > warning-free.jac <<'EOF'
  > choose-flag(flag: value) = value
  > sum-pair : (Int, Int) ->{} Int
  > sum-pair(left: x, right: y) = x
  > type Mode = | Live | DryRun
  > deploy(mode: value) = match value { | Live -> 1 | DryRun -> 0 }
  > choose-flag(flag: True)
  > sum-pair(left: 1, right: 2)
  > deploy(Live)
  > EOF
  $ jac check warning-free.jac > warning-free.out 2>&1
  $ grep -c 'warning\[W120[67]\]' warning-free.out || true
  0
