(** Recovering recursive-descent parser for `.jac` surface syntax.

    Newlines remain significant except in parenthesized lists and after explicit continuation
    tokens. Recovery leaves span-bearing holes and synchronizes at item and delimiter boundaries. *)

(** [kernel_name_of_pascal] is the parser/resolver's D34 boundary for ordinary uppercase names.
    Kind-tagged escapes instead use {!Surface_name.decode_escaped}. *)
let kernel_name_of_pascal surface = Surface_name.of_pascal surface

type state = {
  source : string;
  tokens : Surface_lex.located array;
  mutable index : int;
  mutable limit : int option;
  mutable diagnostics : Diag.t list;
  mutable next_hole : int;
}

type parsed_type_atom = { ty : Surface_ast.ty; arrow_params : Surface_ast.ty list option }
type separators = { consumed : bool; semicolon : Surface_lex.located option }

let current state =
  let token = state.tokens.(state.index) in
  match state.limit with
  | Some limit when state.index >= limit -> { token with Surface_lex.token = Surface_lex.Eof }
  | Some _ | None -> token

let advance state =
  let token = current state in
  if token.Surface_lex.token <> Surface_lex.Eof then state.index <- state.index + 1;
  token

let meta_with_span span = Meta.with_span span Meta.empty

let recovery_meta id span =
  Meta.empty |> Meta.with_span span
  |> Meta.with_surface_form "recovery-hole"
  |> Meta.with_surface_hole (string_of_int id)

let hole_meta state span =
  let id = state.next_hole in
  state.next_hole <- id + 1;
  (id, recovery_meta id span)

let report_code state token code message =
  state.diagnostics <- Diag.error ~span:token.Surface_lex.span ~code message :: state.diagnostics

let report state token message = report_code state token "E1220" message
let token_description token = Surface_lex.show_token token.Surface_lex.token
let advance_recording_invalid state = advance state

let expr_hole state token =
  let id, meta = hole_meta state token.Surface_lex.span in
  Surface_ast.{ it = Hole id; meta }

let pat_hole state token =
  let id, meta = hole_meta state token.Surface_lex.span in
  Surface_ast.{ it = PHole id; meta }

let ty_hole state token =
  let id, meta = hole_meta state token.Surface_lex.span in
  Surface_ast.{ it = TyHole id; meta }

let top_hole state token =
  let id, meta = hole_meta state token.Surface_lex.span in
  Surface_ast.{ it = TopHole id; meta }

let rec skip_comments state =
  match (current state).Surface_lex.token with
  | Surface_lex.Comment _ | Surface_lex.DocComment _ ->
      ignore (advance state);
      skip_comments state
  | _ -> ()

let rec skip_list_space state =
  match (current state).Surface_lex.token with
  | Surface_lex.Comment _ | Surface_lex.DocComment _ | Surface_lex.Newline ->
      ignore (advance state);
      skip_list_space state
  | _ -> ()

let skip_continuation = skip_list_space

let consume_separators_info state =
  let consumed = ref false in
  let semicolon = ref None in
  skip_comments state;
  while
    match (current state).Surface_lex.token with
    | Surface_lex.Newline | Surface_lex.Semi -> true
    | _ -> false
  do
    consumed := true;
    let token = advance state in
    if token.Surface_lex.token = Surface_lex.Semi && Option.is_none !semicolon then
      semicolon := Some token;
    skip_comments state
  done;
  { consumed = !consumed; semicolon = !semicolon }

let consume_separators state = (consume_separators_info state).consumed

let is_item_sync = function
  | Surface_lex.Newline | Surface_lex.Semi | Surface_lex.RBrace | Surface_lex.Bar
  | Surface_lex.Invalid _ | Surface_lex.Eof ->
      true
  | _ -> false

let synchronize_item state =
  while not (is_item_sync (current state).Surface_lex.token) do
    ignore (advance state)
  done

let synchronize_paren state =
  while
    match (current state).Surface_lex.token with
    | Surface_lex.RParen | Surface_lex.RBrace | Surface_lex.Bar | Surface_lex.Eof -> false
    | _ -> true
  do
    ignore (advance_recording_invalid state)
  done

let projected_name name =
  match kernel_name_of_pascal name with Some kernel -> kernel | None -> name

let forall_name_before_dot state token =
  let span = token.Surface_lex.span in
  let length = span.Span.end_pos.offset - span.start_pos.offset in
  if length < 2 || span.end_pos.offset > String.length state.source then None
  else
    let spelling = String.sub state.source span.start_pos.offset length in
    if spelling.[length - 1] <> '.' then None
    else
      let name = String.sub spelling 0 (length - 1) in
      if Surface_name.valid_lower_name name then Some name else None

let span_between first last = Span.merge first.Surface_lex.span last.Surface_lex.span

let span_from_meta left right =
  match (Meta.span left, Meta.span right) with
  | Some left, Some right -> Some (Span.merge left right)
  | Some span, None | None, Some span -> Some span
  | None, None -> None

let merged_meta left right =
  match span_from_meta left right with Some span -> meta_with_span span | None -> left

let meta_from_token_to_meta token meta =
  match Meta.span meta with
  | Some span -> meta_with_span (Span.merge token.Surface_lex.span span)
  | None -> meta_with_span token.span

let shift_raw_pos base (position : Span.pos) =
  {
    Span.line = base.Span.line + position.line - 1;
    col = (if position.line = 1 then base.col + position.col - 1 else position.col);
    offset = base.offset + position.offset;
  }

let shift_raw_span content_span span =
  Span.make ~file:content_span.Span.file
    ~start_pos:(shift_raw_pos content_span.start_pos span.Span.start_pos)
    ~end_pos:(shift_raw_pos content_span.start_pos span.end_pos)

let shift_raw_diagnostic raw content_span (diagnostic : Diag.t) =
  let span =
    match diagnostic.span with
    | Some span -> Some (shift_raw_span content_span span)
    | None -> Some raw.Surface_lex.span
  in
  { diagnostic with Diag.span }

let rec shift_raw_form content_span (form : Form.t) =
  let meta =
    match Meta.span form.meta with
    | Some span -> Meta.with_span (shift_raw_span content_span span) form.meta
    | None -> form.meta
  in
  let args =
    List.map
      (function Form.F child -> Form.F (shift_raw_form content_span child) | scalar -> scalar)
      form.args
  in
  { form with Form.meta; args }

let parse_raw_candidate state raw (candidate : Surface_lex.raw_candidate) =
  let () =
    if not candidate.closed then
      let position = candidate.content_span.Span.end_pos in
      let span =
        Span.make ~file:candidate.content_span.file ~start_pos:position ~end_pos:position
      in
      state.diagnostics <-
        Diag.error ~span ~code:"E1221" "expected `}` before end of raw `jqd` form"
        :: state.diagnostics
  in
  match Reader.parse_one ~file:candidate.content_span.Span.file candidate.source with
  | Ok form when candidate.closed -> Some (shift_raw_form candidate.content_span form)
  | Ok _ -> None
  | Error diagnostics ->
      List.iter
        (fun diagnostic ->
          state.diagnostics <-
            shift_raw_diagnostic raw candidate.content_span diagnostic :: state.diagnostics)
        diagnostics;
      None

let expect state expected description =
  let token = current state in
  if token.Surface_lex.token = expected then Some (advance state)
  else begin
    report state token
      (Printf.sprintf "expected %s, found %s" description (token_description token));
    None
  end

let with_limit state limit f =
  let previous = state.limit in
  state.limit <- Some limit;
  Fun.protect ~finally:(fun () -> state.limit <- previous) f

let token_at state index =
  if index < Array.length state.tokens then state.tokens.(index)
  else state.tokens.(Array.length state.tokens - 1)

let rec index_after_comments state index =
  match (token_at state index).Surface_lex.token with
  | Surface_lex.Comment _ | Surface_lex.DocComment _ -> index_after_comments state (index + 1)
  | _ -> index

let rec index_after_layout state index =
  match (token_at state index).Surface_lex.token with
  | Surface_lex.Comment _ | Surface_lex.DocComment _ | Surface_lex.Newline | Surface_lex.Semi ->
      index_after_layout state (index + 1)
  | _ -> index

let term_name = function
  | Surface_lex.Ident name when Surface_name.valid_lower_name name -> Some name
  | Surface_lex.Escaped (Surface_name.Term, name) -> Some name
  | _ -> None

let equation_definition_ahead_at state start =
  match (token_at state (start + 1)).Surface_lex.token with
  | Surface_lex.LParen ->
      let rec find_closing index depth =
        match (token_at state index).Surface_lex.token with
        | Surface_lex.LParen -> find_closing (index + 1) (depth + 1)
        | Surface_lex.RParen ->
            if depth = 1 then
              let next = index_after_comments state (index + 1) in
              (token_at state next).Surface_lex.token = Surface_lex.Equal
            else find_closing (index + 1) (depth - 1)
        | (Surface_lex.Eof | Surface_lex.Newline) when depth = 0 -> false
        | Surface_lex.Eof -> false
        | _ -> find_closing (index + 1) depth
      in
      find_closing (start + 1) 0
  | _ -> false

