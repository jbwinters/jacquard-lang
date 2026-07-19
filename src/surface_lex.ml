(** Span-preserving lexer for canonical and recoverable `.jac` source.

    Dotted names stay one [Ident], [_] is an identifier token in both pattern and resume positions,
    and newlines remain tokens so the parser can apply D27 without indentation semantics. After
    lexical [jqd], a following braced byte region is captured as an inert [RawCandidate]. The parser
    decides whether that candidate occurs in a legal inversion production and only then invokes the
    bootstrap reader. *)

type raw_candidate = { source : string; content_span : Span.t; closed : bool }

type token =
  | Ident of string
  | Escaped of Surface_name.kind * string
  | HashRef of Hash.t * Surface_name.kind
  | GroupRef of int
  | Keyword of string
  | Literal of Kernel.lit
  | Comment of string
  | DocComment of string
  | LParen
  | RParen
  | LBrace
  | RBrace
  | LBracket
  | RBracket
  | Comma
  | Colon
  | Equal
  | Arrow
  | Bar
  | Pipe
  | Dot
  | Semi
  | Newline
  | RawCandidate of raw_candidate
  | Invalid of Diag.t
  | Eof

type located = { token : token; span : Span.t }
type recovery = { tokens : located list; diagnostics : Diag.t list }

let keywords =
  [
    "type";
    "effect";
    "once";
    "multi";
    "fn";
    "let";
    "rec";
    "match";
    "handle";
    "return";
    "resume";
    "quote";
    "unquote";
    "if";
    "then";
    "else";
    "as";
    "where";
    "forall";
    "jqd";
  ]

type state = {
  src : string;
  file : string;
  mutable off : int;
  mutable line : int;
  mutable col : int;
  mutable forall_pending : bool;
  mutable raw_pending : bool;
}

exception Bug_lex_error of Diag.t

let pos state = { Span.line = state.line; col = state.col; offset = state.off }
let span state start_pos = Span.make ~file:state.file ~start_pos ~end_pos:(pos state)

let diagnostic_summary = function
  | "E1210" -> "The source contains an unexpected surface character."
  | "E1211" -> "A surface identifier is malformed."
  | "E1212" -> "A surface numeric literal is malformed or too large."
  | "E1213" -> "A surface string literal is not closed."
  | "E1214" -> "A surface string contains an invalid escape."
  | "E1215" -> "A kind-tagged escaped name is malformed."
  | "E1216" -> "A kind-tagged hash reference is malformed."
  | "E1217" -> "An internal group reference is malformed."
  | "E1218" -> "A surface string contains invalid UTF-8."
  | code -> raise (Diag.Bug_invalid_diagnostic ("unknown surface lexer code " ^ code))

let diagnostic_next_step = function
  | "E1210" -> "Remove the character or replace it with valid surface syntax."
  | "E1211" -> "Rewrite the identifier using the surface name grammar or a kind-tagged escape."
  | "E1212" -> "Rewrite the value as one valid supported integer or real literal."
  | "E1213" -> "Close the string with a double quote before the end of the line or file."
  | "E1214" -> "Replace the escape with one supported by surface strings."
  | "E1215" -> "Use a valid term, con, or op kind tag and close the escaped name."
  | "E1216" -> "Write a full lowercase hash followed by a valid reference-kind suffix."
  | "E1217" -> "Write the internal reference as #group followed by a non-negative index."
  | "E1218" -> "Replace the invalid bytes with valid UTF-8 text."
  | code -> raise (Diag.Bug_invalid_diagnostic ("unknown surface lexer code " ^ code))

let fail state start_pos code cause =
  raise
    (Bug_lex_error
       (Diag.error ~span:(span state start_pos) ~domain:Surface ~code
          ~summary:(diagnostic_summary code) ~cause ~next_step:(diagnostic_next_step code)
          ~contrast:None ()))

let peek state = if state.off < String.length state.src then Some state.src.[state.off] else None

let peek_at state distance =
  let offset = state.off + distance in
  if offset < String.length state.src then Some state.src.[offset] else None

