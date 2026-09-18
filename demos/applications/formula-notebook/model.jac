-- Immutable workbook state. Every cache lookup and recomputation is explicit.
type NbCell = | NbCell(name: Text, source: Text, expression: NbExpr, dependencies: List Text)

type NbEdge = | NbEdge(source: Text, dependent: Text)

type NbEntry = | NbEntry(name: Text, value: NbValue)

type NbSnapshot =
  | NbSnapshot(
      cells: List NbCell,
      reverse: List NbEdge,
      cache: List NbEntry,
      hits: Int,
      computed: Int,
    )

type NbBook = | NbBook(current: NbSnapshot, undo: List NbSnapshot, redo: List NbSnapshot)

type NbEdit = | NbSet Text Text | NbUnset Text

type NbChange = | NbAccepted NbSnapshot | NbRejected Text

type NbOutcome = | NbOutcome(book: NbBook, accepted: Bool, message: Text)

nb.cell-name(cell) = match cell {
                       | NbCell(name: name) -> name}

nb.cell-source(cell) = match cell {
                         | NbCell(source: source) -> source}

nb.cell-expr(cell) = match cell {
                       | NbCell(expression: expression) -> expression}

nb.cell-deps(cell) = match cell {
                       | NbCell(dependencies: dependencies) -> dependencies}

nb.cells(snapshot) = match snapshot {
                       | NbSnapshot(cells: cells) -> cells}

nb.edges(snapshot) = match snapshot {
                       | NbSnapshot(reverse: edges) -> edges}

nb.cache(snapshot) = match snapshot {
                       | NbSnapshot(cache: cache) -> cache}

nb.hits(snapshot) = match snapshot {
                      | NbSnapshot(hits: hits) -> hits}

nb.computed(snapshot) = match snapshot {
                          | NbSnapshot(computed: computed) -> computed}

nb.current(book) = match book {
                     | NbBook(current: current) -> current}

nb.undo-list(book) = match book {
                       | NbBook(undo: undo) -> undo}

nb.redo-list(book) = match book {
                       | NbBook(redo: redo) -> redo}

nb.outcome-book(outcome) = match outcome {
                             | NbOutcome(book: book) -> book}

nb.accepted?(outcome) = match outcome {
                          | NbOutcome(accepted: accepted) -> accepted}

nb.outcome-message(outcome) = match outcome {
                                | NbOutcome(message: message) -> message}

nb.empty-snapshot() = NbSnapshot([], [], [], 0, 0)

nb.empty() = NbBook(nb.empty-snapshot(), [], [])

nb.find-cell(cells, name) = list.find(cells, fn (cell) -> text.eq?(nb.cell-name(cell), name))

nb.find-entry(
  cache,
  name,
) =
  list.find(cache, fn (entry) -> match entry {
                                   | NbEntry(key, _) -> text.eq?(key, name)})

nb.reverse-edges(
  cells,
) =
  list.fold(
    cells,
    [],
    fn (
      edges,
      cell,
    ) ->
      list.append(
        edges,
        list.map(nb.cell-deps(cell), fn (dependency) -> NbEdge(dependency, nb.cell-name(cell))),
      ),
  )

nb.dependents(
  edges,
  name,
) =
  list.fold(
    edges,
    [],
    fn (
      names,
      edge,
    ) ->
      match edge {
        | NbEdge(source, dependent) ->
          if text.eq?(source, name) then Cons(dependent, names) else names
      },
  )

nb.affected(
  edges,
  todo,
  seen,
) =
  match todo {
    | Nil -> seen
    | Cons(name, rest) ->
      if nb.has(seen, name) then nb.affected(edges, rest, seen)
      else nb.affected(edges, list.append(nb.dependents(edges, name), rest), Cons(name, seen))
  }

-- Follow the edited cell's outgoing edges. Previously accepted graphs are acyclic.
nb.cycle-walk(
  cells,
  name,
  path,
  finished,
) =
  if nb.has(path, name) then (Some(list.append(path, [name])), finished)
  else if nb.has(finished, name) then (None, finished)
  else {
         let found = nb.find-cell(cells, name)
         match found {
           | None -> (None, Cons(name, finished))
           | Some(cell) -> {
             let (cycle, visited) =
               list.fold(
                 nb.cell-deps(cell),
                 (None, finished),
                 fn (
                   state,
                   dependency,
                 ) ->
                   {
                     let (answer, seen) = state
                     match answer {
                       | Some(_) -> state
                       | None -> nb.cycle-walk(cells, dependency, list.append(path, [name]), seen)
                     }
                   },
               )
             (cycle, Cons(name, visited))
           }
         }
  }

nb.cycle(cells, name, path) = {
                                let (cycle, _) = nb.cycle-walk(cells, name, path, [])
                                cycle}

-- Reference interpreter: no cache reads, writes, or invalidation helpers.
nb.fresh(
  expr,
  cells,
  origin,
) =
  match expr {
    | NbNumber(n) -> NbValue(n)
    | NbRef(name) -> {
      let found = nb.find-cell(cells, name)
      match found {
        | None -> NbError(name, "undefined cell")
        | Some(cell) -> nb.fresh(nb.cell-expr(cell), cells, name)
      }
    }
    | NbNeg(inner) -> nb.negate(nb.fresh(inner, cells, origin), origin)
    | NbBinary(op, left, right) ->
      nb.arithmetic(op, nb.fresh(left, cells, origin), nb.fresh(right, cells, origin), origin)
  }