let top_item_ahead state index =
  match (token_at state index).Surface_lex.token with
  | Surface_lex.Keyword ("type" | "effect" | "jqd") -> true
  | token -> (
      match term_name token with
      | None -> false
      | Some _ -> (
          let next = index_after_comments state (index + 1) in
          match (token_at state next).Surface_lex.token with
          | Surface_lex.Colon | Surface_lex.Equal -> true
          | _ -> equation_definition_ahead_at state index))

type arm_boundary_kind = Arm_delimiter | Arm_layout of Surface_lex.located | Arm_end
type arm_boundary = { boundary_index : int; boundary_kind : arm_boundary_kind }

let next_arm_boundary state =
  let upper = Option.value ~default:(Array.length state.tokens) state.limit in
  let fallback nested kind index =
    match nested with
    | Some boundary_index -> { boundary_index; boundary_kind = Arm_delimiter }
    | None -> { boundary_index = index; boundary_kind = kind }
  in
  let rec find index parens braces brackets nested =
    if index >= upper then fallback nested Arm_end upper
    else
      match state.tokens.(index).Surface_lex.token with
      | Surface_lex.Bar when parens = 0 && braces = 0 && brackets = 0 ->
          { boundary_index = index; boundary_kind = Arm_delimiter }
      | Surface_lex.Bar -> find (index + 1) parens braces brackets (Some index)
      | Surface_lex.RBrace when parens = 0 && braces = 0 && brackets = 0 ->
          { boundary_index = index; boundary_kind = Arm_delimiter }
      | Surface_lex.Eof -> fallback nested Arm_end index
      | (Surface_lex.Newline | Surface_lex.Semi) when parens = 0 && braces = 0 && brackets = 0 ->
          let next = index_after_layout state index in
          if next < upper && top_item_ahead state next then
            fallback nested (Arm_layout (token_at state next)) index
          else find (index + 1) parens braces brackets nested
      | Surface_lex.LParen -> find (index + 1) (parens + 1) braces brackets nested
      | Surface_lex.RParen -> find (index + 1) (max 0 (parens - 1)) braces brackets nested
      | Surface_lex.LBrace -> find (index + 1) parens (braces + 1) brackets nested
      | Surface_lex.RBrace -> find (index + 1) parens (max 0 (braces - 1)) brackets nested
      | Surface_lex.LBracket -> find (index + 1) parens braces (brackets + 1) nested
      | Surface_lex.RBracket -> find (index + 1) parens braces (max 0 (brackets - 1)) nested
      | _ -> find (index + 1) parens braces brackets nested
  in
  find state.index 0 0 0 None

let quote_boundary_after_layout state =
  let layout = state.index in
  let next = index_after_layout state layout in
  if next = layout then None
  else
    match state.limit with
    | Some limit when next >= limit ->
        let boundary = if limit > layout then limit else next in
        Some (token_at state boundary)
    | Some _ -> None
    | None when top_item_ahead state next -> Some (token_at state next)
    | None -> None

let starts_type_atom = function
  | Surface_lex.Ident _ | Surface_lex.LParen -> true
  | Surface_lex.Escaped ((Surface_name.Type | Surface_name.Tvar), _) -> true
  | Surface_lex.HashRef (_, Surface_name.Type) -> true
  | _ -> false

let rec parse_expr state ~allow_newlines = parse_pipe state ~allow_newlines

and parse_pipe state ~allow_newlines =
  (* SS.13 adds the [|>] loop here; keeping this layer now fixes precedence below it. *)
  parse_call state ~allow_newlines

and parse_call state ~allow_newlines =
  let fn : Surface_ast.expr = parse_primary state ~allow_newlines in
  let rec postfix (fn : Surface_ast.expr) : Surface_ast.expr =
    skip_comments state;
    match (current state).Surface_lex.token with
    | Surface_lex.LParen ->
        let opening = advance state in
        let args, closing = parse_expr_list state in
        let meta = meta_with_span (span_between opening closing) in
        let meta = merged_meta fn.Surface_ast.meta meta in
        postfix Surface_ast.{ it = Call (fn, args); meta }
    | _ -> fn
  in
  postfix fn

and parse_expr_list state =
  skip_list_space state;
  match (current state).Surface_lex.token with
  | Surface_lex.RParen -> ([], advance state)
  | _ ->
      let rec loop acc =
        let expression = parse_expr state ~allow_newlines:true in
        skip_list_space state;
        match (current state).Surface_lex.token with
        | Surface_lex.Comma ->
            ignore (advance state);
            skip_list_space state;
            if (current state).Surface_lex.token = Surface_lex.RParen then begin
              report state (current state) "calls do not permit a trailing comma";
              (List.rev (expression :: acc), advance state)
            end
            else loop (expression :: acc)
        | Surface_lex.RParen -> (List.rev (expression :: acc), advance state)
        | _ ->
            let token = current state in
            report state token
              (Printf.sprintf "expected `,` or `)`, found %s" (token_description token));
            synchronize_paren state;
            let closing =
              match (current state).Surface_lex.token with
              | Surface_lex.RParen -> advance state
              | _ -> current state
            in
            (List.rev (expression :: acc), closing)
      in
      loop []

and parse_primary state ~allow_newlines =
  if allow_newlines then skip_list_space state else skip_comments state;
  let token = current state in
  let meta = meta_with_span token.Surface_lex.span in
  match token.Surface_lex.token with
  | Surface_lex.Literal literal ->
      ignore (advance state);
      Surface_ast.{ it = Lit literal; meta }
  | Surface_lex.Ident "_" ->
      report state token "`_` is only valid in pattern position";
      ignore (advance state);
      expr_hole state token
  | Surface_lex.Ident name ->
      ignore (advance state);
      let projected = kernel_name_of_pascal name in
      let meta =
        match projected with Some _ -> Meta.with_surface_ref_kind "con" meta | None -> meta
      in
      Surface_ast.{ it = Name (Option.value ~default:name projected); meta }
  | Surface_lex.Escaped (((Surface_name.Term | Surface_name.Con | Surface_name.Op) as kind), name)
    ->
      ignore (advance state);
      let meta = Meta.with_surface_ref_kind (Surface_name.kind_tag kind) meta in
      Surface_ast.{ it = Name name; meta }
  | Surface_lex.HashRef (hash, Surface_name.Term) ->
      ignore (advance state);
      Surface_ast.{ it = HashRef (hash, Kernel.Term); meta }
  | Surface_lex.HashRef (hash, Surface_name.Con) ->
      ignore (advance state);
      Surface_ast.{ it = HashRef (hash, Kernel.Con); meta }
  | Surface_lex.HashRef (hash, Surface_name.Op) ->
      ignore (advance state);
      Surface_ast.{ it = HashRef (hash, Kernel.Op); meta }
  | Surface_lex.GroupRef index ->
      ignore (advance state);
      Surface_ast.{ it = GroupRef index; meta }
  | Surface_lex.LParen -> parse_paren_expr state (advance state)
  | Surface_lex.LBrace -> parse_block state (advance state)
  | Surface_lex.Keyword "fn" -> parse_fn state ~allow_newlines (advance state)
  | Surface_lex.Keyword "match" -> parse_match state ~allow_newlines (advance state)
  | Surface_lex.Keyword "handle" -> parse_handle state ~allow_newlines (advance state)
  | Surface_lex.Keyword "quote" -> parse_quote state (advance state)
  | Surface_lex.Keyword "unquote" -> parse_unquote state (advance state)
  | Surface_lex.Invalid _ ->
      ignore (advance state);
      expr_hole state token
  | _ ->
      report state token
        (Printf.sprintf "expected an expression, found %s" (token_description token));
      if token.Surface_lex.token <> Surface_lex.Eof then ignore (advance state);
      expr_hole state token

and parse_paren_expr state opening =
  skip_list_space state;
  match (current state).Surface_lex.token with
  | Surface_lex.RParen ->
      let closing = advance state in
      Surface_ast.{ it = Tuple []; meta = meta_with_span (span_between opening closing) }
  | _ -> (
      let first = parse_expr state ~allow_newlines:true in
      skip_list_space state;
      match (current state).Surface_lex.token with
      | Surface_lex.Colon ->
          ignore (advance state);
          skip_continuation state;
          let ty = parse_type state ~allow_newlines:true in
          skip_list_space state;
          let closing =
            match expect state Surface_lex.RParen "`)` after the annotation" with
            | Some token -> token
            | None -> current state
          in
          Surface_ast.{ it = Ann (first, ty); meta = meta_with_span (span_between opening closing) }
      | Surface_lex.Comma ->
          ignore (advance state);
          skip_list_space state;
          if (current state).Surface_lex.token = Surface_lex.RParen then
            let closing = advance state in
            Surface_ast.
              { it = Tuple [ first ]; meta = meta_with_span (span_between opening closing) }
          else
            let rec items acc =
              let item = parse_expr state ~allow_newlines:true in
              skip_list_space state;
              match (current state).Surface_lex.token with
              | Surface_lex.Comma ->
                  ignore (advance state);
                  skip_list_space state;
                  if (current state).Surface_lex.token = Surface_lex.RParen then begin
                    report state (current state) "multi-item tuples do not permit a trailing comma";
                    (List.rev (item :: acc), advance state)
                  end
                  else items (item :: acc)
              | Surface_lex.RParen -> (List.rev (item :: acc), advance state)
              | _ ->
                  let token = current state in
                  report state token
                    (Printf.sprintf "expected `,` or `)`, found %s" (token_description token));
                  synchronize_paren state;
                  let closing =
                    if (current state).Surface_lex.token = Surface_lex.RParen then advance state
                    else current state
                  in
                  (List.rev (item :: acc), closing)
            in
            let rest, closing = items [] in
            Surface_ast.
              { it = Tuple (first :: rest); meta = meta_with_span (span_between opening closing) }
      | Surface_lex.RParen ->
          let closing = advance state in
          { first with Surface_ast.meta = meta_with_span (span_between opening closing) }
      | _ ->
          let token = current state in
          report state token
            (Printf.sprintf "expected `:`, `,`, or `)`, found %s" (token_description token));
          synchronize_paren state;
          let closing =
            if (current state).Surface_lex.token = Surface_lex.RParen then advance state
            else current state
          in
          let hole = expr_hole state token in
          { hole with Surface_ast.meta = meta_with_span (span_between opening closing) })

