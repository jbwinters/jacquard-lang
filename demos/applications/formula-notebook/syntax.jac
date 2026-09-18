-- Formula syntax and bounded arithmetic. Source columns are one-based.
type NbOp = | NbAdd | NbSub | NbMul | NbDiv

type NbExpr = | NbNumber Int | NbRef Text | NbNeg NbExpr | NbBinary NbOp NbExpr NbExpr

type NbTokenKind = | NbInteger Int | NbName Text | NbOperator NbOp | NbLeft | NbRight

type NbToken = | NbToken(kind: NbTokenKind, column: Int)

type NbDiagnostic = | NbDiagnostic(column: Int, message: Text)

type NbLexed = | NbTokens(tokens: List NbToken, end-column: Int) | NbLexError NbDiagnostic

type NbParsed = | NbParsed(expr: NbExpr, remaining: List NbToken) | NbParseError NbDiagnostic

type NbFormula = | NbFormula NbExpr | NbBadFormula NbDiagnostic

type NbValue = | NbValue Int | NbError(origin: Text, reason: Text)

nb.any(
  xs,
  predicate,
) =
  match xs {
    | Nil -> False
    | Cons(x, rest) -> if predicate(x) then True else nb.any(rest, predicate)
  }

nb.has(xs, name) = nb.any(xs, fn (x) -> text.eq?(x, name))

nb.unique(
  xs,
) =
  list.fold(xs, [], fn (acc, x) -> if nb.has(acc, x) then acc else list.append(acc, [x]))

nb.join(
  xs,
  separator,
) =
  match xs {
    | Nil -> ""
    | Cons(first, rest) ->
      list.fold(rest, first, fn (acc, x) -> text.concat(text.concat(acc, separator), x))
  }

nb.chars(s) = text.split(s, "")

nb.letters = nb.chars("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")

nb.letter?(s) = nb.has(nb.letters, s)

nb.digits =
  [
    ("0", 0),
    ("1", 1),
    ("2", 2),
    ("3", 3),
    ("4", 4),
    ("5", 5),
    ("6", 6),
    ("7", 7),
    ("8", 8),
    ("9", 9),
  ]

nb.digit(
  s,
) =
  {
    let found = list.find(nb.digits, fn (pair) -> {
                                                    let (character, _) = pair
                                                    text.eq?(character, s)})
    match found {
      | None -> None
      | Some((_, n)) -> Some(n)
    }
  }

nb.name-tail?(
  s,
) =
  if nb.letter?(s) then True
  else if text.eq?(s, "_") then True
  else match nb.digit(s) {
         | Some(_) -> True
         | None -> False
  }

nb.every(
  xs,
  predicate,
) =
  match xs {
    | Nil -> True
    | Cons(x, rest) -> if predicate(x) then nb.every(rest, predicate) else False
  }

nb.valid-name?(
  name,
) =
  if int.gt?(text.length(name), 24) then False
  else match nb.chars(name) {
         | Nil -> False
         | Cons(first, rest) -> bool.and(nb.letter?(first), nb.every(rest, nb.name-tail?))
  }

nb.span(
  chars,
  predicate,
  taken,
) =
  match chars {
    | Cons(c, rest) ->
      if predicate(c) then nb.span(rest, predicate, Cons(c, taken))
      else (list.reverse(taken), chars)
    | Nil -> (list.reverse(taken), Nil)
  }

nb.literal(
  chars,
  value,
) =
  match chars {
    | Nil -> Some(value)
    | Cons(c, rest) ->
      match nb.digit(c) {
        | None -> None
        | Some(n) -> {
          let next = add(mul(value, 10), n)
          if int.gt?(next, 1000000) then None else nb.literal(rest, next)
        }}
  }

nb.lex-loop(
  chars,
  column,
  count,
  tokens,
) =
  match chars {
    | Nil -> NbTokens(list.reverse(tokens), column)
    | Cons(c, rest) ->
      if nb.has([" ", "\t", "\r", "\n"], c) then nb.lex-loop(rest, add(column, 1), count, tokens)
      else if int.gte?(count, 100) then
             NbLexError(NbDiagnostic(column, "formula exceeds 100 tokens"))
      else if nb.letter?(c) then
             {
               let (letters, remaining) = nb.span(chars, nb.name-tail?, [])
               let name = nb.join(letters, "")
               if int.gt?(list.length(letters), 24) then
                 NbLexError(NbDiagnostic(column, "name exceeds 24 characters"))
               else nb.lex-loop(
                      remaining,
                      add(column, list.length(letters)),
                      add(count, 1),
                      Cons(NbToken(NbName(name), column), tokens),
                    )}
      else {
             let digit = nb.digit(c)
             match digit {
               | Some(_) -> {
                 let (digits, remaining) =
                   nb.span(
                     chars,
                     fn (x) -> match nb.digit(x) {
                                 | Some(_) -> True
                                 | None -> False},
                     [],
                   )
                 let number = nb.literal(digits, 0)
                 match number {
                   | None -> NbLexError(NbDiagnostic(column, "literal exceeds 1000000"))
                   | Some(n) ->
                     nb.lex-loop(
                       remaining,
                       add(column, list.length(digits)),
                       add(count, 1),
                       Cons(NbToken(NbInteger(n), column), tokens),
                     )
                 }
               }
               | None -> {
                 let kind =
                   if text.eq?(c, "+") then Some(NbOperator(NbAdd))
                   else if text.eq?(c, "-") then Some(NbOperator(NbSub))
                   else if text.eq?(c, "*") then Some(NbOperator(NbMul))
                   else if text.eq?(c, "/") then Some(NbOperator(NbDiv))
                   else if text.eq?(c, "(") then Some(NbLeft)
                   else if text.eq?(c, ")") then Some(NbRight)
                   else None
                 match kind {
                   | None ->
                     NbLexError(NbDiagnostic(column, text.concat("unexpected character ", c)))
                   | Some(k) ->
                     nb.lex-loop(
                       rest,
                       add(column, 1),
                       add(count, 1),
                       Cons(NbToken(k, column), tokens),
                     )
                 }
               }
             }
      }
  }

