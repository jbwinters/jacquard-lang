buggy-sum-to = quote { fn (n) -> div(mul(n, sub(n, 1)), 2) }

intended-fix = quote { fn (n) -> div(mul(n, add(n, 1)), 2) }

op-swaps = Cons(quote { add }, Cons(quote { sub }, Cons(quote { mul }, Nil)))

op-mutants(leaf) =
  match list.contains?(op-swaps, leaf, MkEq(code.eq?)) {
    | False -> Nil
    | True -> list.filter(op-swaps, fn (op) -> bool.not(code.eq?(op, leaf)))}

lit-mutants(leaf) =
  match code.to-int(leaf) {
    | None -> Nil
    | Some(k) -> Cons(code.of-int(sub(k, 1)), Cons(code.of-int(add(k, 1)), Nil))}

leaf-edits(leaf) =
  list.append(list.map(op-mutants(leaf), fn (m) -> (m, "operator")),
    list.map(lit-mutants(leaf), fn (m) -> (m, "literal")))

set-nth(xs, i, x) =
  match xs {
    | Nil -> Nil
    | Cons(y, rest) ->
      match eq(i, 0) {
        | True -> Cons(x, rest)
        | False -> Cons(y, set-nth(rest, sub(i, 1), x))}}

code-mutants(c) =
  list.append(leaf-edits(c),
    match code.un-form(c) {
      | None -> Nil
      | Some((head, children)) ->
        list.concat(
          list.map(list.zip(children, list.range(0, list.length(children))),
            fn (slot) ->
              match slot {
                | (child, i) ->
                  list.map(code-mutants(child),
                    fn (edited) ->
                      match edited {
                        | (m, kind) -> (code.form(head, set-nth(children, i, m)), kind)})}))})

patch-weight(kind) = match kind {
                       | "operator" -> 3.0
                       | _ -> 1.0}

patch-prior(original) =
  Categorical(
    Cons(MkPair(original, 4.0),
      list.map(code-mutants(original),
        fn (edited) -> match edited {
                         | (m, kind) -> MkPair(m, patch-weight(kind))})))

passes?(code, spec) =
  {
    let f = `op:eval-code`(code)
    list.fold(spec, True,
      fn (acc, example) ->
        match example {
          | (input, expected) -> bool.and(acc, eq(f(input), expected))})}

repair(original, spec) =
  {
    let patch = `op:sample`(patch-prior(original))
    `op:observe`(Bernoulli(match passes?(patch, spec) {
                             | True -> 1.0
                             | False -> 0.0}), True)
    patch}

posterior-over-patches(original, spec) =
  dist.tally(dist.enumerate(fn () -> repair(original, spec)), MkEq(code.eq?))

surviving-patches(table) =
  list.filter(table, fn (entry) -> match entry {
                                     | MkPair(_, p) -> lt-real(0.0, p)})

map-patch(original, table) =
  match list.fold(table, MkPair(original, 0.0),
          fn (best, entry) -> match (best, entry) {
                               | (MkPair(_, bp), MkPair(_, ep)) -> match lt-real(bp, ep) {
                                                                    | True -> entry | False -> best}}) {
    | MkPair(code, _) -> code}

bug-report = Cons((3, 6), Nil)

regression-spec = Cons((1, 1), bug-report)

list.length(code-mutants(buggy-sum-to))

surviving-patches(posterior-over-patches(buggy-sum-to, bug-report))

code.diff(buggy-sum-to, map-patch(buggy-sum-to, posterior-over-patches(buggy-sum-to, bug-report)))

surviving-patches(posterior-over-patches(buggy-sum-to, regression-spec))

code.diff(buggy-sum-to,
  map-patch(buggy-sum-to, posterior-over-patches(buggy-sum-to, regression-spec)))