and parse_fn state ~allow_newlines keyword =
  let params =
    match expect state Surface_lex.LParen "`(` after `fn`" with
    | Some opening -> fst (parse_pattern_list state opening)
    | None -> []
  in
  let arrow = expect state Surface_lex.Arrow "`->` after function parameters" in
  Option.iter (fun _ -> skip_continuation state) arrow;
  let body = parse_expr state ~allow_newlines in
  let meta =
    match Meta.span body.Surface_ast.meta with
    | Some body_span -> meta_with_span (Span.merge keyword.Surface_lex.span body_span)
    | None -> meta_with_span keyword.span
  in
  Surface_ast.{ it = Fn (params, body); meta }

and parse_pattern_list state _opening =
  skip_list_space state;
  match (current state).Surface_lex.token with
  | Surface_lex.RParen ->
      let closing = advance state in
      ([], closing)
  | _ ->
      let rec loop acc =
        let pattern = parse_pattern state ~allow_newlines:true in
        skip_list_space state;
        match (current state).Surface_lex.token with
        | Surface_lex.Comma ->
            ignore (advance state);
            skip_list_space state;
            if (current state).Surface_lex.token = Surface_lex.RParen then begin
              report state (current state) "pattern lists do not permit a trailing comma";
              let closing = advance state in
              (List.rev (pattern :: acc), closing)
            end
            else loop (pattern :: acc)
        | Surface_lex.RParen ->
            let closing = advance state in
            (List.rev (pattern :: acc), closing)
        | Surface_lex.Bar | Surface_lex.RBrace | Surface_lex.Eof ->
            let closing = current state in
            report state closing "expected `)` to close the pattern list";
            (List.rev (pattern :: acc), closing)
        | _ ->
            let token = current state in
            report state token
              (Printf.sprintf "expected `,` or `)`, found %s" (token_description token));
            synchronize_paren state;
            let closing =
              if (current state).Surface_lex.token = Surface_lex.RParen then advance state
              else current state
            in
            (List.rev (pattern :: acc), closing)
      in
      loop []

and parse_pattern state ~allow_newlines =
  if allow_newlines then skip_list_space state else skip_comments state;
  let atom = parse_pattern_atom state ~allow_newlines in
  if allow_newlines then skip_list_space state else skip_comments state;
  match (current state).Surface_lex.token with
  | Surface_lex.Keyword "as" ->
      ignore (advance state);
      if allow_newlines then skip_list_space state else skip_comments state;
      let binder_token = current state in
      let binder =
        match binder_token.Surface_lex.token with
        | Surface_lex.Ident name when Surface_name.valid_lower_name name ->
            ignore (advance state);
            Some name
        | Surface_lex.Escaped (Surface_name.Term, name) ->
            ignore (advance state);
            Some name
        | _ ->
            report state binder_token
              (Printf.sprintf "expected a lowercase or `term`-escaped binder after `as`, found %s"
                 (token_description binder_token));
            (match binder_token.Surface_lex.token with
            | Surface_lex.Bar | Surface_lex.RBrace | Surface_lex.RParen | Surface_lex.Arrow
            | Surface_lex.Eof ->
                ()
            | _ -> ignore (advance_recording_invalid state));
            None
      in
      let pattern =
        match binder with
        | Some name ->
            Surface_ast.
              { it = PAs (atom, name); meta = meta_from_token_to_meta binder_token atom.meta }
        | None -> pat_hole state binder_token
      in
      if allow_newlines then skip_list_space state else skip_comments state;
      if (current state).Surface_lex.token = Surface_lex.Keyword "as" then begin
        let chained = advance state in
        report state chained
          "an `as` pattern permits one binder; nest another pattern instead of chaining `as`";
        if allow_newlines then skip_list_space state else skip_comments state;
        match (current state).Surface_lex.token with
        | Surface_lex.Ident name when Surface_name.valid_lower_name name -> ignore (advance state)
        | Surface_lex.Escaped (Surface_name.Term, _) -> ignore (advance state)
        | _ -> ()
      end;
      pattern
  | _ -> atom

and parse_pattern_atom state ~allow_newlines:_ =
  let token = current state in
  let meta = meta_with_span token.Surface_lex.span in
  match token.Surface_lex.token with
  | Surface_lex.Ident "_" ->
      ignore (advance state);
      Surface_ast.{ it = PWild; meta }
  | Surface_lex.Ident name when Surface_name.valid_lower_name name ->
      ignore (advance state);
      Surface_ast.{ it = PBind name; meta }
  | Surface_lex.Escaped (Surface_name.Term, name) ->
      ignore (advance state);
      Surface_ast.{ it = PBind name; meta }
  | Surface_lex.Literal literal ->
      ignore (advance state);
      Surface_ast.{ it = PLit literal; meta }
  | Surface_lex.Ident name -> (
      match kernel_name_of_pascal name with
      | Some name -> parse_constructor_pattern state token meta (Surface_ast.Named name)
      | None ->
          report state token "expected a lowercase binder or PascalCase constructor pattern";
          ignore (advance state);
          pat_hole state token)
  | Surface_lex.Escaped (Surface_name.Con, name) ->
      parse_constructor_pattern state token meta (Surface_ast.Named name)
  | Surface_lex.HashRef (hash, Surface_name.Con) ->
      parse_constructor_pattern state token meta (Surface_ast.Hashed hash)
  | Surface_lex.LParen ->
      let opening = advance state in
      let items, closing = parse_pattern_list state opening in
      Surface_ast.{ it = PTuple items; meta = meta_with_span (span_between opening closing) }
  | Surface_lex.Invalid _ ->
      ignore (advance state);
      pat_hole state token
  | _ ->
      report state token (Printf.sprintf "expected a pattern, found %s" (token_description token));
      (match token.Surface_lex.token with
      | Surface_lex.Bar | Surface_lex.RBrace | Surface_lex.RParen | Surface_lex.Arrow
      | Surface_lex.Eof ->
          ()
      | _ -> ignore (advance_recording_invalid state));
      pat_hole state token

and parse_constructor_pattern state name_token name_meta constructor =
  ignore (advance state);
  match (current state).Surface_lex.token with
  | Surface_lex.LParen ->
      let opening = advance state in
      let args, closing = parse_pattern_list state opening in
      let meta = meta_with_span (Span.merge name_token.Surface_lex.span closing.span) in
      Surface_ast.{ it = PCon (constructor, args); meta }
  | _ -> Surface_ast.{ it = PCon (constructor, []); meta = name_meta }

and parse_match state ~allow_newlines keyword =
  let subject = parse_expr state ~allow_newlines in
  skip_comments state;
  match expect state Surface_lex.LBrace "`{` before the match arms" with
  | None ->
      Surface_ast.{ it = Match (subject, []); meta = meta_from_token_to_meta keyword subject.meta }
  | Some opening ->
      ignore (consume_separators state);
      let clauses = ref [] in
      let closing = ref opening in
      let finished = ref false in
      let parse_arm start =
        let clause, next_top = parse_match_arm state start in
        clauses := clause :: !clauses;
        match next_top with
        | None -> ignore (consume_separators state)
        | Some next_top ->
            report_code state next_top "E1221" "expected `}` before the next top-level item";
            closing := current state;
            finished := true
      in
      while not !finished do
        let token = current state in
        match token.Surface_lex.token with
        | Surface_lex.RBrace ->
            if !clauses = [] then report state token "a `match` requires at least one arm";
            closing := advance state;
            finished := true
        | Surface_lex.Eof ->
            report_code state token "E1221" "expected `}` before end of match";
            closing := token;
            finished := true
        | Surface_lex.Bar ->
            let bar = advance state in
            parse_arm bar
        | _ ->
            report state token "match arms must begin with `|`";
            parse_arm token
      done;
      Surface_ast.
        {
          it = Match (subject, List.rev !clauses);
          meta = meta_with_span (span_between keyword !closing);
        }

