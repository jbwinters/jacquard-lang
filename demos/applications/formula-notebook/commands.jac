type NbCommand =
  | NbEditCommand NbEdit
  | NbPreview Text Text
  | NbShow(name: Option Text)
  | NbWhy Text
  | NbUndo
  | NbRedo
  | NbHelp
  | NbQuit
  | NbNoop
  | NbInvalid Text

type NbResponse = | NbResponse(book: NbBook, output: Text, stop: Bool)

nb.response-book(response) = match response {
                               | NbResponse(book: book) -> book}

nb.response-output(response) = match response {
                                 | NbResponse(output: output) -> output}

nb.response-stop?(response) = match response {
                                | NbResponse(stop: stop) -> stop}

nb.whitespace?(c) = nb.has([" ", "\t", "\r", "\n"], c)

nb.assignment(
  rest,
  preview,
) =
  {
    let (before, after) = nb.span(nb.chars(rest), fn (c) -> bool.not(text.eq?(c, "=")), [])
    match after {
      | Nil -> NbInvalid("expected NAME = EXPR")
      | Cons(_, expression) -> {
        let name = text.trim(nb.join(before, ""))
        let source = text.trim(nb.join(expression, ""))
        if preview then NbPreview(name, source) else NbEditCommand(NbSet(name, source))
      }
    }
  }

nb.command(
  line,
) =
  if int.gt?(text.length(line), 8192) then NbInvalid("command exceeds 8192 characters")
  else {
         let (word, tail) =
           nb.span(nb.chars(text.trim(line)), fn (c) -> bool.not(nb.whitespace?(c)), [])
         let verb = nb.join(word, "")
         let argument = text.trim(nb.join(tail, ""))
         match (verb, text.empty?(argument)) {
           | ("", _) -> NbNoop
           | ("set", _) -> nb.assignment(argument, False)
           | ("whatif", _) -> nb.assignment(argument, True)
           | ("unset", _) ->
             if nb.valid-name?(argument) then NbEditCommand(NbUnset(argument))
             else NbInvalid("expected unset NAME")
           | ("show", True) -> NbShow(None)
           | ("show", False) ->
             if nb.valid-name?(argument) then NbShow(Some(argument))
             else NbInvalid("expected show [NAME]")
           | ("why", _) ->
             if nb.valid-name?(argument) then NbWhy(argument) else NbInvalid("expected why NAME")
           | ("undo", True) -> NbUndo
           | ("redo", True) -> NbRedo
           | ("help", True) -> NbHelp
           | ("quit", True) -> NbQuit
           | _ -> NbInvalid("unknown command or unexpected arguments; type help")
         }
  }

nb.stats(
  snapshot,
) =
  text.concat(
    text.concat(text.concat("cache totals: ", text.from-int(nb-snapshot.hits(snapshot))), " hits, "),
    text.concat(text.from-int(nb-snapshot.computed(snapshot)), " recomputations"),
  )

nb.delta-stats(
  before,
  after,
) =
  text.concat(
    text.concat(
      text.concat("recalculation: ", text.from-int(sub(nb-snapshot.hits(after), nb-snapshot.hits(before)))),
      " hits, ",
    ),
    text.concat(text.from-int(sub(nb-snapshot.computed(after), nb-snapshot.computed(before))), " recomputations"),
  )

nb.line(
  snapshot,
  name,
) =
  text.concat(text.concat(name, " = "), nb.value-text(nb.visible-value(snapshot, name)))

nb.definition-line(
  snapshot,
  cell,
) =
  text.concat(
    text.concat(nb.line(snapshot, nb-cell.name(cell)), "    ["),
    text.concat(nb-cell.source(cell), "]"),
  )

nb.show(
  snapshot,
  name,
) =
  match name {
    | Some(key) -> {
      let found = nb.find-cell(nb-snapshot.cells(snapshot), key)
      match found {
        | None -> nb.line(snapshot, key)
        | Some(cell) -> nb.definition-line(snapshot, cell)
      }
    }
    | None -> {
      let lines = list.map(nb-snapshot.cells(snapshot), fn (cell) -> nb.definition-line(snapshot, cell))
      text.concat(
        if list.empty?(lines) then "(empty workbook)\n"
        else text.concat(nb.join(lines, "\n"), "\n"),
        nb.stats(snapshot),
      )
    }
  }

nb.observed(
  snapshot,
  name,
) =
  match nb.find-cell(nb-snapshot.cells(snapshot), name) {
    | None -> "<unset>"
    | Some(_) -> nb.value-text(nb.visible-value(snapshot, name))
  }