nb.precedence(op) = match op {
                      | NbAdd -> 1
                      | NbSub -> 1
                      | NbMul -> 2
                      | NbDiv -> 2}

nb.parse-at(
  tokens,
  minimum,
  end-column,
) =
  {
    let prefix =
      match tokens {
        | Nil -> NbParseError(NbDiagnostic(end-column, "expected a number, name, or parenthesis"))
        | Cons(NbToken(kind, column), rest) ->
          match kind {
            | NbInteger(n) -> NbParsed(NbNumber(n), rest)
            | NbName(name) -> NbParsed(NbRef(name), rest)
            | NbOperator(NbSub) -> {
              let parsed = nb.parse-at(rest, 3, end-column)
              match parsed {
                | NbParseError(e) -> NbParseError(e)
                | NbParsed(expr, remaining) -> NbParsed(NbNeg(expr), remaining)
              }
            }
            | NbLeft -> {
              let parsed = nb.parse-at(rest, 1, end-column)
              match parsed {
                | NbParseError(e) -> NbParseError(e)
                | NbParsed(expr, remaining) ->
                  match remaining {
                    | Cons(NbToken(NbRight, _), more) -> NbParsed(expr, more)
                    | Cons(NbToken(_, at), _) ->
                      NbParseError(NbDiagnostic(at, "expected closing parenthesis"))
                    | Nil -> NbParseError(NbDiagnostic(end-column, "expected closing parenthesis"))}
              }
            }
            | _ -> NbParseError(NbDiagnostic(column, "expected a number, name, or parenthesis"))}}
    let rec suffix(
      left,
      remaining,
    ) =
      match remaining {
        | Cons(NbToken(NbOperator(op), _), more) ->
          if int.lt?(nb.precedence(op), minimum) then NbParsed(left, remaining)
          else {
                 let right = nb.parse-at(more, add(nb.precedence(op), 1), end-column)
                 match right {
                   | NbParseError(e) -> NbParseError(e)
                   | NbParsed(expr, tail) -> suffix(NbBinary(op, left, expr), tail)
                 }
          }
        | _ -> NbParsed(left, remaining)
      }
    match prefix {
      | NbParseError(e) -> NbParseError(e)
      | NbParsed(expr, rest) -> suffix(expr, rest)
    }
  }

nb.parse(
  source,
) =
  if int.gt?(text.length(source), 4096) then
    NbBadFormula(NbDiagnostic(4097, "formula exceeds 4096 characters"))
  else {
         let lexed = nb.lex-loop(nb.chars(source), 1, 0, [])
         match lexed {
           | NbLexError(e) -> NbBadFormula(e)
           | NbTokens(tokens, end-column) -> {
             let parsed = nb.parse-at(tokens, 1, end-column)
             match parsed {
               | NbParseError(e) -> NbBadFormula(e)
               | NbParsed(expr, Nil) -> NbFormula(expr)
               | NbParsed(_, Cons(NbToken(_, column), _)) ->
                 NbBadFormula(NbDiagnostic(column, "unexpected token after expression"))
             }
           }
         }
  }

nb.dependencies(
  expr,
) =
  match expr {
    | NbNumber(_) -> []
    | NbRef(name) -> [name]
    | NbNeg(inner) -> nb.dependencies(inner)
    | NbBinary(_, left, right) ->
      nb.unique(list.append(nb.dependencies(left), nb.dependencies(right)))
  }

nb.bounded(
  n,
  origin,
) =
  if bool.or(int.lt?(n, -1000000), int.gt?(n, 1000000)) then
    NbError(origin, "result outside -1000000..1000000")
  else NbValue(n)

nb.negate(
  value,
  origin,
) =
  match value {
    | NbError(_, _) -> value
    | NbValue(n) -> nb.bounded(sub(0, n), origin)
  }

nb.arithmetic(
  op,
  left,
  right,
  origin,
) =
  match (left, right) {
    | (NbError(_, _), _) -> left
    | (_, NbError(_, _)) -> right
    | (NbValue(a), NbValue(b)) ->
      match op {
        | NbAdd -> nb.bounded(add(a, b), origin)
        | NbSub -> nb.bounded(sub(a, b), origin)
        | NbMul -> nb.bounded(mul(a, b), origin)
        | NbDiv ->
          if eq(b, 0) then NbError(origin, "division by zero") else nb.bounded(div(a, b), origin)}
  }

nb.value-text(
  value,
) =
  match value {
    | NbValue(n) -> text.from-int(n)
    | NbError(origin, reason) ->
      text.concat(text.concat(text.concat("ERROR [", origin), "]: "), reason)
  }

nb.diagnostic-text(
  diagnostic,
) =
  match diagnostic {
    | NbDiagnostic(column, message) ->
      text.concat(text.concat(text.concat("column ", text.from-int(column)), ": "), message)
  }