and parse_match_arm state start =
  let pattern_token = current state in
  let pattern =
    match pattern_token.Surface_lex.token with
    | Surface_lex.Arrow | Surface_lex.Bar | Surface_lex.RBrace | Surface_lex.Eof ->
        report state pattern_token "expected a pattern after `|`";
        pat_hole state pattern_token
    | _ -> parse_pattern state ~allow_newlines:false
  in
  skip_comments state;
  match expect state Surface_lex.Arrow "`->` after the match pattern" with
  | None -> (
      let boundary = next_arm_boundary state in
      let body_token = current state in
      state.index <- boundary.boundary_index;
      let body = expr_hole state body_token in
      ( Surface_ast.
          { cpattern = pattern; cbody = body; cmeta = meta_from_token_to_meta start body.meta },
        match boundary.boundary_kind with Arm_layout top -> Some top | _ -> None ))
  | Some _ ->
      skip_continuation state;
      let body_token = current state in
      let body, next_top =
        match body_token.Surface_lex.token with
        | Surface_lex.Bar | Surface_lex.RBrace | Surface_lex.Eof ->
            report state body_token "expected an expression after `->`";
            (expr_hole state body_token, None)
        | _ ->
            let boundary = next_arm_boundary state in
            let body =
              with_limit state boundary.boundary_index (fun () ->
                  parse_expr state ~allow_newlines:false)
            in
            (match boundary.boundary_kind with
            | Arm_layout _ -> ()
            | Arm_delimiter | Arm_end -> ignore (consume_separators state));
            if state.index < boundary.boundary_index then
              begin match (current state).Surface_lex.token with
              | Surface_lex.Bar | Surface_lex.RBrace -> ()
              | _ ->
                  report state (current state) "expected `|` or `}` after the match arm body";
                  state.index <- boundary.boundary_index
              end;
            let next_top =
              match boundary.boundary_kind with
              | Arm_layout top when state.index >= boundary.boundary_index -> Some top
              | Arm_layout _ | Arm_delimiter | Arm_end -> None
            in
            (body, next_top)
      in
      ( Surface_ast.
          { cpattern = pattern; cbody = body; cmeta = meta_from_token_to_meta start body.meta },
        next_top )

and atomic_handle_start = function
  | Surface_lex.Literal _ | Surface_lex.Ident _ | Surface_lex.GroupRef _ -> true
  | Surface_lex.Escaped ((Surface_name.Term | Surface_name.Con | Surface_name.Op), _) -> true
  | Surface_lex.HashRef (_, (Surface_name.Term | Surface_name.Con | Surface_name.Op)) -> true
  | _ -> false

and atomic_handle_body (expr : Surface_ast.expr) =
  match expr.it with
  | Surface_ast.Lit _ | Surface_ast.Name _ | Surface_ast.HashRef _ -> true
  | Surface_ast.Call (head, _) -> atomic_handle_call_head head
  | _ -> false

and atomic_handle_call_head (expr : Surface_ast.expr) =
  match expr.it with
  | Surface_ast.Name _ | Surface_ast.HashRef _ -> true
  | Surface_ast.Call (head, _) -> atomic_handle_call_head head
  | _ -> false

and missing_return_clause state token =
  report_code state token "E0212" "`handle` needs exactly one `return` clause";
  let rbinder = pat_hole state token in
  let rbody = expr_hole state token in
  Surface_ast.{ rbinder; rbody; rmeta = meta_with_span token.Surface_lex.span }

and parse_handler_body state ~allow_newlines =
  let start = current state in
  match start.Surface_lex.token with
  | Surface_lex.LBrace -> parse_block state (advance state)
  | _ ->
      let body = parse_expr state ~allow_newlines in
      if (not (atomic_handle_start start.token)) || not (atomic_handle_body body) then
        report_code state start "E1226"
          "non-atomic `handle` bodies require an explicit `{ body }` block";
      body

and parse_handler_clause_body state _start =
  match expect state Surface_lex.Arrow "`->` before the handler clause body" with
  | None -> (
      let boundary = next_arm_boundary state in
      let body_token = current state in
      state.index <- boundary.boundary_index;
      let body = expr_hole state body_token in
      (body, match boundary.boundary_kind with Arm_layout top -> Some top | _ -> None))
  | Some _ -> (
      skip_continuation state;
      let body_token = current state in
      match body_token.Surface_lex.token with
      | Surface_lex.Bar | Surface_lex.RBrace | Surface_lex.Eof ->
          report state body_token "expected an expression after `->`";
          (expr_hole state body_token, None)
      | _ ->
          let boundary = next_arm_boundary state in
          let body =
            with_limit state boundary.boundary_index (fun () ->
                parse_expr state ~allow_newlines:false)
          in
          (match boundary.boundary_kind with
          | Arm_layout _ -> ()
          | Arm_delimiter | Arm_end -> ignore (consume_separators state));
          if state.index < boundary.boundary_index then
            begin match (current state).Surface_lex.token with
            | Surface_lex.Bar | Surface_lex.RBrace -> ()
            | _ ->
                report state (current state) "expected `|` or `}` after the handler clause body";
                state.index <- boundary.boundary_index
            end;
          let next_top =
            match boundary.boundary_kind with
            | Arm_layout top when state.index >= boundary.boundary_index -> Some top
            | Arm_layout _ | Arm_delimiter | Arm_end -> None
          in
          (body, next_top))

and parse_return_clause state start =
  let pattern_token = current state in
  let rbinder =
    match pattern_token.Surface_lex.token with
    | Surface_lex.Arrow | Surface_lex.Bar | Surface_lex.RBrace | Surface_lex.Eof ->
        report state pattern_token "expected a pattern after `return`";
        pat_hole state pattern_token
    | _ -> parse_pattern state ~allow_newlines:false
  in
  skip_comments state;
  let rbody, next_top = parse_handler_clause_body state start in
  (Surface_ast.{ rbinder; rbody; rmeta = meta_from_token_to_meta start rbody.meta }, next_top)

and parse_operation_clause state start =
  let operation_token = current state in
  let operation =
    match operation_token.Surface_lex.token with
    | Surface_lex.Ident name when Surface_name.valid_lower_name name ->
        ignore (advance state);
        Surface_ast.Named name
    | Surface_lex.Escaped (Surface_name.Op, name) ->
        ignore (advance state);
        Surface_ast.Named name
    | Surface_lex.HashRef (hash, Surface_name.Op) ->
        ignore (advance state);
        Surface_ast.Hashed hash
    | _ ->
        report_code state operation_token "E1226"
          (Printf.sprintf "expected an operation name after `|`, found %s"
             (token_description operation_token));
        (match operation_token.Surface_lex.token with
        | Surface_lex.Bar | Surface_lex.RBrace | Surface_lex.Eof -> ()
        | _ -> ignore (advance_recording_invalid state));
        Surface_ast.Named "__surface_hole"
  in
  let params =
    match expect state Surface_lex.LParen "`(` after the operation name" with
    | Some opening -> fst (parse_pattern_list state opening)
    | None -> []
  in
  skip_comments state;
  ignore (expect state (Surface_lex.Keyword "resume") "`resume` after operation parameters");
  skip_comments state;
  let resume_token = current state in
  let oresume =
    match resume_token.Surface_lex.token with
    | Surface_lex.Ident "_" ->
        ignore (advance state);
        "_"
    | Surface_lex.Ident name when Surface_name.valid_lower_name name ->
        ignore (advance state);
        name
    | Surface_lex.Escaped (Surface_name.Term, name) ->
        ignore (advance state);
        name
    | _ ->
        report_code state resume_token "E1226"
          (Printf.sprintf "expected a resume binder, found %s" (token_description resume_token));
        (match resume_token.Surface_lex.token with
        | Surface_lex.Arrow | Surface_lex.Bar | Surface_lex.RBrace | Surface_lex.Eof -> ()
        | _ -> ignore (advance_recording_invalid state));
        "__surface_hole"
  in
  skip_comments state;
  let obody, next_top = parse_handler_clause_body state start in
  let ometa = meta_from_token_to_meta start obody.meta |> Meta.with_surface_ref_kind "op" in
  (Surface_ast.{ operation; oparams = params; oresume; obody; ometa }, next_top)

and parse_handler_clause state start =
  let token = current state in
  match token.Surface_lex.token with
  | Surface_lex.Keyword "return" ->
      ignore (advance state);
      let clause, next_top = parse_return_clause state start in
      (`Return clause, next_top)
  | Surface_lex.Ident name when Surface_name.valid_lower_name name ->
      let clause, next_top = parse_operation_clause state start in
      (`Operation clause, next_top)
  | Surface_lex.Escaped (Surface_name.Op, _) | Surface_lex.HashRef (_, Surface_name.Op) ->
      let clause, next_top = parse_operation_clause state start in
      (`Operation clause, next_top)
  | _ -> (
      report_code state token "E1226"
        (Printf.sprintf "expected `return` or an operation clause, found %s"
           (token_description token));
      let boundary = next_arm_boundary state in
      state.index <- boundary.boundary_index;
      (`Malformed, match boundary.boundary_kind with Arm_layout top -> Some top | _ -> None))