let advance state =
  let char = state.src.[state.off] in
  state.off <- state.off + 1;
  if char = '\n' then begin
    state.line <- state.line + 1;
    state.col <- 1
  end
  else state.col <- state.col + 1;
  char

let restore state (position : Span.pos) =
  state.off <- position.offset;
  state.line <- position.line;
  state.col <- position.col

let rec skip_space state =
  match peek state with
  | Some (' ' | '\t' | '\r') ->
      ignore (advance state);
      skip_space state
  | _ -> ()

let located state start_pos token = { token; span = span state start_pos }
let is_digit char = char >= '0' && char <= '9'
let is_hex char = is_digit char || (char >= 'a' && char <= 'f') || (char >= 'A' && char <= 'F')

let is_atom_delimiter = function
  | ' ' | '\t' | '\r' | '\n' | '(' | ')' | '{' | '}' | '[' | ']' | ',' | ':' | ';' | '=' | '|' | '"'
  | '`' | '#' ->
      true
  | _ -> false

let read_atom state =
  let start = state.off in
  while
    match peek state with
    | Some '-' when peek_at state 1 = Some '>' -> false
    | Some char when not (is_atom_delimiter char) -> true
    | _ -> false
  do
    ignore (advance state)
  done;
  String.sub state.src start (state.off - start)

let read_comment state ~doc =
  let start_pos = pos state in
  ignore (advance state);
  ignore (advance state);
  if doc then ignore (advance state);
  let body_start = state.off in
  while match peek state with Some '\n' | None -> false | Some _ -> true do
    ignore (advance state)
  done;
  let body = String.sub state.src body_start (state.off - body_start) in
  located state start_pos (if doc then DocComment body else Comment body)

let hex_value = function
  | '0' .. '9' as char -> Char.code char - Char.code '0'
  | 'a' .. 'f' as char -> Char.code char - Char.code 'a' + 10
  | 'A' .. 'F' as char -> Char.code char - Char.code 'A' + 10
  | _ -> invalid_arg "hex_value"

let utf8_width source offset =
  let length = String.length source in
  let byte index = if index < length then Char.code source.[index] else -1 in
  let continuation index = index < length && byte index land 0xc0 = 0x80 in
  let first = byte offset in
  if first < 0x80 then Some 1
  else if first >= 0xc2 && first <= 0xdf && continuation (offset + 1) then Some 2
  else if first >= 0xe0 && first <= 0xef then
    let second = byte (offset + 1) in
    let second_ok =
      if first = 0xe0 then second >= 0xa0 && second <= 0xbf
      else if first = 0xed then second >= 0x80 && second <= 0x9f
      else second >= 0x80 && second <= 0xbf
    in
    if second_ok && continuation (offset + 2) then Some 3 else None
  else if first >= 0xf0 && first <= 0xf4 then
    let second = byte (offset + 1) in
    let second_ok =
      if first = 0xf0 then second >= 0x90 && second <= 0xbf
      else if first = 0xf4 then second >= 0x80 && second <= 0x8f
      else second >= 0x80 && second <= 0xbf
    in
    if second_ok && continuation (offset + 2) && continuation (offset + 3) then Some 4 else None
  else None