nb.cached(
  expr,
  snapshot,
  origin,
) =
  match expr {
    | NbNumber(n) -> (NbValue(n), snapshot)
    | NbNeg(inner) -> {
      let (value, next) = nb.cached(inner, snapshot, origin)
      (nb.negate(value, origin), next)
    }
    | NbBinary(op, left, right) -> {
      let (a, first) = nb.cached(left, snapshot, origin)
      let (b, second) = nb.cached(right, first, origin)
      (nb.arithmetic(op, a, b, origin), second)
    }
    | NbRef(name) -> {
      let entry = nb.find-entry(nb.cache(snapshot), name)
      match entry {
        | Some(NbEntry(_, value)) ->
          (
            value,
            NbSnapshot(
              nb.cells(snapshot),
              nb.edges(snapshot),
              nb.cache(snapshot),
              add(nb.hits(snapshot), 1),
              nb.computed(snapshot),
            ),
          )
        | None -> {
          let cell = nb.find-cell(nb.cells(snapshot), name)
          let (value, next) =
            match cell {
              | None -> (NbError(name, "undefined cell"), snapshot)
              | Some(definition) -> nb.cached(nb.cell-expr(definition), snapshot, name)}
          (
            value,
            NbSnapshot(
              nb.cells(next),
              nb.edges(next),
              Cons(NbEntry(name, value), nb.cache(next)),
              nb.hits(next),
              add(nb.computed(next), 1),
            ),
          )
        }
      }
    }
  }

nb.recalculate(
  snapshot,
) =
  list.fold(
    nb.cells(snapshot),
    snapshot,
    fn (
      next,
      cell,
    ) ->
      {
        let (_, updated) = nb.cached(NbRef(nb.cell-name(cell)), next, nb.cell-name(cell))
        updated
      },
  )

nb.visible-value(
  snapshot,
  name,
) =
  match nb.find-entry(nb.cache(snapshot), name) {
    | Some(NbEntry(_, value)) -> value
    | None -> NbError(name, "undefined cell")
  }

nb.candidate(
  snapshot,
  name,
  cells,
) =
  {
    let cycle = nb.cycle(cells, name, [])
    match cycle {
      | Some(path) -> NbRejected(text.concat("cycle: ", nb.join(path, " -> ")))
      | None -> {
        let affected = nb.affected(nb.edges(snapshot), [name], [])
        let edges = nb.reverse-edges(cells)
        let live-names =
          nb.unique(
            list.append(
              list.map(cells, nb.cell-name),
              list.map(edges, fn (edge) -> match edge {
                                             | NbEdge(source: source) -> source}),
            ),
          )
        let cache =
          list.filter(
            nb.cache(snapshot),
            fn (
              entry,
            ) ->
              match entry {
                | NbEntry(key, _) ->
                  bool.and(bool.not(nb.has(affected, key)), nb.has(live-names, key))
              },
          )
        NbAccepted(
          nb.recalculate(NbSnapshot(cells, edges, cache, nb.hits(snapshot), nb.computed(snapshot))),
        )
      }
    }
  }

nb.edit(
  snapshot,
  edit,
) =
  match edit {
    | NbSet(name, source) ->
      if bool.not(nb.valid-name?(name)) then
        NbRejected("invalid cell name (ASCII letter, then letters/digits/underscore; max 24)")
      else {
             let parsed = nb.parse(source)
             match parsed {
               | NbBadFormula(diagnostic) -> NbRejected(nb.diagnostic-text(diagnostic))
               | NbFormula(expr) -> {
                 let exists = nb.find-cell(nb.cells(snapshot), name)
                 let new-cell = NbCell(name, text.trim(source), expr, nb.dependencies(expr))
                 match exists {
                   | None ->
                     if int.gte?(list.length(nb.cells(snapshot)), 40) then
                       NbRejected("workbook limit: 40 defined cells")
                     else nb.candidate(snapshot, name, list.append(nb.cells(snapshot), [new-cell]))
                   | Some(_) ->
                     nb.candidate(
                       snapshot,
                       name,
                       list.map(
                         nb.cells(snapshot),
                         fn (cell) -> if text.eq?(nb.cell-name(cell), name) then new-cell else cell,
                       ),
                     )
                 }
               }
             }
      }
    | NbUnset(name) -> {
      let exists = nb.find-cell(nb.cells(snapshot), name)
      match exists {
        | None -> NbRejected(text.concat("cannot unset undefined cell ", name))
        | Some(_) ->
          nb.candidate(
            snapshot,
            name,
            list.filter(
              nb.cells(snapshot),
              fn (cell) -> bool.not(text.eq?(nb.cell-name(cell), name)),
            ),
          )
      }
    }
  }

nb.commit(
  book,
  edit,
) =
  {
    let result = nb.edit(nb.current(book), edit)
    match result {
      | NbRejected(message) -> NbOutcome(book, False, message)
      | NbAccepted(snapshot) ->
        NbOutcome(
          NbBook(snapshot, list.take(Cons(nb.current(book), nb.undo-list(book)), 20), []),
          True,
          "edit accepted",
        )
    }
  }

nb.undo(
  book,
) =
  match nb.undo-list(book) {
    | Nil -> NbOutcome(book, False, "nothing to undo")
    | Cons(previous, remaining) ->
      NbOutcome(
        NbBook(previous, remaining, Cons(nb.current(book), nb.redo-list(book))),
        True,
        "undone",
      )
  }

nb.redo(
  book,
) =
  match nb.redo-list(book) {
    | Nil -> NbOutcome(book, False, "nothing to redo")
    | Cons(next, remaining) ->
      NbOutcome(NbBook(next, Cons(nb.current(book), nb.undo-list(book)), remaining), True, "redone")
  }
