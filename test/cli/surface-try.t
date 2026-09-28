Result propagation with `try` (SX.29, D77). `let x = try e` binds the Ok
payload and continues the enclosing block; an Err ends that block with the
same Err. It elaborates to an ordinary `match`, so hashes, the interpreter,
and native code agree with the hand-written form.

  $ export JACQUARD_PRELUDE=../../prelude
  $ export JACQUARD_RUNTIME=../../runtime
  $ export CC=clang

Request validation with several fallible steps and declared Result types, in
the interpreter and natively:

  $ jacquard run ../../demos/request-validation/validate.jac
  "accepted Ada, 36"
  "rejected: a field is missing"
  "rejected: malformed ada.example.org"
  "rejected: 12 is under 18"
  $ jacquard build ../../demos/request-validation/validate.jac -o validate > /dev/null
  $ ./validate
  "accepted Ada, 36"
  "rejected: a field is missing"
  "rejected: malformed ada.example.org"
  "rejected: 12 is under 18"

A `try` block and its hand-written positional twin hash identically, and the
formatter keeps the `try` spelling:

  $ cat > twins.jac <<'J'
  > parse-age(t) = match text.to-int(t) {
  >   | Some(n) -> Ok(n)
  >   | None -> Err("not a number")
  > }
  > adult(n) = if int.gte?(n, 18) then Ok(n) else Err("under 18")
  > admit(t) = {
  >   let n = try parse-age(t)
  >   let m = try adult(n)
  >   Ok(int.add(m, 1))
  > }
  > admit-twin(t) = match parse-age(t) {
  >   | Ok(n) -> match adult(n) {
  >     | Ok(m) -> Ok(int.add(m, 1))
  >     | Err(error) -> Err(error)
  >   }
  >   | Err(error) -> Err(error)
  > }
  > (admit("40"), admit("x"), admit("12"))
  > J
  $ jacquard run twins.jac
  (ok(41), err("not a number"), err("under 18"))
  $ jacquard hash twins.jac | grep admit | awk '{print $2}' | uniq | wc -l
  1
  $ jacquard fmt twins.jac > formatted.jac
  $ sed -n '/^admit(/,/^$/p' formatted.jac
  admit(t) = {
               let n = try parse-age(t)
               let m = try adult(n)
               Ok(int.add(m, 1))}
  
  $ jacquard fmt formatted.jac | cmp - formatted.jac && echo stable
  stable
  $ jacquard export twins.jac -o twins.jqd && grep -c "try" twins.jqd
  0
  [1]

No step runs after the first Err, and effects before it happen in order:

  $ cat > order.jac <<'J'
  > step(label, r) = {
  >   println(label)
  >   r
  > }
  > chain() = {
  >   let a = try step("first", Ok(1))
  >   let b = try step("second", Err("stop"))
  >   let c = try step("third", Ok(3))
  >   Ok(int.add(a, int.add(b, c)))
  > }
  > chain()
  > J
  $ jacquard run --allow console order.jac
  first
  second
  err("stop")
  $ jacquard build order.jac -o order > /dev/null && ./order --allow console
  first
  second
  err("stop")

An Err leaves only the innermost block: a nested function's `try` returns
from that function, and the caller keeps the Result as a value. Inside a
handler, a `once` answer and each `multi` resumption propagate independently:

  $ cat > scopes.jac <<'J'
  > once effect Ask where {
  >   count-of : (Text) -> Result Text Int
  > }
  > multi effect Pick where {
  >   pick : () -> Bool
  > }
  > inner(x) = {
  >   let y = try x
  >   Ok(int.add(y, 1))
  > }
  > outer() = {
  >   let kept = inner(Err("inner"))
  >   let fine = try inner(Ok(1))
  >   Ok((kept, fine))
  > }
  > lookup(key) =
  >   handle {
  >     let v = try count-of(key)
  >     Ok(int.add(v, 1))
  >   } {
  >     | return r -> r
  >     | count-of(k) resume go -> go(if text.empty?(k) then Err("empty key") else Ok(41))
  >   }
  > both() =
  >   handle {
  >     let b = try (if pick() then Ok(1) else Err("no"))
  >     Ok(int.add(b, 10))
  >   } {
  >     | return r -> [r]
  >     | pick() resume k -> list.append(k(True), k(False))
  >   }
  > (outer(), lookup("k"), lookup(""), both())
  > J
  $ jacquard run scopes.jac
  (ok((err("inner"), 2)), ok(42), err("empty key"), cons(ok(11), cons(err("no"), nil)))
  $ jacquard build scopes.jac -o scopes > /dev/null && ./scopes
  (ok((err("inner"), 2)), ok(42), err("empty key"), cons(ok(11), cons(err("no"), nil)))

The error type is preserved exactly; there is no implicit conversion:

  $ cat > mismatch.jac <<'J'
  > f() = {
  >   let x = try Err(1)
  >   Err("text")
  > }
  > J
  $ jacquard check mismatch.jac 2>&1 | head -2
  mismatch.jac:2:3-21: error[E0801]: Types do not agree
    Cause: match clause result: expected result text a, got result int a (type mismatch)

Quoted code stores the elaboration:

  $ cat > quoted.jac <<'J'
  > code.render(quote { {
  >   let x = try Ok(1)
  >   Ok(x)
  > } })
  > J
  $ jacquard run quoted.jac
  "(match (app (surface-ref-v0 con ok) (lit 1)) (clause (pcon ok (pvar x)) (app (surface-ref-v0 con ok) (var x))) (clause (pcon err (pvar error)) (app (surface-ref-v0 con err) (var error))))"

Like `if` and list literals, `try` binds the prelude's `Ok` and `Err` by
identity (SX.31), so a file that declares its own `Err` cannot capture it:

  $ cat > shadow.jac <<'J'
  > good() = Ok(1)
  > type Other = | Err Int
  > f() = {
  >   let x = try good()
  >   good()
  > }
  > f()
  > J
  $ jacquard run shadow.jac
  ok(1)

`try` is only a block item, never the last one, and never on `let rec`:

  $ printf 'f(x) = g(try x)\n' > expr.jac
  $ jacquard check expr.jac 2>&1 | grep E1242
  expr.jac:1:10-13: error[E1242]: `try` is used outside a block item
  $ printf 'f(x) = {\n  try x\n}\n' > tail.jac
  $ jacquard check tail.jac 2>&1 | head -3
  tail.jac:2:3-8: error[E1243]: A block ends in `try`.
    Cause: A block cannot end in `try`: the value of the final item is already the block's Result; write the expression itself.
    Next step: Write the final expression itself; its Result is already the block's value.
  $ printf 'f(x) = {\n  let rec h(y) = try x\n  x\n}\n' > rec.jac
  $ jacquard check rec.jac 2>&1 | grep E1244
  rec.jac:2:18-21: error[E1244]: A recursive local binding uses `try`
