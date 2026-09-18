-- Full-state observations include graph order, cache entries, counters, and history.
nb.snapshot-text(
  snapshot,
) =
  {
    let cells =
      list.map(
        nb.cells(snapshot),
        fn (
          cell,
        ) ->
          nb.join(
            [nb.cell-name(cell), nb.cell-source(cell), nb.join(nb.cell-deps(cell), ",")],
            "|",
          ),
      )
    let edges =
      list.map(
        nb.edges(snapshot),
        fn (edge) -> match edge {
                       | NbEdge(a, b) -> text.concat(text.concat(a, ">"), b)},
      )
    let cache =
      list.map(
        nb.cache(snapshot),
        fn (
          entry,
        ) ->
          match entry {
            | NbEntry(name, value) -> text.concat(text.concat(name, "="), nb.value-text(value))
          },
      )
    nb.join(
      [nb.join(cells, ";"), nb.join(edges, ";"), nb.join(cache, ";"), nb.stats(snapshot)],
      "\n",
    )
  }

nb.book-text(
  book,
) =
  nb.join(
    [
      nb.snapshot-text(nb.current(book)),
      nb.join(list.map(nb.undo-list(book), nb.snapshot-text), "\n---\n"),
      nb.join(list.map(nb.redo-list(book), nb.snapshot-text), "\n---\n"),
    ],
    "\n===\n",
  )

nb.set(book, name, source) = nb.outcome-book(nb.commit(book, NbSet(name, source)))

nb.run-lines(
  lines,
) =
  list.fold(lines, nb.empty(), fn (book, line) -> nb.response-book(nb.execute(book, line)))

nb.check-value(
  book,
  name,
  expected,
) =
  check.eq(
    nb.value-text(nb.visible-value(nb.current(book), name)),
    expected,
    text.eq,
    text.show,
    name,
  )

nb.check-reference(
  book,
) =
  {
    let snapshot = nb.current(book)
    list.each(
      nb.cells(snapshot),
      fn (
        cell,
      ) ->
        {
          let name = nb.cell-name(cell)
          let actual = nb.visible-value(snapshot, name)
          let expected = nb.fresh(NbRef(name), nb.cells(snapshot), name)
          check.eq(
            nb.value-text(actual),
            nb.value-text(expected),
            text.eq,
            text.show,
            text.concat("fresh versus cached: ", name),
          )
        },
    )
    let cache-names =
      list.map(nb.cache(snapshot), fn (entry) -> match entry {
                                                   | NbEntry(name, _) -> name})
    check.eq(
      list.length(cache-names),
      list.length(nb.unique(cache-names)),
      int.eq,
      int.show,
      "no duplicate cache entries",
    )
  }