let read_string state =
  let start_pos = pos state in
  ignore (advance state);
  let buffer = Buffer.create 32 in
  let rec loop () =
    match peek state with
    | None -> fail state start_pos "E1213" "unterminated string literal"
    | Some '"' ->
        ignore (advance state);
        located state start_pos (Literal (Kernel.LText (Buffer.contents buffer)))
    | Some '\\' ->
        let escape_pos = pos state in
        ignore (advance state);
        (match peek state with
        | None -> fail state start_pos "E1213" "unterminated string escape"
        | Some (('\\' | '"') as char) ->
            Buffer.add_char buffer char;
            ignore (advance state)
        | Some 'n' ->
            Buffer.add_char buffer '\n';
            ignore (advance state)
        | Some 't' ->
            Buffer.add_char buffer '\t';
            ignore (advance state)
        | Some 'r' ->
            Buffer.add_char buffer '\r';
            ignore (advance state)
        | Some 'x' -> (
            ignore (advance state);
            match (peek state, peek_at state 1) with
            | Some high, Some low when is_hex high && is_hex low ->
                Buffer.add_char buffer (Char.chr ((hex_value high * 16) + hex_value low));
                ignore (advance state);
                ignore (advance state)
            | _ -> fail state escape_pos "E1214" "`\\x` must be followed by two hex digits")
        | Some char ->
            fail state escape_pos "E1214" (Printf.sprintf "invalid string escape `\\%c`" char));
        loop ()
    | Some char when Char.code char >= 0x80 -> (
        let scalar_pos = pos state in
        match utf8_width state.src state.off with
        | None ->
            ignore (advance state);
            fail state scalar_pos "E1218" "invalid UTF-8 scalar in string literal"
        | Some width ->
            for _ = 1 to width do
              Buffer.add_char buffer (advance state)
            done;
            loop ())
    | Some char ->
        Buffer.add_char buffer char;
        ignore (advance state);
        loop ()
  in
  loop ()

let read_escaped state =
  let start_pos = pos state in
  let start = state.off in
  ignore (advance state);
  while match peek state with Some '`' | None | Some '\n' -> false | Some _ -> true do
    ignore (advance state)
  done;
  match peek state with
  | Some '`' -> (
      ignore (advance state);
      let spelling = String.sub state.src start (state.off - start) in
      match Surface_name.decode_escaped spelling with
      | Some (kind, name) -> located state start_pos (Escaped (kind, name))
      | None -> fail state start_pos "E1215" "malformed kind-tagged escaped name")
  | _ -> fail state start_pos "E1215" "unterminated kind-tagged escaped name"

let kind_of_tag = function
  | "term" -> Some Surface_name.Term
  | "op" -> Some Surface_name.Op
  | "type" -> Some Surface_name.Type
  | "con" -> Some Surface_name.Con
  | "effect" -> Some Surface_name.Effect
  | _ -> None

let read_hash state =
  let start_pos = pos state in
  let start = state.off in
  let group_mode =
    state.off + 7 <= String.length state.src && String.sub state.src state.off 7 = "#group["
  in
  if group_mode then begin
    for _ = 1 to 7 do
      ignore (advance state)
    done;
    let digits_start = state.off in
    while match peek state with Some char when is_digit char -> true | _ -> false do
      ignore (advance state)
    done;
    let digits = String.sub state.src digits_start (state.off - digits_start) in
    let consume_bad_tail () =
      while
        match peek state with
        | Some ']' ->
            ignore (advance state);
            false
        | Some (' ' | '\t' | '\r' | '\n' | '(' | ')' | '{' | '}' | ',' | ';' | '=' | '|') | None ->
            false
        | Some _ -> true
      do
        ignore (advance state)
      done
    in
    match (digits, peek state) with
    | "", _ ->
        consume_bad_tail ();
        fail state start_pos "E1217" "#group requires one or more decimal digits"
    | _, Some ']' -> (
        ignore (advance state);
        match int_of_string_opt digits with
        | Some index -> located state start_pos (GroupRef index)
        | None -> fail state start_pos "E1217" "#group index does not fit in a native int")
    | _ ->
        consume_bad_tail ();
        fail state start_pos "E1217" "malformed #group[n] reference"
  end
  else begin
    ignore (advance state);
    while
      match peek state with
      | Some '-' when peek_at state 1 = Some '>' -> false
      | Some
          ( ' ' | '\t' | '\r' | '\n' | '(' | ')' | '{' | '}' | '[' | ']' | ',' | ';' | '=' | '|'
          | '"' | '`' )
      | None ->
          false
      | Some _ -> true
    do
      ignore (advance state)
    done;
    let spelling = String.sub state.src start (state.off - start) in
    match String.index_opt spelling ':' with
    | None -> fail state start_pos "E1216" "hash references require a kind suffix"
    | Some colon -> (
        let digest = String.sub spelling 1 (colon - 1) in
        let tag = String.sub spelling (colon + 1) (String.length spelling - colon - 1) in
        match (Hash.of_hex digest, kind_of_tag tag) with
        | Some hash, Some kind -> located state start_pos (HashRef (hash, kind))
        | _ -> fail state start_pos "E1216" "malformed kind-tagged hash reference")
  end