nb.changes(
  before,
  after,
) =
  {
    let names =
      nb.unique(
        list.append(
          list.map(nb-snapshot.cells(after), nb-cell.name),
          list.map(nb-snapshot.cells(before), nb-cell.name),
        ),
      )
    let changed =
      list.filter(
        names,
        fn (name) -> bool.not(text.eq?(nb.observed(before, name), nb.observed(after, name))),
      )
    if list.empty?(changed) then "values unchanged"
    else nb.join(
           list.map(
             changed,
             fn (
               name,
             ) ->
               text.concat(
                 text.concat(text.concat(name, ": "), nb.observed(before, name)),
                 text.concat(" -> ", nb.observed(after, name)),
               ),
           ),
           "\n",
         )
  }

nb.all-dependencies(
  cells,
  todo,
  seen,
) =
  match todo {
    | Nil -> seen
    | Cons(name, rest) ->
      if nb.has(seen, name) then nb.all-dependencies(cells, rest, seen)
      else {
             let found = nb.find-cell(cells, name)
             let more = match found {
                          | None -> []
                          | Some(cell) -> nb-cell.dependencies(cell)}
             nb.all-dependencies(cells, list.append(rest, more), list.append(seen, [name]))
      }
  }

nb.why(
  snapshot,
  name,
) =
  {
    let found = nb.find-cell(nb-snapshot.cells(snapshot), name)
    match found {
      | None -> text.concat("undefined cell: ", name)
      | Some(cell) -> {
        let direct = nb-cell.dependencies(cell)
        let all = nb.all-dependencies(nb-snapshot.cells(snapshot), direct, [])
        let details = list.map(all, fn (dependency) -> nb.line(snapshot, dependency))
        text.concat(
          text.concat(
            nb.definition-line(snapshot, cell),
            text.concat(
              "\ndirect dependencies: ",
              if list.empty?(direct) then "(none)" else nb.join(direct, ", "),
            ),
          ),
          if list.empty?(details) then ""
          else text.concat("\ndependency values (transitive):\n", nb.join(details, "\n")),
        )
      }
    }
  }

nb.help() =
  "Formula notebook: integers, names, + - * /, unary -, parentheses.\nset NAME = EXPR | unset NAME | show [NAME] | why NAME\nwhatif NAME = EXPR | undo | redo | help | quit\nNames are case-sensitive; division truncates toward zero.\nLimits: 40 cells, 100 tokens / 4096 characters per formula, values +/-1000000.\nUndo retains 20 edits. Preview leaves the live workbook unchanged.\nAn empty input line or EOF exits; whitespace-only input is ignored."

nb.apply-outcome(
  before,
  outcome,
  edit?,
) =
  {
    let after = nb-outcome.book(outcome)
    let message = nb-outcome.message(outcome)
    let output =
      if nb-outcome.accepted(outcome) then
        {
          let changes = nb.changes(nb-book.current(before), nb-book.current(after))
          let statistics =
            if edit? then nb.delta-stats(nb-book.current(before), nb-book.current(after))
            else nb.stats(nb-book.current(after))
          text.concat(
            text.concat(text.concat(message, "\n"), changes),
            text.concat("\n", statistics),
          )}
      else text.concat("rejected: ", message)
    NbResponse(after, output, False)
  }

nb.process(
  book,
  command,
) =
  match command {
    | NbEditCommand(edit) -> nb.apply-outcome(book, nb.commit(book, edit), True)
    | NbUndo -> nb.apply-outcome(book, nb.undo(book), False)
    | NbRedo -> nb.apply-outcome(book, nb.redo(book), False)
    | NbPreview(name, source) -> {
      let result = nb.edit(nb-book.current(book), NbSet(name, source))
      let output =
        match result {
          | NbRejected(message) -> text.concat("preview rejected: ", message)
          | NbAccepted(snapshot) ->
            text.concat(
              text.concat(
                "preview (live state unchanged):\n",
                nb.changes(nb-book.current(book), snapshot),
              ),
              text.concat("\n", nb.delta-stats(nb-book.current(book), snapshot)),
            )}
      NbResponse(book, output, False)
    }
    | NbShow(name) -> NbResponse(book, nb.show(nb-book.current(book), name), False)
    | NbWhy(name) -> NbResponse(book, nb.why(nb-book.current(book), name), False)
    | NbHelp -> NbResponse(book, nb.help(), False)
    | NbQuit -> NbResponse(book, "bye", True)
    | NbNoop -> NbResponse(book, "", False)
    | NbInvalid(message) -> NbResponse(book, text.concat("rejected: ", message), False)
  }

nb.execute(book, line) = nb.process(book, nb.command(line))