nb.graph-tests =
  Group(
    "dependency graph and cache",
    [
      Case(
        "missing references, arithmetic origins, and repair propagate",
        fn () ->
          {
            let waiting = nb.run-lines(["set total = part + 1", "set part = source / 0"])
            nb.check-value(waiting, "total", "ERROR [source]: undefined cell")
            let defined = nb.set(waiting, "source", "10")
            nb.check-value(defined, "total", "ERROR [part]: division by zero")
            let repaired = nb.set(defined, "part", "source / 2")
            nb.check-value(repaired, "total", "6")
            let removed = nb.response-book(nb.execute(repaired, "unset source"))
            nb.check-value(removed, "total", "ERROR [source]: undefined cell")
            nb.check-reference(removed)
            let restored = nb.set(removed, "source", "20")
            nb.check-value(restored, "total", "11")
            nb.check-reference(restored)
          },
      ),
      Case(
        "cycles report actual paths and failed edits preserve all state",
        fn () ->
          {
            let book =
              nb.run-lines(
                ["set a = 2", "set b = a + 1", "set c = b * 2", "set unused = 9", "undo"],
              )
            list.each(
              [
                ("set a = a", "a -> a"),
                ("set a = c", "a -> c -> b -> a"),
                ("set a = (2 +)", "column 5:"),
                ("set 1a = 2", "invalid cell name"),
                ("unset missing", "undefined cell"),
              ],
              fn (
                example,
              ) ->
                {
                  let (line, expected) = example
                  let response = nb.execute(book, line)
                  check.true(text.contains?(nb.response-output(response), expected), line)
                  check.eq(
                    nb.book-text(nb.response-book(response)),
                    nb.book-text(book),
                    text.eq,
                    text.show,
                    "atomic rejection including redo",
                  )
                },
            )
            let forward = nb.set(nb.empty(), "a", "b")
            let cycle = nb.execute(forward, "set b = a")
            check.true(
              text.contains?(nb.response-output(cycle), "b -> a -> b"),
              "forward-reference cycle",
            )
            check.eq(
              nb.book-text(nb.response-book(cycle)),
              nb.book-text(forward),
              text.eq,
              text.show,
              "forward cycle atomic",
            )
          },
      ),
      Case(
        "diamond computes once per affected cell and reuses independent cache",
        fn () ->
          {
            let book =
              nb.run-lines(
                [
                  "set root = 1",
                  "set left = root + 1",
                  "set right = root + 2",
                  "set total = left + right",
                  "set independent = 99",
                ],
              )
            let before = nb.current(book)
            let changed = nb.set(book, "root", "3")
            let after = nb.current(changed)
            check.eq(
              sub(nb.computed(after), nb.computed(before)),
              4,
              int.eq,
              int.show,
              "root, left, right, total only",
            )
            check.eq(
              sub(nb.hits(after), nb.hits(before)),
              5,
              int.eq,
              int.show,
              "four dependency hits and independent hit",
            )
            nb.check-value(changed, "total", "9")
            nb.check-value(changed, "independent", "99")
            nb.check-reference(changed)
          },
      ),
      Case(
        "replaced dependencies remove stale edges and missing caches are invalidated",
        fn () ->
          {
            let book =
              nb.run-lines(
                ["set a = 1", "set b = 2", "set x = a", "set total = x + 1", "set x = b"],
              )
            let changed = nb.set(book, "a", "8")
            check.eq(
              sub(nb.computed(nb.current(changed)), nb.computed(nb.current(book))),
              1,
              int.eq,
              int.show,
              "obsolete source only",
            )
            check.eq(
              list.length(nb.dependents(nb.edges(nb.current(changed)), "a")),
              0,
              int.eq,
              int.show,
              "obsolete reverse edge removed",
            )
            let waiting = nb.set(changed, "x", "unknown + b")
            let repaired = nb.set(waiting, "unknown", "7")
            check.eq(
              sub(nb.computed(nb.current(repaired)), nb.computed(nb.current(waiting))),
              3,
              int.eq,
              int.show,
              "missing source plus two dependents",
            )
            nb.check-value(repaired, "total", "10")
            nb.check-reference(repaired)
          },
      ),
      Case(
        "cell limit rejects atomically and replacement remains possible",
        fn () ->
          {
            let book =
              list.fold(
                list.range(0, 40),
                nb.empty(),
                fn (
                  state,
                  n,
                ) ->
                  nb.set(state, text.concat("cell", text.from-int(n)), text.from-int(n)),
              )
            check.eq(list.length(nb.cells(nb.current(book))), 40, int.eq, int.show, "forty cells")
            let rejected = nb.execute(book, "set overflow = 1")
            check.eq(
              nb.book-text(nb.response-book(rejected)),
              nb.book-text(book),
              text.eq,
              text.show,
              "capacity failure atomic",
            )
            check.true(
              text.contains?(nb.response-output(rejected), "40 defined cells"),
              "capacity explained",
            )
            nb.check-value(nb.set(book, "cell0", "100"), "cell0", "100")
          },
      ),
      Case(
        "replacing missing references does not retain abandoned cache entries",
        fn () ->
          {
            let book =
              list.fold(
                list.range(0, 30),
                nb.empty(),
                fn (state, n) -> nb.set(state, "x", text.concat("absent", text.from-int(n))),
              )
            check.eq(
              list.length(nb.cache(nb.current(book))),
              2,
              int.eq,
              int.show,
              "only x and its current missing source remain",
            )
            nb.check-value(book, "x", "ERROR [absent29]: undefined cell")
            nb.check-reference(book)
          },
      ),
    ],
  )