let read_number state =
  let start_pos = pos state in
  let spelling = read_atom state in
  let leading_plus_is_legal = spelling = "+inf.0" || spelling = "+nan.0" in
  if String.starts_with ~prefix:"+" spelling && not leading_plus_is_legal then
    fail state start_pos "E1212" "ordinary numeric literals cannot use a leading `+`";
  match Reader.classify_literal spelling with
  | Some (Form.Int value) -> located state start_pos (Literal (Kernel.LInt value))
  | Some (Form.Real value) -> located state start_pos (Literal (Kernel.LReal value))
  | _ -> fail state start_pos "E1212" (Printf.sprintf "malformed numeric literal `%s`" spelling)

let read_name state =
  let start_pos = pos state in
  let spelling = read_atom state in
  let spelling =
    let length = String.length spelling in
    (* Dotted names normally consume [.]. In [forall], split the terminating dot here so merged
       lexer diagnostics do not retain a stale E1211 for the parser's valid [e.] boundary. *)
    if state.forall_pending && length > 1 && spelling.[length - 1] = '.' then
      let name = String.sub spelling 0 (length - 1) in
      if Surface_name.valid_lower_name name then begin
        state.off <- state.off - 1;
        state.col <- state.col - 1;
        name
      end
      else spelling
    else spelling
  in
  if spelling = "_" then located state start_pos (Ident spelling)
  else if List.mem spelling keywords then located state start_pos (Keyword spelling)
  else if Surface_name.valid_lower_name spelling || Option.is_some (Surface_name.of_pascal spelling)
  then located state start_pos (Ident spelling)
  else fail state start_pos "E1211" (Printf.sprintf "malformed surface identifier `%s`" spelling)

let one state constructor =
  let start_pos = pos state in
  ignore (advance state);
  located state start_pos constructor

let read_raw_candidate state =
  let start_pos = pos state in
  ignore (advance state);
  let content_start = pos state in
  let content_offset = state.off in
  let parens = ref 0 in
  let in_string = ref false in
  let escaped = ref false in
  let in_comment = ref false in
  (* Structural recovery outranks a brace from an unterminated string. A string fallback is local
     to that string so balanced string contents cannot affect recovery at EOF. *)
  let structural_fallback = ref None in
  let string_fallback = ref None in
  let closed = ref false in
  let finished = ref false in
  let content_end = ref content_start in
  while not !finished do
    match peek state with
    | None ->
        (match (!structural_fallback, if !in_string then !string_fallback else None) with
        | Some (fallback_end, resume_at), _ ->
            content_end := fallback_end;
            restore state resume_at;
            closed := true
        | None, Some (fallback_end, resume_at) ->
            content_end := fallback_end;
            restore state resume_at;
            closed := true
        | None, None -> content_end := pos state);
        finished := true
    | Some char when !in_comment ->
        ignore (advance state);
        if char = '\n' then in_comment := false
    | Some char when !in_string ->
        let fallback_end =
          if char = '}' && Option.is_none !string_fallback then Some (pos state) else None
        in
        ignore (advance state);
        (match fallback_end with
        | Some fallback_end -> string_fallback := Some (fallback_end, pos state)
        | None -> ());
        if !escaped then escaped := false
        else if char = '\\' then escaped := true
        else if char = '"' then begin
          in_string := false;
          string_fallback := None
        end
    | Some '"' ->
        in_string := true;
        string_fallback := None;
        ignore (advance state)
    | Some ';' ->
        in_comment := true;
        ignore (advance state)
    | Some '(' ->
        incr parens;
        ignore (advance state)
    | Some ')' ->
        parens := max 0 (!parens - 1);
        ignore (advance state)
    | Some '}' ->
        let close_start = pos state in
        ignore (advance state);
        if !parens = 0 then begin
          content_end := close_start;
          closed := true;
          finished := true
        end
        else if Option.is_none !structural_fallback then
          structural_fallback := Some (close_start, pos state)
    | Some _ -> ignore (advance state)
  done;
  let source = String.sub state.src content_offset (!content_end.Span.offset - content_offset) in
  let content_span = Span.make ~file:state.file ~start_pos:content_start ~end_pos:!content_end in
  { token = RawCandidate { source; content_span; closed = !closed }; span = span state start_pos }

let next_regular state =
  match peek state with
  | None -> located state (pos state) Eof
  | Some '\n' -> one state Newline
  | Some ';' -> one state Semi
  | Some '(' -> one state LParen
  | Some ')' -> one state RParen
  | Some '{' -> one state LBrace
  | Some '}' -> one state RBrace
  | Some '[' -> one state LBracket
  | Some ']' -> one state RBracket
  | Some ',' -> one state Comma
  | Some ':' -> one state Colon
  | Some '=' -> one state Equal
  | Some '.' -> one state Dot
  | Some '|' when peek_at state 1 = Some '>' ->
      let start_pos = pos state in
      ignore (advance state);
      ignore (advance state);
      located state start_pos Pipe
  | Some '|' -> one state Bar
  | Some '-' when peek_at state 1 = Some '>' ->
      let start_pos = pos state in
      ignore (advance state);
      ignore (advance state);
      located state start_pos Arrow
  | Some '-' when peek_at state 1 = Some '-' && peek_at state 2 = Some '|' ->
      read_comment state ~doc:true
  | Some '-' when peek_at state 1 = Some '-' -> read_comment state ~doc:false
  | Some '"' -> read_string state
  | Some '`' -> read_escaped state
  | Some '#' -> read_hash state
  | Some ('0' .. '9' | '+' | '-') -> read_number state
  | Some ('a' .. 'z' | 'A' .. 'Z' | '_') -> read_name state
  | Some char ->
      let start_pos = pos state in
      ignore (advance state);
      fail state start_pos "E1210" (Printf.sprintf "unexpected surface character `%c`" char)

let update_context state ({ token; _ } as located) =
  state.raw_pending <-
    (match token with
    | Keyword "jqd" -> true
    | (Comment _ | DocComment _) when state.raw_pending -> true
    | _ -> false);
  state.forall_pending <-
    (match token with
    | Keyword "forall" -> true
    | Ident _
    | Escaped ((Surface_name.Tvar | Surface_name.Rvar), _)
    | Bar | Comment _ | DocComment _ | Newline
      when state.forall_pending ->
        true
    | _ -> false);
  located

let next state =
  skip_space state;
  if state.raw_pending then
    begin match peek state with
    | Some '{' -> update_context state (read_raw_candidate state)
    | Some '-' when peek_at state 1 = Some '-' -> update_context state (next_regular state)
    | _ -> update_context state (next_regular state)
    end
  else update_context state (next_regular state)

let initial_state ~file src =
  { src; file; off = 0; line = 1; col = 1; forall_pending = false; raw_pending = false }

(** [lex ~file source] tokenizes a complete source string and appends one [Eof] token. It stops at
    the first malformed token and returns a span-bearing diagnostic. *)
let lex ~file src : (located list, Diag.t list) result =
  let state = initial_state ~file src in
  let rec loop acc =
    let token = next state in
    match token.token with Eof -> Ok (List.rev (token :: acc)) | _ -> loop (token :: acc)
  in
  match loop [] with tokens -> tokens | exception Bug_lex_error diagnostic -> Error [ diagnostic ]

let resynchronize_string state start_pos ~after_offset =
  restore state start_pos;
  (match peek state with Some '"' -> ignore (advance state) | _ -> ());
  let rec seek_closing_quote () =
    match peek state with
    | None -> ()
    | Some '\n' when state.off >= after_offset -> ()
    | Some '"' when state.off >= after_offset -> ignore (advance state)
    | Some '\\' -> (
        ignore (advance state);
        match peek state with
        | None -> ()
        | Some '\n' when state.off >= after_offset -> ()
        | Some _ ->
            ignore (advance state);
            seek_closing_quote ())
    | Some _ ->
        ignore (advance state);
        seek_closing_quote ()
  in
  seek_closing_quote ()

let recover_after_error state start_pos start_char diagnostic =
  match start_char with
  | Some '"' ->
      let after_offset =
        if Diag.code diagnostic = Some "E1213" then start_pos.Span.offset
        else
          match Diag.span diagnostic with
          | Some error_span -> error_span.Span.end_pos.offset
          | None -> state.off
      in
      resynchronize_string state start_pos ~after_offset;
      if Diag.code diagnostic = Some "E1213" then
        Diag.with_span (Some (span state start_pos)) diagnostic
      else diagnostic
  | _ ->
      (if state.off = start_pos.Span.offset then
         match peek state with Some _ -> ignore (advance state) | None -> ());
      diagnostic

(** [lex_recover ~file source] tokenizes through lexical damage and appends [Eof]. Every malformed
    lexical unit becomes one in-order [Invalid] token carrying its diagnostic. String recovery stops
    at a closing quote or newline. This function is total for arbitrary byte strings; use {!lex} at
    strict build/check boundaries. *)
let lex_recover ~file src : recovery =
  let state = initial_state ~file src in
  let rec loop tokens diagnostics =
    skip_space state;
    let start_pos = pos state in
    let start_char = peek state in
    match next state with
    | { token = Eof; _ } as eof ->
        { tokens = List.rev (eof :: tokens); diagnostics = List.rev diagnostics }
    | token -> loop (token :: tokens) diagnostics
    | exception Bug_lex_error diagnostic ->
        let diagnostic = recover_after_error state start_pos start_char diagnostic in
        let invalid_span = Option.value (Diag.span diagnostic) ~default:(span state start_pos) in
        let invalid = { token = Invalid diagnostic; span = invalid_span } in
        ignore (update_context state invalid);
        loop (invalid :: tokens) (diagnostic :: diagnostics)
  in
  loop [] []

let kind_name = Surface_name.kind_tag

(** Stable token rendering used by lexer goldens and parser diagnostics. *)
let show_token = function
  | Ident name -> "ident(" ^ name ^ ")"
  | Escaped (kind, name) -> Printf.sprintf "escaped(%s:%s)" (kind_name kind) name
  | HashRef (hash, kind) -> Printf.sprintf "hash(%s:%s)" (Hash.to_hex hash) (kind_name kind)
  | GroupRef index -> Printf.sprintf "group-ref(%d)" index
  | Keyword name -> "keyword(" ^ name ^ ")"
  | Literal (Kernel.LInt value) -> "int(" ^ string_of_int value ^ ")"
  | Literal (Kernel.LReal value) -> "real(" ^ Printer.real_repr value ^ ")"
  | Literal (Kernel.LText value) -> Printf.sprintf "text(\"%s\")" (Printer.escape_text value)
  | Comment text -> "comment(" ^ text ^ ")"
  | DocComment text -> "doc-comment(" ^ text ^ ")"
  | LParen -> "("
  | RParen -> ")"
  | LBrace -> "{"
  | RBrace -> "}"
  | LBracket -> "["
  | RBracket -> "]"
  | Comma -> ","
  | Colon -> ":"
  | Equal -> "="
  | Arrow -> "->"
  | Bar -> "|"
  | Pipe -> "|>"
  | Dot -> "."
  | Semi -> ";"
  | Newline -> "newline"
  | RawCandidate { closed; _ } -> if closed then "raw-candidate" else "raw-candidate(unclosed)"
  | Invalid diagnostic -> "invalid(" ^ Option.value ~default:"uncoded" (Diag.code diagnostic) ^ ")"
  | Eof -> "eof"

let show located = Printf.sprintf "%s %s" (Span.to_string located.span) (show_token located.token)