and parse_handle state ~allow_newlines keyword =
  let body = parse_handler_body state ~allow_newlines in
  skip_comments state;
  let opening = expect state Surface_lex.LBrace "`{` before the handler clauses" in
  let returns = ref None in
  let ops = ref [] in
  let closing = ref keyword in
  let finished = ref false in
  let reported_order = ref false in
  (match opening with Some token -> closing := token | None -> finished := true);
  if not !finished then ignore (consume_separators state);
  while not !finished do
    let token = current state in
    match token.Surface_lex.token with
    | Surface_lex.RBrace ->
        closing := advance state;
        finished := true
    | Surface_lex.Eof ->
        report_code state token "E1221" "expected `}` before end of handler";
        closing := token;
        finished := true
    | Surface_lex.Bar -> (
        let bar = advance state in
        let clause, next_top = parse_handler_clause state bar in
        (match clause with
        | `Return clause -> (
            match !returns with
            | None -> returns := Some clause
            | Some _ -> report_code state bar "E0212" "`handle` has more than one `return` clause")
        | `Operation clause ->
            if Option.is_none !returns && not !reported_order then begin
              report_code state bar "E1226" "the `return` clause must be the first handler clause";
              reported_order := true
            end;
            ops := clause :: !ops
        | `Malformed -> ());
        match next_top with
        | None -> ignore (consume_separators state)
        | Some next_top ->
            report_code state next_top "E1221" "expected `}` before the next top-level item";
            closing := current state;
            finished := true)
    | _ -> (
        report_code state token "E1226" "handler clauses must begin with `|`";
        let clause, next_top = parse_handler_clause state token in
        (match clause with
        | `Return clause -> if Option.is_none !returns then returns := Some clause
        | `Operation clause -> ops := clause :: !ops
        | `Malformed -> ());
        match next_top with
        | None -> ignore (consume_separators state)
        | Some next_top ->
            report_code state next_top "E1221" "expected `}` before the next top-level item";
            closing := current state;
            finished := true)
  done;
  let ret =
    match !returns with Some clause -> clause | None -> missing_return_clause state !closing
  in
  Surface_ast.
    {
      it = Handle (body, ret, List.rev !ops);
      meta = meta_with_span (span_between keyword !closing);
    }

and parse_quote state keyword =
  match expect state Surface_lex.LBrace "`{` after `quote`" with
  | None ->
      let body = expr_hole state (current state) in
      Surface_ast.{ it = Quote (Surface body); meta = meta_from_token_to_meta keyword body.meta }
  | Some _opening ->
      ignore (consume_separators state);
      let body, raw_unclosed =
        match (current state).Surface_lex.token with
        | Surface_lex.Keyword "jqd" -> (
            ignore (advance state);
            skip_comments state;
            let raw = current state in
            match raw.Surface_lex.token with
            | Surface_lex.RawCandidate candidate ->
                ignore (advance state);
                let body =
                  match parse_raw_candidate state raw candidate with
                  | Some form -> Surface_ast.Raw form
                  | None -> Surface_ast.Surface (expr_hole state raw)
                in
                (body, not candidate.closed)
            | _ ->
                report_code state raw "E1226" "expected a raw `{ bootstrap-form }` after `jqd`";
                (Surface_ast.Surface (expr_hole state raw), false))
        | _ -> (Surface_ast.Surface (parse_expr state ~allow_newlines:false), false)
      in
      let closing =
        if raw_unclosed then current state
        else
          match quote_boundary_after_layout state with
          | Some boundary ->
              report_code state boundary "E1221"
                "expected `}` after the quoted expression before the enclosing boundary";
              current state
          | None -> (
              ignore (consume_separators state);
              match expect state Surface_lex.RBrace "`}` after the quoted expression" with
              | Some token -> token
              | None -> current state)
      in
      Surface_ast.{ it = Quote body; meta = meta_with_span (span_between keyword closing) }

and parse_unquote state keyword =
  match expect state Surface_lex.LParen "`(` after `unquote`" with
  | None ->
      let body = expr_hole state (current state) in
      Surface_ast.{ it = Unquote body; meta = meta_from_token_to_meta keyword body.meta }
  | Some _ ->
      skip_list_space state;
      let body = parse_expr state ~allow_newlines:true in
      skip_list_space state;
      let closing =
        match expect state Surface_lex.RParen "`)` after the unquote splice" with
        | Some token -> token
        | None ->
            synchronize_paren state;
            if (current state).Surface_lex.token = Surface_lex.RParen then advance state
            else current state
      in
      Surface_ast.{ it = Unquote body; meta = meta_with_span (span_between keyword closing) }

and parse_block state opening =
  let items = ref [] in
  let closing = ref opening in
  ignore (consume_separators state);
  let finished = ref false in
  while not !finished do
    let token = current state in
    match token.Surface_lex.token with
    | Surface_lex.RBrace ->
        closing := advance state;
        finished := true
    | Surface_lex.Eof ->
        report_code state token "E1221" "expected `}` before end of file";
        items := Surface_ast.Expr (expr_hole state token) :: !items;
        closing := token;
        finished := true
    | Surface_lex.Invalid _ ->
        items := Surface_ast.Expr (expr_hole state token) :: !items;
        ignore (advance state);
        finish_block_item state items closing finished
    | Surface_lex.Keyword "let" ->
        items := parse_let_item state (advance state) :: !items;
        finish_block_item state items closing finished
    | _ ->
        let expression = parse_expr state ~allow_newlines:false in
        items := Surface_ast.Expr expression :: !items;
        finish_block_item state items closing finished
  done;
  Surface_ast.
    { it = Block (List.rev !items); meta = meta_with_span (span_between opening !closing) }

and finish_block_item state items closing finished =
  skip_comments state;
  match (current state).Surface_lex.token with
  | Surface_lex.RBrace ->
      closing := advance state;
      finished := true
  | Surface_lex.Eof -> ()
  | Surface_lex.Newline | Surface_lex.Semi -> ignore (consume_separators state)
  | _ ->
      let token = current state in
      report_code state token "E1223" "block items require a newline or `;` separator";
      items := Surface_ast.Expr (expr_hole state token) :: !items;
      synchronize_item state;
      ignore (consume_separators state)

and parse_let_item state keyword =
  let recursive =
    match (current state).Surface_lex.token with
    | Surface_lex.Keyword "rec" ->
        ignore (advance state);
        true
    | _ -> false
  in
  let binder = parse_pattern state ~allow_newlines:false in
  let params =
    if recursive then
      match expect state Surface_lex.LParen "a parenthesized parameter list after `let rec`" with
      | Some opening -> fst (parse_pattern_list state opening)
      | None -> []
    else begin
      if (current state).Surface_lex.token = Surface_lex.LParen then
        report state (current state) "local function shorthand requires `let rec`";
      []
    end
  in
  ignore (expect state Surface_lex.Equal "`=` in the local binding");
  skip_continuation state;
  let value = parse_expr state ~allow_newlines:false in
  let _ = keyword in
  Surface_ast.Let { recursive; binder; params; value }

and parse_type state ~allow_newlines =
  if allow_newlines then skip_list_space state else skip_comments state;
  match (current state).Surface_lex.token with
  | Surface_lex.Keyword "forall" -> parse_forall state ~allow_newlines (advance state)
  | _ -> (
      let parsed = parse_type_app state ~allow_newlines in
      if allow_newlines then skip_list_space state else skip_comments state;
      match (current state).Surface_lex.token with
      | Surface_lex.Arrow -> (
          match parsed.arrow_params with
          | Some params -> parse_arrow state ~allow_newlines params parsed.ty.Surface_ast.meta
          | None ->
              let token = current state in
              report state token "arrow parameter types must use `(T, U) ->{...} R`";
              parsed.ty)
      | _ -> parsed.ty)

and parse_type_app state ~allow_newlines =
  let first = parse_type_atom state ~allow_newlines in
  let args = ref [] in
  let continue = ref true in
  while !continue do
    if allow_newlines then skip_list_space state else skip_comments state;
    if starts_type_atom (current state).Surface_lex.token then
      args := (parse_type_atom state ~allow_newlines).ty :: !args
    else continue := false
  done;
  match List.rev !args with
  | [] -> first
  | args ->
      let last = List.hd (List.rev args) in
      let meta = merged_meta first.ty.Surface_ast.meta last.Surface_ast.meta in
      { ty = Surface_ast.{ it = TyApp (first.ty, args); meta }; arrow_params = None }

and parse_type_atom state ~allow_newlines =
  if allow_newlines then skip_list_space state else skip_comments state;
  let token = current state in
  let meta = meta_with_span token.Surface_lex.span in
  match token.Surface_lex.token with
  | Surface_lex.Ident name when Surface_name.valid_lower_name name ->
      ignore (advance state);
      { ty = Surface_ast.{ it = TyVar name; meta }; arrow_params = None }
  | Surface_lex.Ident name ->
      ignore (advance state);
      { ty = Surface_ast.{ it = TyName (projected_name name); meta }; arrow_params = None }
  | Surface_lex.Escaped (Surface_name.Type, name) ->
      ignore (advance state);
      { ty = Surface_ast.{ it = TyName name; meta }; arrow_params = None }
  | Surface_lex.Escaped (Surface_name.Tvar, name) ->
      ignore (advance state);
      { ty = Surface_ast.{ it = TyVar name; meta }; arrow_params = None }
  | Surface_lex.HashRef (hash, Surface_name.Type) ->
      ignore (advance state);
      { ty = Surface_ast.{ it = TyHash hash; meta }; arrow_params = None }
  | Surface_lex.LParen -> parse_paren_type state ~allow_newlines (advance state)
  | _ ->
      report state token (Printf.sprintf "expected a type, found %s" (token_description token));
      if token.Surface_lex.token <> Surface_lex.Eof then ignore (advance_recording_invalid state);
      let id, meta = hole_meta state token.span in
      { ty = Surface_ast.{ it = TyHole id; meta }; arrow_params = None }

