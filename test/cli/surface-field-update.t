Nominal field updates (SX.28b, DES.4 Phase 2). `Ctor(value with label: e, ...)`
rebuilds `value` with the named fields replaced. It elaborates to the explicit
let-and-match twin, so hashes, the interpreter, and native code agree with the
hand-written form.

  $ export JACQUARD_PRELUDE=../../prelude
  $ export JACQUARD_RUNTIME=../../runtime
  $ export CC=clang

A `with` update and its hand-written twin hash identically, and a type-changing
update of a parametric field falls out of the twin:

  $ cat > twins.jac <<'J'
  > type Snap = | Snap(cells: Int, reverse: Int, cache: Int, hits: Int, computed: Int)
  > type Pair a b = | Pair(left: a, right: b)
  > refresh(s) = Snap(s with cells: 10, cache: 30)
  > refresh-twin(s) = {
  >   let value = s
  >   let cells = 10
  >   let cache = 30
  >   match value {
  >     | Snap(cells: _, cache: _, reverse: r, hits: h, computed: c) -> Snap(cells, r, cache, h, c)
  >   }
  > }
  > widen(p) = Pair(p with left: 2.5)
  > (refresh(Snap(1, 2, 3, 4, 5)), refresh-twin(Snap(1, 2, 3, 4, 5)), widen(Pair(1, "a")))
  > J
  $ jacquard run twins.jac
  (snap(10, 2, 30, 4, 5), snap(10, 2, 30, 4, 5), pair(2.5, "a"))
  $ jacquard build twins.jac -o twins > /dev/null && ./twins
  (snap(10, 2, 30, 4, 5), snap(10, 2, 30, 4, 5), pair(2.5, "a"))
  $ jacquard hash twins.jac | grep ':refresh' | awk '{print $2}' | uniq | wc -l
  1
  $ jacquard check --print-sigs twins.jac | grep widen
  widen : forall a b. (Pair b a) ->{} Pair Real a

The formatter keeps the `with` spelling, one field per line once the form
wraps, and never rewrites a setter into a `with` update or back:

  $ cat > layout.jac <<'J'
  > type Snap = | Snap(cells: List Int, cache: List Int, hits: Int, computed: Int)
  > grow(snapshot, next) = Snap(snapshot with cells: list.append(snap.cells(snapshot), [1, 2, 3]), cache: Cons(4, snap.cache(next)), computed: add(snap.computed(next), 1))
  > hit(s) = snap.with-hits(s, hits: add(snap.hits(s), 1))
  > J
  $ jacquard fmt layout.jac > formatted.jac
  $ sed -n '/^grow(/,$p' formatted.jac
  grow(
    snapshot,
    next,
  ) =
    Snap(snapshot with
      cells: list.append(snap.cells(snapshot), [1, 2, 3]),
      cache: Cons(4, snap.cache(next)),
      computed: add(snap.computed(next), 1),
    )
  
  hit(s) = snap.with-hits(s, hits: add(snap.hits(s), 1))
  $ jacquard fmt formatted.jac | cmp - formatted.jac && echo stable
  stable
  $ jacquard hash layout.jac > before.txt && jacquard hash formatted.jac | cmp - before.txt && echo same
  same
  $ jacquard export twins.jac -o twins.jqd && grep -c ' with ' twins.jqd
  0
  [1]

The source value is evaluated first, then each new field exactly once, in
source order, whatever the declaration order of the fields:

  $ cat > order.jac <<'J'
  > type Snap = | Snap(cells: Int, reverse: Int, cache: Int)
  > noisy(label, value) = {
  >   println(label)
  >   value
  > }
  > Snap(noisy("value", Snap(1, 2, 3)) with cache: noisy("cache", 30), cells: noisy("cells", 10))
  > J
  $ jacquard run --allow console order.jac
  value
  cache
  cells
  snap(10, 2, 30)
  $ jacquard build order.jac -o order > /dev/null && ./order --allow console
  value
  cache
  cells
  snap(10, 2, 30)

Unknown and repeated labels are the labeled-pattern errors, at the label:

  $ cat > labels.jac <<'J'
  > type Snap = | Snap(cells: Int, hits: Int)
  > unknown(s) = Snap(s with cels: 1)
  > J
  $ jacquard check labels.jac 2>&1 | head -2
  labels.jac:2:26-33: error[E0305]: This constructor has no field with the selected label.
    Cause: Field `cels` is not declared by this constructor.
  $ cat > repeated.jac <<'J'
  > type Snap = | Snap(cells: Int, hits: Int)
  > twice(s) = Snap(s with cells: 1, cells: 2)
  > J
  $ jacquard check repeated.jac 2>&1 | head -2
  repeated.jac:2:34-42: error[E0306]: A labeled constructor pattern selects one field more than once.
    Cause: Field `cells` is selected more than once in this pattern.

A `with` update names one constructor. On a sum type it rebuilds only that
constructor, so the exhaustiveness check refuses it and points at the total
setter:

  $ cat > shape.jac <<'J'
  > type Shape = | Circle(name: Text, radius: Int) | Square(name: Text, side: Int)
  > rename(s) = Circle(s with name: "c")
  > J
  $ jacquard check shape.jac 2>&1 | head -3
  shape.jac:2:13-37: error[E0813]: This match is not exhaustive
    Cause: this match is not exhaustive: it misses square(_, _); a `with` update rebuilds only the constructor it names; use `shape.with-name` for a total update
    Next step: Use `shape.with-name` for a total update, or write a match with a clause for every constructor.

Exactly one value precedes `with`, and at least one `label: expression`
follows it; anything else is a syntax error:

  $ cat > syntax.jac <<'J'
  > type Snap = | Snap(cells: Int, hits: Int)
  > two(s) = Snap(s, 1 with cells: 1)
  > after(s) = Snap(s with cells: 1, 2)
  > none(s) = Snap(s with)
  > piped(s) = s |> Snap(s with cells: 1)
  > J
  $ jacquard check syntax.jac 2>&1 | grep -E '^syntax|Cause'
  syntax.jac:2:20-24: error[E1220]: Surface syntax is invalid
    Cause: a `with` field update takes exactly one value before `with`: write `Ctor(value with label: expression, ...)`
  syntax.jac:3:34-35: error[E1220]: Surface syntax is invalid
    Cause: every field after `with` is written `label: expression`; a positional value cannot follow `with`
  syntax.jac:4:22-23: error[E1220]: Surface syntax is invalid
    Cause: a `with` field update needs at least one `label: expression` field after `with`
  syntax.jac:5:14-16: error[E1220]: Surface syntax is invalid
    Cause: a `with` field update cannot be the right side of `|>`: the pipe would pass a second value before `with`; update the piped value with `Ctor(value |> f with label: expression)`