nb.history-tests =
  Group(
    "preview and snapshot history",
    [
      Case(
        "preview leaves definitions, caches, counters, undo, and redo unchanged",
        fn () ->
          {
            let book = nb.run-lines(["set a = 2", "set b = a * 3", "set a = 4", "undo"])
            list.each(
              [
                "whatif a = 7",
                "whatif a = missing",
                "whatif a = b",
                "whatif a = 1 +",
                "whatif extra = 5",
              ],
              fn (
                line,
              ) ->
                {
                  let response = nb.execute(book, line)
                  check.eq(
                    nb.book-text(nb.response-book(response)),
                    nb.book-text(book),
                    text.eq,
                    text.show,
                    line,
                  )
                },
            )
            let preview = nb.execute(book, "whatif a = 7")
            check.true(
              text.contains?(nb.response-output(preview), "b: 6 -> 21"),
              "preview computes downstream",
            )
            nb.check-value(book, "b", "6")
          },
      ),
      Case(
        "undo redo restore entire snapshots and branching clears redo",
        fn () ->
          {
            let first = nb.run-lines(["set a = 2", "set b = a * 3"])
            let second = nb.set(first, "a", "4")
            let undone = nb.outcome-book(nb.undo(second))
            check.eq(
              nb.snapshot-text(nb.current(undone)),
              nb.snapshot-text(nb.current(first)),
              text.eq,
              text.show,
              "undo full snapshot",
            )
            let redone = nb.outcome-book(nb.redo(undone))
            check.eq(
              nb.book-text(redone),
              nb.book-text(second),
              text.eq,
              text.show,
              "redo full book",
            )
            let branch = nb.set(undone, "a", "5")
            check.eq(list.length(nb.redo-list(branch)), 0, int.eq, int.show, "new edit clears redo")
            check.true(bool.not(nb.accepted?(nb.redo(branch))), "redo unavailable after branch")
          },
      ),
      Case(
        "history retains twenty edits and failed operations consume none",
        fn () ->
          {
            let book =
              list.fold(
                list.range(0, 25),
                nb.empty(),
                fn (state, n) -> nb.set(state, "a", text.from-int(n)),
              )
            check.eq(list.length(nb.undo-list(book)), 20, int.eq, int.show, "bounded undo")
            let undone =
              list.fold(list.range(0, 20), book, fn (state, _) -> nb.outcome-book(nb.undo(state)))
            nb.check-value(undone, "a", "4")
            let failure = nb.undo(undone)
            check.true(bool.not(nb.accepted?(failure)), "old history dropped")
            check.eq(
              nb.book-text(nb.outcome-book(failure)),
              nb.book-text(undone),
              text.eq,
              text.show,
              "failed undo unchanged",
            )
            let restored =
              list.fold(list.range(0, 20), undone, fn (state, _) -> nb.outcome-book(nb.redo(state)))
            check.eq(
              nb.book-text(restored),
              nb.book-text(book),
              text.eq,
              text.show,
              "twenty redos restore book",
            )
          },
      ),
    ],
  )

-- Each generated seed selects eight transitions; compare after EVERY transition.
-- Coverage includes edge replacement, absent sources, arithmetic errors, invalid
-- edits, preview, history, and history branching. The reference has no cache.
nb.generated-step(
  seed,
  step,
) =
  {
    let choice = mod(add(mul(seed, add(step, 3)), mul(step, step)), 12)
    match choice {
      | 0 -> text.concat("set a = ", text.from-int(sub(mod(seed, 11), 5)))
      | 1 -> "unset a"
      | 2 -> "set b = a * 2"
      | 3 -> "set b = alternate + 1"
      | 4 -> text.concat("set alternate = ", text.from-int(mod(seed, 7)))
      | 5 -> "set c = b / a"
      | 6 -> "set a = c"
      | 7 -> "set b = 2 +"
      | 8 -> "undo"
      | 9 -> "redo"
      | 10 -> "whatif a = 100"
      | _ -> "set c = b + a"
    }
  }

nb.generated-tests =
  Group(
    "generated transitions versus fresh evaluation",
    [
      Prop(
        "bounded edit sequences",
        fn () ->
          {
            let seed = sample(UniformInt(0, 127))
            let initial = nb.run-lines(["set a = 1", "set b = a + 2", "set c = a + b"])
            let _ =
              list.fold(
                list.range(0, 8),
                initial,
                fn (
                  book,
                  step,
                ) ->
                  {
                    let next = nb.response-book(nb.execute(book, nb.generated-step(seed, step)))
                    nb.check-reference(next)
                    next
                  },
              )
            ()
          },
      ),
    ],
  )