and parse_paren_type state ~allow_newlines:_ opening =
  skip_list_space state;
  if (current state).Surface_lex.token = Surface_lex.RParen then
    let closing = advance state in
    {
      ty = Surface_ast.{ it = TyTuple []; meta = meta_with_span (span_between opening closing) };
      arrow_params = Some [];
    }
  else
    let first = parse_type state ~allow_newlines:true in
    skip_list_space state;
    match (current state).Surface_lex.token with
    | Surface_lex.RParen ->
        let closing = advance state in
        let ty = { first with Surface_ast.meta = meta_with_span (span_between opening closing) } in
        { ty; arrow_params = Some [ first ] }
    | Surface_lex.Comma ->
        ignore (advance state);
        skip_list_space state;
        if (current state).Surface_lex.token = Surface_lex.RParen then
          let closing = advance state in
          {
            ty =
              Surface_ast.
                { it = TyTuple [ first ]; meta = meta_with_span (span_between opening closing) };
            arrow_params = None;
          }
        else
          let rec items acc =
            let item = parse_type state ~allow_newlines:true in
            skip_list_space state;
            match (current state).Surface_lex.token with
            | Surface_lex.Comma ->
                ignore (advance state);
                skip_list_space state;
                if (current state).Surface_lex.token = Surface_lex.RParen then begin
                  report state (current state)
                    "multi-item type tuples do not permit a trailing comma";
                  (List.rev (item :: acc), advance state)
                end
                else items (item :: acc)
            | Surface_lex.RParen -> (List.rev (item :: acc), advance state)
            | _ ->
                let token = current state in
                report state token
                  (Printf.sprintf "expected `,` or `)`, found %s" (token_description token));
                synchronize_paren state;
                let closing =
                  if (current state).Surface_lex.token = Surface_lex.RParen then advance state
                  else current state
                in
                (List.rev (item :: acc), closing)
          in
          let rest, closing = items [] in
          let all = first :: rest in
          {
            ty =
              Surface_ast.{ it = TyTuple all; meta = meta_with_span (span_between opening closing) };
            arrow_params = Some all;
          }
    | _ ->
        let token = current state in
        report state token
          (Printf.sprintf "expected `,` or `)`, found %s" (token_description token));
        let id, meta = hole_meta state token.span in
        { ty = Surface_ast.{ it = TyHole id; meta }; arrow_params = None }

and parse_arrow state ~allow_newlines params left_meta =
  let arrow = advance state in
  let opening = expect state Surface_lex.LBrace "`{` immediately after `->`" in
  Option.iter (fun _ -> skip_continuation state) opening;
  let effects = ref [] in
  let tail = ref None in
  let finished = ref false in
  let closing = ref arrow in
  while not !finished do
    let token = current state in
    match token.Surface_lex.token with
    | Surface_lex.RBrace ->
        closing := advance state;
        finished := true
    | Surface_lex.Bar ->
        if Option.is_some !tail then report state token "an effect row can contain only one tail";
        ignore (advance state);
        skip_continuation state;
        tail := parse_row_var state;
        skip_list_space state;
        if (current state).Surface_lex.token <> Surface_lex.RBrace then
          report state (current state) "the effect-row tail must be the final row item"
    | Surface_lex.Ident name when Option.is_some (kernel_name_of_pascal name) ->
        effects := Surface_ast.Named (projected_name name) :: !effects;
        ignore (advance state);
        parse_row_separator state
    | Surface_lex.Escaped (Surface_name.Effect, name) ->
        effects := Surface_ast.Named name :: !effects;
        ignore (advance state);
        parse_row_separator state
    | Surface_lex.HashRef (hash, Surface_name.Effect) ->
        effects := Surface_ast.Hashed hash :: !effects;
        ignore (advance state);
        parse_row_separator state
    | _ ->
        report state token
          (Printf.sprintf "expected an effect name, row tail, or `}`, found %s"
             (token_description token));
        if token.token <> Surface_lex.Eof then ignore (advance_recording_invalid state);
        finished := true
  done;
  let row_meta = meta_with_span (span_between arrow !closing) in
  if allow_newlines then skip_list_space state else skip_continuation state;
  let result = parse_type state ~allow_newlines in
  let meta = merged_meta left_meta result.Surface_ast.meta in
  Surface_ast.
    { it = TyArrow (params, { effects = List.rev !effects; tail = !tail; row_meta }, result); meta }

and parse_row_separator state =
  skip_list_space state;
  match (current state).Surface_lex.token with
  | Surface_lex.Comma -> (
      ignore (advance state);
      skip_continuation state;
      match (current state).Surface_lex.token with
      | Surface_lex.RBrace | Surface_lex.Bar ->
          report state (current state) "effect rows do not permit a trailing comma"
      | _ -> ())
  | Surface_lex.Bar | Surface_lex.RBrace -> ()
  | _ -> report state (current state) "expected `,`, `|`, or `}` in the effect row"

and parse_row_var state =
  let token = current state in
  match token.Surface_lex.token with
  | Surface_lex.Ident name when Surface_name.valid_lower_name name ->
      ignore (advance state);
      Some name
  | Surface_lex.Escaped (Surface_name.Rvar, name) ->
      ignore (advance state);
      Some name
  | _ ->
      report state token "expected a lowercase row variable after `|`";
      None

and parse_forall state ~allow_newlines keyword =
  let tyvars = ref [] in
  let rowvars = ref [] in
  let in_rows = ref false in
  let finished = ref false in
  while not !finished do
    if allow_newlines then skip_list_space state else skip_comments state;
    let token = current state in
    match token.Surface_lex.token with
    | Surface_lex.Dot ->
        if !in_rows && !rowvars = [] then
          report state token "expected at least one row variable after `|` in `forall`";
        ignore (advance state);
        finished := true
    | Surface_lex.Bar when not !in_rows ->
        in_rows := true;
        ignore (advance state)
    | Surface_lex.Ident name when Surface_name.valid_lower_name name ->
        if !in_rows then rowvars := name :: !rowvars else tyvars := name :: !tyvars;
        ignore (advance state)
    | Surface_lex.Escaped (Surface_name.Tvar, name) when not !in_rows ->
        tyvars := name :: !tyvars;
        ignore (advance state)
    | Surface_lex.Escaped (Surface_name.Rvar, name) when !in_rows ->
        rowvars := name :: !rowvars;
        ignore (advance state)
    | Surface_lex.Invalid { Diag.code = "E1211"; _ } -> (
        match forall_name_before_dot state token with
        | Some name ->
            if !in_rows then rowvars := name :: !rowvars else tyvars := name :: !tyvars;
            ignore (advance state);
            finished := true
        | None ->
            report state token "expected quantified variables followed by `.`";
            ignore (advance state);
            finished := true)
    | _ ->
        report state token "expected quantified variables followed by `.`";
        if token.token <> Surface_lex.Eof then ignore (advance_recording_invalid state);
        finished := true
  done;
  skip_continuation state;
  let body = parse_type state ~allow_newlines in
  let meta =
    match Meta.span body.Surface_ast.meta with
    | Some span -> meta_with_span (Span.merge keyword.Surface_lex.span span)
    | None -> meta_with_span keyword.span
  in
  Surface_ast.{ it = TyForall (List.rev !tyvars, List.rev !rowvars, body); meta }

let op_name = function
  | Surface_lex.Ident name when Surface_name.valid_lower_name name -> Some name
  | Surface_lex.Escaped (Surface_name.Op, name) -> Some name
  | _ -> None

let projected_decl_name kind = function
  | Surface_lex.Ident name -> kernel_name_of_pascal name
  | Surface_lex.Escaped (actual, name) when actual = kind -> Some name
  | _ -> None

let type_decl_name token = projected_decl_name Surface_name.Type token
let con_decl_name token = projected_decl_name Surface_name.Con token
let effect_decl_name token = projected_decl_name Surface_name.Effect token
let equation_definition_ahead state = equation_definition_ahead_at state state.index

let skip_continuation_before_top state =
  let layout = state.index in
  skip_continuation state;
  if state.index > layout && top_item_ahead state state.index then begin
    let top = current state in
    state.index <- layout;
    Some top
  end
  else None

let layout_boundary_before_top state start =
  let rec find index depth =
    match (token_at state index).Surface_lex.token with
    | Surface_lex.Eof -> None
    | Surface_lex.LParen -> find (index + 1) (depth + 1)
    | Surface_lex.RParen when depth > 0 -> find (index + 1) (depth - 1)
    | Surface_lex.RParen -> None
    | Surface_lex.Comma when depth = 0 -> None
    | Surface_lex.Comment _ | Surface_lex.DocComment _ | Surface_lex.Newline | Surface_lex.Semi ->
        let next = index_after_layout state index in
        if next > index && top_item_ahead state next then Some (index, token_at state next)
        else find (index + 1) depth
    | _ -> find (index + 1) depth
  in
  find start 0

let parse_signature state name_token name =
  ignore (advance state);
  ignore (expect state Surface_lex.Colon "`:` in the signature");
  skip_continuation state;
  let ty = parse_type state ~allow_newlines:false in
  Surface_ast.{ it = Signature (name, ty); meta = meta_from_token_to_meta name_token ty.meta }

let parse_definition state name_token name equation =
  ignore (advance state);
  let params =
    if equation then
      match expect state Surface_lex.LParen "`(` after the definition name" with
      | Some opening -> fst (parse_pattern_list state opening)
      | None -> []
    else []
  in
  ignore (expect state Surface_lex.Equal "`=` in the definition");
  skip_continuation state;
  let value = parse_expr state ~allow_newlines:false in
  Surface_ast.
    {
      it = Definition { name; equation; params; value };
      meta = meta_from_token_to_meta name_token value.meta;
    }

let parse_type_vars state stop =
  let vars = ref [] in
  let finished = ref false in
  while not !finished do
    let token = current state in
    if stop token.Surface_lex.token then finished := true
    else
      match token.Surface_lex.token with
      | Surface_lex.Ident name when Surface_name.valid_lower_name name ->
          vars := name :: !vars;
          ignore (advance state)
      | Surface_lex.Escaped (Surface_name.Tvar, name) ->
          vars := name :: !vars;
          ignore (advance state)
      | _ -> finished := true
  done;
  List.rev !vars

let parse_decl_name state description project =
  let token = current state in
  match project token.Surface_lex.token with
  | Some name ->
      ignore (advance state);
      (name, token)
  | None ->
      report_code state token "E1225"
        (Printf.sprintf "expected %s, found %s" description (token_description token));
      if token.Surface_lex.token <> Surface_lex.Eof then ignore (advance_recording_invalid state);
      ("__surface_hole", token)

let field_label_ahead state =
  match term_name (current state).Surface_lex.token with
  | None -> None
  | Some name ->
      let next = token_at state (state.index + 1) in
      if next.Surface_lex.token = Surface_lex.Colon then Some name else None

let parse_constructor_fields state constructor opening =
  let fields = ref [] in
  let has_label = ref false in
  let closing = ref opening in
  skip_list_space state;
  let finished = ref false in
  while not !finished do
    match (current state).Surface_lex.token with
    | Surface_lex.RParen ->
        closing := advance state;
        finished := true
    | Surface_lex.Eof | Surface_lex.RBrace ->
        report_code state (current state) "E1225" "expected `)` to close the constructor field list";
        finished := true
    | _ -> (
        let start = current state in
        let label = field_label_ahead state in
        let missing_type =
          match label with
          | None -> None
          | Some _ ->
              has_label := true;
              ignore (advance state);
              ignore (advance state);
              skip_continuation_before_top state
        in
        match missing_type with
        | Some next_top ->
            report_code state next_top "E1225"
              (Printf.sprintf
                 "expected a field type in constructor `%s` before the next top-level item"
                 constructor);
            let ty = ty_hole state next_top in
            fields :=
              Surface_ast.{ label; ty; meta = meta_from_token_to_meta start ty.meta } :: !fields;
            finished := true
        | None -> (
            let boundary = layout_boundary_before_top state state.index in
            let ty =
              match boundary with
              | Some (limit, _) ->
                  with_limit state limit (fun () -> parse_type state ~allow_newlines:true)
              | None -> parse_type state ~allow_newlines:true
            in
            let meta = meta_from_token_to_meta start ty.Surface_ast.meta in
            fields := Surface_ast.{ label; ty; meta } :: !fields;
            match boundary with
            | Some (limit, next_top) when state.index = limit ->
                report_code state next_top "E1225"
                  (Printf.sprintf
                     "expected `)` to close constructor `%s` before the next top-level item"
                     constructor);
                finished := true
            | Some _ | None -> (
                skip_list_space state;
                match (current state).Surface_lex.token with
                | Surface_lex.Comma ->
                    ignore (advance state);
                    skip_list_space state;
                    if (current state).Surface_lex.token = Surface_lex.RParen then
                      report_code state (current state) "E1225"
                        "constructor field lists do not permit a trailing comma"
                | Surface_lex.RParen -> ()
                | _ ->
                    report_code state (current state) "E1225"
                      (Printf.sprintf "expected `,` or `)` in constructor `%s`, found %s"
                         constructor
                         (token_description (current state)));
                    synchronize_paren state)))
  done;
  if not !has_label then
    report_code state opening "E1225"
      (Printf.sprintf
         "constructor `%s` uses positional fields without parentheses; write `%s T`, not `%s(T)`"
         constructor constructor constructor);
  (List.rev !fields, !closing)

let parse_constructor state =
  let name, name_token = parse_decl_name state "a constructor name" con_decl_name in
  match (current state).Surface_lex.token with
  | Surface_lex.LParen ->
      let opening = advance state in
      let fields, closing = parse_constructor_fields state name opening in
      Surface_ast.
        {
          name;
          fields;
          meta = meta_with_span (Span.merge name_token.Surface_lex.span closing.span);
        }
  | _ ->
      let fields = ref [] in
      while starts_type_atom (current state).Surface_lex.token do
        let parsed = parse_type_atom state ~allow_newlines:false in
        fields := Surface_ast.{ label = None; ty = parsed.ty; meta = parsed.ty.meta } :: !fields;
        skip_comments state
      done;
      let fields = List.rev !fields in
      let meta =
        match List.rev fields with
        | field :: _ -> meta_from_token_to_meta name_token field.Surface_ast.meta
        | [] -> meta_with_span name_token.span
      in
      Surface_ast.{ name; fields; meta }

let next_bar state =
  let index = index_after_layout state state.index in
  if (token_at state index).Surface_lex.token = Surface_lex.Bar then Some index else None

let parse_type_decl state keyword =
  let name, _ = parse_decl_name state "a type name" type_decl_name in
  let vars = parse_type_vars state (fun token -> token = Surface_lex.Equal) in
  ignore (expect state Surface_lex.Equal "`=` in the type declaration");
  let interrupted = ref false in
  (match skip_continuation_before_top state with
  | Some next_top ->
      report_code state next_top "E1225" "a type declaration requires a constructor";
      interrupted := true
  | None ->
      if (current state).Surface_lex.token = Surface_lex.Bar then begin
        ignore (advance state);
        match skip_continuation_before_top state with
        | Some next_top ->
            report_code state next_top "E1225" "a type declaration requires a constructor after `|`";
            interrupted := true
        | None -> ()
      end);
  let constructors = ref [] in
  let finished = ref !interrupted in
  while not !finished do
    match con_decl_name (current state).Surface_lex.token with
    | None ->
        if !constructors = [] then
          report_code state (current state) "E1225" "a type declaration requires a constructor";
        finished := true
    | Some _ -> (
        constructors := parse_constructor state :: !constructors;
        match next_bar state with
        | Some index ->
            state.index <- index;
            ignore (advance state);
            skip_continuation state
        | None -> finished := true)
  done;
  let constructors = List.rev !constructors in
  let meta =
    match List.rev constructors with
    | constructor :: _ -> meta_from_token_to_meta keyword constructor.Surface_ast.meta
    | [] -> meta_with_span keyword.Surface_lex.span
  in
  Surface_ast.{ it = TypeDecl { name; vars; constructors }; meta }

let parse_operation_types state =
  match expect state Surface_lex.LParen "`(` before operation parameter types" with
  | None -> []
  | Some _ ->
      skip_list_space state;
      if (current state).Surface_lex.token = Surface_lex.RParen then begin
        ignore (advance state);
        []
      end
      else
        let rec loop acc =
          let ty = parse_type state ~allow_newlines:true in
          skip_list_space state;
          match (current state).Surface_lex.token with
          | Surface_lex.Comma ->
              ignore (advance state);
              skip_list_space state;
              if (current state).Surface_lex.token = Surface_lex.RParen then begin
                report_code state (current state) "E1225"
                  "operation parameter lists do not permit a trailing comma";
                ignore (advance state);
                List.rev (ty :: acc)
              end
              else loop (ty :: acc)
          | Surface_lex.RParen ->
              ignore (advance state);
              List.rev (ty :: acc)
          | _ ->
              report_code state (current state) "E1225"
                (Printf.sprintf "expected `,` or `)` in operation parameters, found %s"
                   (token_description (current state)));
              synchronize_paren state;
              if (current state).Surface_lex.token = Surface_lex.RParen then ignore (advance state);
              List.rev (ty :: acc)
        in
        loop []

let parse_operation state =
  let name_token = current state in
  let name = Option.value ~default:"__surface_hole" (op_name name_token.Surface_lex.token) in
  ignore (advance state);
  ignore (expect state Surface_lex.Colon "`:` in the operation signature");
  skip_continuation state;
  let params = parse_operation_types state in
  ignore (expect state Surface_lex.Arrow "`->` in the operation signature");
  skip_continuation state;
  let result = parse_type state ~allow_newlines:false in
  Surface_ast.{ name; params; result; meta = meta_from_token_to_meta name_token result.meta }

let operation_ahead state index =
  match op_name (token_at state index).Surface_lex.token with
  | None -> false
  | Some _ ->
      let next = index_after_comments state (index + 1) in
      (token_at state next).Surface_lex.token = Surface_lex.Colon

let parse_effect_decl state keyword =
  let name, _ = parse_decl_name state "an effect name" effect_decl_name in
  let vars = parse_type_vars state (fun token -> token = Surface_lex.Keyword "where") in
  ignore (expect state (Surface_lex.Keyword "where") "`where` in the effect declaration");
  let opening = expect state Surface_lex.LBrace "`{` immediately after `where`" in
  let operations = ref [] in
  let closing = ref None in
  let interrupted = ref false in
  (match opening with
  | None -> ()
  | Some _ ->
      let layout = state.index in
      let next = index_after_layout state layout in
      if next > layout && top_item_ahead state next && not (operation_ahead state next) then begin
        report_code state (token_at state next) "E1221"
          "expected `}` before the next top-level item";
        interrupted := true
      end
      else ignore (consume_separators state);
      let finished = ref false in
      if !interrupted then finished := true;
      while not !finished do
        let token = current state in
        match token.Surface_lex.token with
        | Surface_lex.RBrace ->
            closing := Some (advance state);
            finished := true
        | Surface_lex.Eof ->
            report_code state token "E1221" "expected `}` before end of effect declaration";
            finished := true
        | _ when operation_ahead state state.index -> (
            operations := parse_operation state :: !operations;
            skip_comments state;
            match (current state).Surface_lex.token with
            | Surface_lex.RBrace -> ()
            | Surface_lex.Newline | Surface_lex.Semi ->
                let next = index_after_layout state state.index in
                if top_item_ahead state next && not (operation_ahead state next) then begin
                  report_code state (token_at state next) "E1221"
                    "expected `}` before the next top-level item";
                  finished := true
                end
                else ignore (consume_separators state)
            | Surface_lex.Eof -> ()
            | _ ->
                report_code state (current state) "E1225"
                  "effect operations require a newline or `;` separator";
                synchronize_item state;
                ignore (consume_separators state))
        | _ ->
            report_code state token "E1225"
              (Printf.sprintf "expected an operation signature or `}`, found %s"
                 (token_description token));
            if token.Surface_lex.token <> Surface_lex.Eof then begin
              synchronize_item state;
              ignore (consume_separators state)
            end
      done);
  if Option.is_some opening && (not !interrupted) && !operations = [] then
    report_code state keyword "E1225" "an effect declaration requires an operation signature";
  let operations = List.rev !operations in
  let end_span =
    match !closing with
    | Some token -> token.Surface_lex.span
    | None -> (
        match List.rev operations with
        | operation :: _ ->
            Option.value ~default:keyword.span (Meta.span operation.Surface_ast.meta)
        | [] -> keyword.span)
  in
  Surface_ast.
    {
      it = EffectDecl { name; vars; operations };
      meta = meta_with_span (Span.merge keyword.Surface_lex.span end_span);
    }

let parse_raw_top state keyword =
  skip_comments state;
  let raw = current state in
  match raw.Surface_lex.token with
  | Surface_lex.RawCandidate candidate ->
      ignore (advance state);
      begin match parse_raw_candidate state raw candidate with
      | Some form ->
          Surface_ast.
            {
              it = RawTop form;
              meta = meta_with_span (Span.merge keyword.Surface_lex.span raw.span);
            }
      | None -> top_hole state raw
      end
  | _ ->
      report_code state raw "E1226" "expected a raw `{ bootstrap-form }` after top-level `jqd`";
      top_hole state raw

let parse_top state =
  let token = current state in
  match token.Surface_lex.token with
  | Surface_lex.Invalid _ ->
      ignore (advance state);
      top_hole state token
  | Surface_lex.RBrace ->
      report state token "unmatched `}` at top level";
      ignore (advance state);
      top_hole state token
  | Surface_lex.Bar ->
      report state token "stray `|` at top level";
      ignore (advance state);
      top_hole state token
  | Surface_lex.Keyword "type" -> parse_type_decl state (advance state)
  | Surface_lex.Keyword "effect" -> parse_effect_decl state (advance state)
  | Surface_lex.Keyword "jqd" -> parse_raw_top state (advance state)
  | surface_token -> (
      match term_name surface_token with
      | Some name when (token_at state (state.index + 1)).Surface_lex.token = Surface_lex.Colon ->
          parse_signature state token name
      | Some name when (token_at state (state.index + 1)).Surface_lex.token = Surface_lex.Equal ->
          parse_definition state token name false
      | Some name when equation_definition_ahead state -> parse_definition state token name true
      | _ ->
          let expression = parse_expr state ~allow_newlines:false in
          Surface_ast.{ it = TopExpr expression; meta = expression.meta })

let signature_interruption state token message = report_code state token "E1224" message

let parse_tokens ~source tokens =
  let state =
    {
      source;
      tokens = Array.of_list tokens;
      index = 0;
      limit = None;
      diagnostics = [];
      next_hole = 0;
    }
  in
  let items = ref [] in
  let pending_signature = ref None in
  ignore (consume_separators state);
  while (current state).Surface_lex.token <> Surface_lex.Eof do
    let start = current state in
    let item = parse_top state in
    (match (!pending_signature, item.Surface_ast.it) with
    | Some (expected, _), Surface_ast.Definition { name; _ } when String.equal expected name ->
        pending_signature := None
    | Some (expected, _), Surface_ast.Signature (name, _) ->
        signature_interruption state start
          (Printf.sprintf
             "signature for `%s` must be followed by its definition; found a second signature for \
              `%s`"
             expected name);
        pending_signature := Some (name, item)
    | Some (expected, _), Surface_ast.Definition { name; _ } ->
        signature_interruption state start
          (Printf.sprintf "signature for `%s` cannot attach to definition `%s`" expected name);
        pending_signature := None
    | Some (expected, _), _ ->
        signature_interruption state start
          (Printf.sprintf "signature for `%s` must be followed by its definition" expected);
        pending_signature := None
    | None, Surface_ast.Signature (name, _) -> pending_signature := Some (name, item)
    | None, _ -> ());
    items := item :: !items;
    skip_comments state;
    if (current state).Surface_lex.token <> Surface_lex.Eof then begin
      let separators = consume_separators_info state in
      (match (!pending_signature, separators.semicolon) with
      | Some (name, _), Some semicolon ->
          signature_interruption state semicolon
            (Printf.sprintf "signature for `%s` cannot be separated from its definition by `;`" name);
          pending_signature := None
      | _ -> ());
      if not separators.consumed then begin
        let token = current state in
        report state token
          (Printf.sprintf "top-level items require a newline or `;`, found %s"
             (token_description token));
        synchronize_item state;
        ignore (consume_separators state)
      end
    end
  done;
  (match !pending_signature with
  | Some (name, _) ->
      signature_interruption state (current state)
        (Printf.sprintf "signature for `%s` has no following definition" name)
  | None -> ());
  Surface_ast.{ items = List.rev !items; diagnostics = List.rev state.diagnostics }

(** [recover_string] returns a partial tree and source-ordered diagnostics. Lexical damage becomes
    an in-order hole, allowing valid surrounding items and later parser errors to survive. *)
let recover_string ~file src : Surface_ast.recovered =
  let recovered = Surface_lex.lex_recover ~file src in
  let parsed = parse_tokens ~source:src recovered.tokens in
  let diagnostic_offset diagnostic =
    match diagnostic.Diag.span with Some span -> span.Span.start_pos.offset | None -> max_int
  in
  let diagnostics =
    List.stable_sort
      (fun left right -> Int.compare (diagnostic_offset left) (diagnostic_offset right))
      (recovered.diagnostics @ parsed.diagnostics)
  in
  { parsed with Surface_ast.diagnostics }

(** [strict recovered] rejects parser errors and any partial tree containing a recovery hole. This
    is the boundary that prevents holes from reaching lowering, canonicalization, or execution. *)
let strict (recovered : Surface_ast.recovered) : (Surface_ast.top list, Diag.t list) result =
  let errors =
    List.filter (fun d -> d.Diag.severity = Diag.Error) recovered.Surface_ast.diagnostics
  in
  if errors <> [] then Error recovered.diagnostics
  else if List.exists Surface_ast.has_holes_top recovered.items then
    Error
      [
        Diag.error ~code:"E1202"
          "surface parser recovery left holes; fix the syntax before checking or hashing";
      ]
  else Ok recovered.items

(** [parse_string ~file src] strictly parses a complete surface file. It returns every top-level
    item in document order, or source-ordered, span-bearing diagnostics after recovery. *)
let parse_string ~file src : (Surface_ast.top list, Diag.t list) result =
  strict (recover_string ~file src)
