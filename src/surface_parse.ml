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
  mutable recovery_depth : int;
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

let diagnostic_token state token =
  match (state.limit, token.Surface_lex.token) with
  | Some limit, Surface_lex.Eof when state.index >= limit -> state.tokens.(limit)
  | (Some _ | None), _ -> token

let report_code state token code message =
  let token = diagnostic_token state token in
  state.diagnostics <- Diag.error ~span:token.Surface_lex.span ~code message :: state.diagnostics

let report state token message = report_code state token "E1220" message

let token_description state token =
  Surface_lex.show_token (diagnostic_token state token).Surface_lex.token

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

let synchronize_bracket state =
  while
    match (current state).Surface_lex.token with
    | Surface_lex.RParen | Surface_lex.RBracket | Surface_lex.RBrace | Surface_lex.Bar
    | Surface_lex.Eof ->
        false
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

let with_container_span kind first last meta =
  Meta.with_surface_container kind (meta_with_span (span_between first last)) meta

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
      (Printf.sprintf "expected %s, found %s" description (token_description state token));
    None
  end

let with_limit state limit f =
  let previous = state.limit in
  state.limit <- Some limit;
  Fun.protect ~finally:(fun () -> state.limit <- previous) f

let within_recovery_container state f =
  state.recovery_depth <- state.recovery_depth + 1;
  Fun.protect ~finally:(fun () -> state.recovery_depth <- state.recovery_depth - 1) f

let token_at state index =
  if index < Array.length state.tokens then state.tokens.(index)
  else state.tokens.(Array.length state.tokens - 1)

let rec index_after_comments state index =
  match (token_at state index).Surface_lex.token with
  | Surface_lex.Comment _ | Surface_lex.DocComment _ -> index_after_comments state (index + 1)
  | _ -> index

let rec index_after_continuation state index =
  match (token_at state index).Surface_lex.token with
  | Surface_lex.Comment _ | Surface_lex.DocComment _ | Surface_lex.Newline ->
      index_after_continuation state (index + 1)
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

let top_boundary_after_continuation state =
  if state.recovery_depth > 0 || Option.is_some state.limit then None
  else
    let layout = state.index in
    let next = index_after_continuation state layout in
    if next > layout && top_item_ahead state next then Some (token_at state next) else None

let is_expression_boundary = function
  | Surface_lex.RParen | Surface_lex.RBracket | Surface_lex.RBrace | Surface_lex.Bar
  | Surface_lex.Eof ->
      true
  | _ -> false

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
  let left = parse_call state ~allow_newlines in
  let rec loop left =
    let pipe_index = index_after_continuation state state.index in
    match (token_at state pipe_index).Surface_lex.token with
    | Surface_lex.Pipe ->
        state.index <- pipe_index;
        ignore (advance state);
        skip_continuation state;
        let right = parse_call state ~allow_newlines in
        loop Surface_ast.{ it = Pipe (left, right); meta = merged_meta left.meta right.meta }
    | _ -> left
  in
  loop left

and parse_call state ~allow_newlines =
  let fn : Surface_ast.expr = parse_primary state ~allow_newlines in
  let rec postfix (fn : Surface_ast.expr) : Surface_ast.expr =
    skip_comments state;
    match (current state).Surface_lex.token with
    | Surface_lex.LParen ->
        let opening = advance state in
        let args, closing = within_recovery_container state (fun () -> parse_expr_list state) in
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
              (Printf.sprintf "expected `,` or `)`, found %s" (token_description state token));
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
      let meta = Meta.with_surface_reference meta in
      Surface_ast.{ it = Name (Option.value ~default:name projected); meta }
  | Surface_lex.Escaped (((Surface_name.Term | Surface_name.Con | Surface_name.Op) as kind), name)
    ->
      ignore (advance state);
      let meta =
        meta
        |> Meta.with_surface_ref_kind (Surface_name.kind_tag kind)
        |> Meta.with_surface_reference
      in
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
  | Surface_lex.LParen ->
      let opening = advance state in
      within_recovery_container state (fun () -> parse_paren_expr state opening)
  | Surface_lex.LBracket -> parse_list_expr state (advance state)
  | Surface_lex.LBrace ->
      let opening = advance state in
      within_recovery_container state (fun () -> parse_block state opening)
  | Surface_lex.Keyword "fn" -> parse_fn state ~allow_newlines (advance state)
  | Surface_lex.Keyword "match" -> parse_match state ~allow_newlines (advance state)
  | Surface_lex.Keyword "if" -> parse_if state ~allow_newlines (advance state)
  | Surface_lex.Keyword "handle" -> parse_handle state ~allow_newlines (advance state)
  | Surface_lex.Keyword "quote" ->
      let keyword = advance state in
      within_recovery_container state (fun () -> parse_quote state keyword)
  | Surface_lex.Keyword "unquote" ->
      let keyword = advance state in
      within_recovery_container state (fun () -> parse_unquote state keyword)
  | Surface_lex.Invalid _ ->
      ignore (advance state);
      expr_hole state token
  | _ ->
      report state token
        (Printf.sprintf "expected an expression, found %s" (token_description state token));
      if token.Surface_lex.token <> Surface_lex.Eof then ignore (advance state);
      expr_hole state token

and parse_list_expr state opening =
  let items, closing =
    match top_boundary_after_continuation state with
    | Some next_top ->
        report state next_top "expected `]` before the next top-level item";
        ([ expr_hole state (current state) ], current state)
    | None -> (
        skip_list_space state;
        match (current state).Surface_lex.token with
        | Surface_lex.RBracket -> ([], advance state)
        | _ ->
            let rec loop acc =
              let expression =
                within_recovery_container state (fun () -> parse_expr state ~allow_newlines:true)
              in
              match top_boundary_after_continuation state with
              | Some next_top ->
                  report state next_top "expected `,` or `]` before the next top-level item";
                  (List.rev (expr_hole state (current state) :: expression :: acc), current state)
              | None -> (
                  skip_list_space state;
                  match (current state).Surface_lex.token with
                  | Surface_lex.Comma ->
                      ignore (advance state);
                      skip_list_space state;
                      if (current state).Surface_lex.token = Surface_lex.RBracket then begin
                        report state (current state) "list literals do not permit a trailing comma";
                        let hole = expr_hole state (current state) in
                        (List.rev (hole :: expression :: acc), advance state)
                      end
                      else loop (expression :: acc)
                  | Surface_lex.RBracket -> (List.rev (expression :: acc), advance state)
                  | _ ->
                      let token = current state in
                      report state token
                        (Printf.sprintf "expected `,` or `]`, found %s"
                           (token_description state token));
                      let hole = expr_hole state token in
                      synchronize_bracket state;
                      let closing =
                        match (current state).Surface_lex.token with
                        | Surface_lex.RBracket -> advance state
                        | _ -> current state
                      in
                      (List.rev (hole :: expression :: acc), closing))
            in
            loop [])
  in
  let meta = meta_with_span (span_between opening closing) in
  Surface_ast.{ it = List items; meta = Meta.with_surface_container "list" meta meta }

and parse_if state ~allow_newlines keyword =
  let condition = parse_expr state ~allow_newlines in
  match top_boundary_after_continuation state with
  | Some next_top ->
      report state next_top "expected `then` after the condition before the next top-level item";
      let yes = expr_hole state (current state) in
      let no = expr_hole state (current state) in
      Surface_ast.{ it = If (condition, yes, no); meta = meta_from_token_to_meta keyword no.meta }
  | None ->
      skip_continuation state;
      let then_token = expect state (Surface_lex.Keyword "then") "`then` after the condition" in
      if Option.is_none then_token && is_expression_boundary (current state).Surface_lex.token then
        let yes = expr_hole state (current state) in
        let no = expr_hole state (current state) in
        Surface_ast.{ it = If (condition, yes, no); meta = meta_from_token_to_meta keyword no.meta }
      else begin
        let branch_boundary =
          match then_token with Some _ -> top_boundary_after_continuation state | None -> None
        in
        match branch_boundary with
        | Some next_top ->
            report state next_top
              "expected an expression after `then` before the next top-level item";
            let yes = expr_hole state (current state) in
            let no = expr_hole state (current state) in
            Surface_ast.
              { it = If (condition, yes, no); meta = meta_from_token_to_meta keyword no.meta }
        | None -> (
            Option.iter (fun _ -> skip_continuation state) then_token;
            let yes = parse_expr state ~allow_newlines in
            match top_boundary_after_continuation state with
            | Some next_top ->
                report state next_top
                  "expected `else` after the then branch before the next top-level item";
                let no = expr_hole state (current state) in
                Surface_ast.
                  { it = If (condition, yes, no); meta = meta_from_token_to_meta keyword no.meta }
            | None -> (
                skip_continuation state;
                let else_token =
                  expect state (Surface_lex.Keyword "else") "`else` after the then branch"
                in
                if
                  Option.is_none else_token
                  && is_expression_boundary (current state).Surface_lex.token
                then
                  let no = expr_hole state (current state) in
                  Surface_ast.
                    { it = If (condition, yes, no); meta = meta_from_token_to_meta keyword no.meta }
                else
                  let branch_boundary =
                    match else_token with
                    | Some _ -> top_boundary_after_continuation state
                    | None -> None
                  in
                  match branch_boundary with
                  | Some next_top ->
                      report state next_top
                        "expected an expression after `else` before the next top-level item";
                      let no = expr_hole state (current state) in
                      Surface_ast.
                        {
                          it = If (condition, yes, no);
                          meta = meta_from_token_to_meta keyword no.meta;
                        }
                  | None ->
                      Option.iter (fun _ -> skip_continuation state) else_token;
                      let no =
                        if is_expression_boundary (current state).Surface_lex.token then begin
                          report state (current state) "expected an expression after `else`";
                          expr_hole state (current state)
                        end
                        else parse_expr state ~allow_newlines
                      in
                      Surface_ast.
                        {
                          it = If (condition, yes, no);
                          meta = meta_from_token_to_meta keyword no.meta;
                        }))
      end

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
                    (Printf.sprintf "expected `,` or `)`, found %s" (token_description state token));
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
          let meta = meta_with_span (span_between opening closing) in
          { first with Surface_ast.meta = Meta.with_surface_container "paren" meta meta }
      | _ ->
          let token = current state in
          report state token
            (Printf.sprintf "expected `:`, `,`, or `)`, found %s" (token_description state token));
          synchronize_paren state;
          let closing =
            if (current state).Surface_lex.token = Surface_lex.RParen then advance state
            else current state
          in
          let hole = expr_hole state token in
          { hole with Surface_ast.meta = meta_with_span (span_between opening closing) })

and parse_fn state ~allow_newlines keyword =
  let params, params_meta =
    match expect state Surface_lex.LParen "`(` after `fn`" with
    | Some opening ->
        let params, closing = parse_pattern_list state opening in
        (params, Some (meta_with_span (span_between opening closing)))
    | None -> ([], None)
  in
  let arrow = expect state Surface_lex.Arrow "`->` after function parameters" in
  Option.iter (fun _ -> skip_continuation state) arrow;
  let body = parse_expr state ~allow_newlines in
  let meta =
    match Meta.span body.Surface_ast.meta with
    | Some body_span -> meta_with_span (Span.merge keyword.Surface_lex.span body_span)
    | None -> meta_with_span keyword.span
  in
  let meta =
    match params_meta with
    | Some params_meta -> Meta.with_surface_container "params" params_meta meta
    | None -> meta
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
              (Printf.sprintf "expected `,` or `)`, found %s" (token_description state token));
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
                 (token_description state binder_token));
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
      Surface_ast.{ it = PBind name; meta = Meta.with_surface_ref_kind "term" meta }
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
      report state token
        (Printf.sprintf "expected a pattern, found %s" (token_description state token));
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
             (token_description state operation_token));
        (match operation_token.Surface_lex.token with
        | Surface_lex.Bar | Surface_lex.RBrace | Surface_lex.Eof -> ()
        | _ -> ignore (advance_recording_invalid state));
        Surface_ast.Named "__surface_hole"
  in
  let params, params_meta =
    match expect state Surface_lex.LParen "`(` after the operation name" with
    | Some opening ->
        let params, closing = parse_pattern_list state opening in
        (params, Some (meta_with_span (span_between opening closing)))
    | None -> ([], None)
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
          (Printf.sprintf "expected a resume binder, found %s"
             (token_description state resume_token));
        (match resume_token.Surface_lex.token with
        | Surface_lex.Arrow | Surface_lex.Bar | Surface_lex.RBrace | Surface_lex.Eof -> ()
        | _ -> ignore (advance_recording_invalid state));
        "__surface_hole"
  in
  skip_comments state;
  let obody, next_top = parse_handler_clause_body state start in
  let ometa = meta_from_token_to_meta start obody.meta |> Meta.with_surface_ref_kind "op" in
  let ometa =
    match params_meta with
    | Some params_meta -> Meta.with_surface_container "params" params_meta ometa
    | None -> ometa
  in
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
           (token_description state token));
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
  let meta = meta_with_span (span_between opening !closing) in
  Surface_ast.{ it = Block (List.rev !items); meta = Meta.with_surface_container "block" meta meta }

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
  let params, params_meta =
    if recursive then (
      match (current state).Surface_lex.token with
      | Surface_lex.LParen ->
          let opening = advance state in
          let params, closing = parse_pattern_list state opening in
          (params, Some (meta_with_span (span_between opening closing)))
      | _ ->
          report_code state (current state) "E1233"
            "`let rec` requires a lowercase name followed by a parameter list";
          ([], None))
    else begin
      if (current state).Surface_lex.token = Surface_lex.LParen then
        report state (current state) "local function shorthand requires `let rec`";
      ([], None)
    end
  in
  ignore (expect state Surface_lex.Equal "`=` in the local binding");
  skip_continuation state;
  let value = parse_expr state ~allow_newlines:false in
  let meta = meta_from_token_to_meta keyword value.meta in
  let meta =
    match params_meta with
    | Some params_meta -> Meta.with_surface_container "params" params_meta meta
    | None -> meta
  in
  Surface_ast.Let { recursive; binder; params; value; meta }

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
      report state token
        (Printf.sprintf "expected a type, found %s" (token_description state token));
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
                  (Printf.sprintf "expected `,` or `)`, found %s" (token_description state token));
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
          (Printf.sprintf "expected `,` or `)`, found %s" (token_description state token));
        let id, meta = hole_meta state token.span in
        { ty = Surface_ast.{ it = TyHole id; meta }; arrow_params = None }

and parse_arrow state ~allow_newlines params left_meta =
  let diagnostics_before_row = List.length state.diagnostics in
  let arrow = advance state in
  let opening = expect state Surface_lex.LBrace "`{` immediately after `->`" in
  let effects = ref [] in
  let tail = ref None in
  let row_owners = ref Meta.empty in
  let own kind token =
    row_owners :=
      Meta.with_surface_container kind (meta_with_span token.Surface_lex.span) !row_owners
  in
  let own_indexed kind index token =
    row_owners :=
      Meta.with_surface_indexed_container kind index
        (meta_with_span token.Surface_lex.span)
        !row_owners
  in
  let finished = ref false in
  let stopped_before_top = ref false in
  let closing = ref arrow in
  Option.iter
    (fun opening ->
      own "row-open" opening;
      (match top_boundary_after_continuation state with
      | Some next_top ->
          report state next_top "expected `}` before the next top-level item";
          stopped_before_top := true;
          finished := true
      | None -> skip_continuation state);
      while not !finished do
        let token = current state in
        match token.Surface_lex.token with
        | Surface_lex.RBrace ->
            let token = advance state in
            own "row-close" token;
            closing := token;
            finished := true
        | Surface_lex.Eof ->
            report state token "expected `}` to close the effect row";
            finished := true
        | Surface_lex.Bar ->
            let duplicate = Option.is_some !tail in
            if duplicate then report state token "an effect row can contain only one tail";
            own "row-bar" (advance state);
            skip_continuation state;
            let parsed_tail = parse_row_var state in
            if not duplicate then tail := Option.map fst parsed_tail;
            Option.iter (fun (_, token) -> own "row-tail" token) parsed_tail;
            skip_list_space state;
            if (current state).Surface_lex.token <> Surface_lex.RBrace then
              report state (current state) "the effect-row tail must be the final row item"
        | Surface_lex.Ident name when Option.is_some (kernel_name_of_pascal name) ->
            if Option.is_some !tail then
              report state token "the effect-row tail must be the final row item";
            let index = List.length !effects in
            effects := Surface_ast.Named (projected_name name) :: !effects;
            own_indexed "row-effect" index (advance state);
            if not (parse_row_separator state ~effect_index:index row_owners) then begin
              stopped_before_top := true;
              finished := true
            end
        | Surface_lex.Escaped (Surface_name.Effect, name) ->
            if Option.is_some !tail then
              report state token "the effect-row tail must be the final row item";
            let index = List.length !effects in
            effects := Surface_ast.Named name :: !effects;
            own_indexed "row-effect" index (advance state);
            if not (parse_row_separator state ~effect_index:index row_owners) then begin
              stopped_before_top := true;
              finished := true
            end
        | Surface_lex.HashRef (hash, Surface_name.Effect) ->
            if Option.is_some !tail then
              report state token "the effect-row tail must be the final row item";
            let index = List.length !effects in
            effects := Surface_ast.Hashed hash :: !effects;
            own_indexed "row-effect" index (advance state);
            if not (parse_row_separator state ~effect_index:index row_owners) then begin
              stopped_before_top := true;
              finished := true
            end
        | _ ->
            report state token
              (Printf.sprintf "expected an effect name, row tail, or `}`, found %s"
                 (token_description state token));
            if token.token <> Surface_lex.Eof then ignore (advance_recording_invalid state);
            finished := true
      done)
    opening;
  let row_meta = Meta.with_span (span_between arrow !closing) !row_owners in
  let row_hole, row_meta =
    if List.length state.diagnostics = diagnostics_before_row then (None, row_meta)
    else
      let id = state.next_hole in
      state.next_hole <- id + 1;
      (Some id, Meta.with_surface_hole (string_of_int id) row_meta)
  in
  let result =
    if !stopped_before_top then ty_hole state (current state)
    else begin
      if allow_newlines then skip_list_space state else skip_continuation state;
      parse_type state ~allow_newlines
    end
  in
  let meta = merged_meta left_meta result.Surface_ast.meta in
  let meta =
    match Meta.span left_meta with
    | Some span -> Meta.with_surface_container "params" (Meta.with_span span Meta.empty) meta
    | None -> meta
  in
  Surface_ast.
    {
      it =
        TyArrow (params, { effects = List.rev !effects; tail = !tail; row_hole; row_meta }, result);
      meta;
    }

and parse_row_separator state ~effect_index row_owners =
  match top_boundary_after_continuation state with
  | Some next_top ->
      report state next_top "expected `}` before the next top-level item";
      false
  | None ->
      skip_comments state;
      (match (current state).Surface_lex.token with
      | Surface_lex.Comma -> (
          let comma = advance state in
          row_owners :=
            Meta.with_surface_indexed_container "row-comma" effect_index
              (meta_with_span comma.Surface_lex.span)
              !row_owners;
          skip_continuation state;
          match (current state).Surface_lex.token with
          | Surface_lex.RBrace | Surface_lex.Bar ->
              report state (current state) "effect rows do not permit a trailing comma"
          | _ -> ())
      | Surface_lex.Bar | Surface_lex.RBrace -> ()
      | Surface_lex.Newline -> (
          skip_continuation state;
          match (current state).Surface_lex.token with
          | Surface_lex.Bar | Surface_lex.RBrace -> ()
          | Surface_lex.Comma ->
              report state (current state)
                "a row comma must immediately follow the preceding effect"
          | _ -> report state (current state) "expected `|` or `}` after the effect row")
      | _ -> report state (current state) "expected `,`, `|`, or `}` in the effect row");
      true

and parse_row_var state =
  let token = current state in
  match token.Surface_lex.token with
  | Surface_lex.Ident name when Surface_name.valid_lower_name name -> Some (name, advance state)
  | Surface_lex.Escaped (Surface_name.Rvar, name) -> Some (name, advance state)
  | _ ->
      report state token "expected a lowercase row variable after `|`";
      None

and parse_forall state ~allow_newlines keyword =
  let tyvars = ref [] in
  let rowvars = ref [] in
  let in_rows = ref false in
  let finished = ref false in
  let dot = ref keyword in
  let forall_owners = ref Meta.empty in
  let own kind token =
    forall_owners :=
      Meta.with_surface_container kind (meta_with_span token.Surface_lex.span) !forall_owners
  in
  let own_indexed kind index token =
    forall_owners :=
      Meta.with_surface_indexed_container kind index
        (meta_with_span token.Surface_lex.span)
        !forall_owners
  in
  own "forall-keyword" keyword;
  while not !finished do
    skip_comments state;
    let token = current state in
    match token.Surface_lex.token with
    | Surface_lex.Dot ->
        if !in_rows && !rowvars = [] then
          report state token "expected at least one row variable after `|` in `forall`";
        let token = advance state in
        own "forall-dot" token;
        dot := token;
        finished := true
    | Surface_lex.Bar when not !in_rows ->
        in_rows := true;
        own "forall-bar" (advance state)
    | Surface_lex.Ident name when Surface_name.valid_lower_name name ->
        if !in_rows then begin
          own_indexed "forall-rvar" (List.length !rowvars) token;
          rowvars := name :: !rowvars
        end
        else begin
          own_indexed "forall-tvar" (List.length !tyvars) token;
          tyvars := name :: !tyvars
        end;
        ignore (advance state)
    | Surface_lex.Escaped (Surface_name.Tvar, name) when not !in_rows ->
        own_indexed "forall-tvar" (List.length !tyvars) token;
        tyvars := name :: !tyvars;
        ignore (advance state)
    | Surface_lex.Escaped (Surface_name.Rvar, name) when !in_rows ->
        own_indexed "forall-rvar" (List.length !rowvars) token;
        rowvars := name :: !rowvars;
        ignore (advance state)
    | Surface_lex.Invalid { Diag.code = "E1211"; _ } -> (
        match forall_name_before_dot state token with
        | Some name ->
            if !in_rows then begin
              own_indexed "forall-rvar" (List.length !rowvars) token;
              rowvars := name :: !rowvars
            end
            else begin
              own_indexed "forall-tvar" (List.length !tyvars) token;
              tyvars := name :: !tyvars
            end;
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
  let forall_meta = Meta.with_span (span_between keyword !dot) !forall_owners in
  let meta = Meta.with_surface_container "forall" forall_meta meta in
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
  let params, params_meta =
    if equation then
      match expect state Surface_lex.LParen "`(` after the definition name" with
      | Some opening ->
          let params, closing = parse_pattern_list state opening in
          (params, Some (meta_with_span (span_between opening closing)))
      | None -> ([], None)
    else ([], None)
  in
  ignore (expect state Surface_lex.Equal "`=` in the definition");
  skip_continuation state;
  let value = parse_expr state ~allow_newlines:false in
  let meta = meta_from_token_to_meta name_token value.meta in
  let meta =
    match params_meta with
    | Some params_meta -> Meta.with_surface_container "params" params_meta meta
    | None -> meta
  in
  Surface_ast.{ it = Definition { name; equation; params; value }; meta }

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
        (Printf.sprintf "expected %s, found %s" description (token_description state token));
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
                         (token_description state (current state)));
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
      let meta = meta_with_span (Span.merge name_token.Surface_lex.span closing.span) in
      let meta = with_container_span "params" opening closing meta in
      Surface_ast.{ name; fields; meta }
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
  | None -> ([], None)
  | Some opening ->
      skip_list_space state;
      if (current state).Surface_lex.token = Surface_lex.RParen then begin
        let closing = advance state in
        ([], Some (meta_with_span (span_between opening closing)))
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
                let closing = advance state in
                (List.rev (ty :: acc), closing)
              end
              else loop (ty :: acc)
          | Surface_lex.RParen ->
              let closing = advance state in
              (List.rev (ty :: acc), closing)
          | _ ->
              report_code state (current state) "E1225"
                (Printf.sprintf "expected `,` or `)` in operation parameters, found %s"
                   (token_description state (current state)));
              synchronize_paren state;
              let closing =
                if (current state).Surface_lex.token = Surface_lex.RParen then advance state
                else current state
              in
              (List.rev (ty :: acc), closing)
        in
        let params, closing = loop [] in
        (params, Some (meta_with_span (span_between opening closing)))

let parse_operation state =
  let name_token = current state in
  let name = Option.value ~default:"__surface_hole" (op_name name_token.Surface_lex.token) in
  ignore (advance state);
  ignore (expect state Surface_lex.Colon "`:` in the operation signature");
  skip_continuation state;
  let params, params_meta = parse_operation_types state in
  ignore (expect state Surface_lex.Arrow "`->` in the operation signature");
  skip_continuation state;
  let result = parse_type state ~allow_newlines:false in
  let meta = meta_from_token_to_meta name_token result.meta in
  let meta =
    match params_meta with
    | Some params_meta -> Meta.with_surface_container "params" params_meta meta
    | None -> meta
  in
  Surface_ast.{ name; params; result; meta }

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
                 (token_description state token));
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

module Trivia_ownership = struct
  type role =
    | Decl
    | Damage
    | Expr
    | Pat
    | Ty
    | Clause
    | Ret
    | Op_clause
    | Row
    | Field
    | Constructor
    | Operation
    | Item
    | Container of string

  type key = role * int * int

  type addition = {
    mutable leading : Meta.trivia_atom list;
    mutable trailing : Meta.trivia_atom list;
    mutable inner : Meta.trivia_atom list;
    mutable eof : Meta.trivia_atom list;
    mutable docs : Meta.trivia_atom list;
  }

  type slot = { key : key; role : role; span : Span.t }

  module Key = struct
    type t = key

    let compare = Stdlib.compare
  end

  module Key_map = Map.Make (Key)

  let empty_addition () = { leading = []; trailing = []; inner = []; eof = []; docs = [] }
  let key role span = (role, span.Span.start_pos.offset, span.end_pos.offset)

  let slot role meta =
    match Meta.span meta with None -> [] | Some span -> [ { key = key role span; role; span } ]

  let container kind meta = slot (Container kind) (Meta.surface_container kind meta)
  let containers kinds meta = List.concat_map (fun kind -> container kind meta) kinds

  let indexed_containers kind count meta =
    List.init count (fun index ->
        slot
          (Container (Printf.sprintf "%s/%d" kind index))
          (Meta.surface_indexed_container kind index meta))
    |> List.concat

  let forall_slots tvars rvars meta =
    let meta = Meta.surface_container "forall" meta in
    containers [ "forall-keyword"; "forall-bar"; "forall-dot" ] meta
    @ indexed_containers "forall-tvar" (List.length tvars) meta
    @ indexed_containers "forall-rvar" (List.length rvars) meta

  let row_slots (row : Surface_ast.row) =
    containers [ "row-open"; "row-bar"; "row-tail"; "row-close" ] row.row_meta
    @ indexed_containers "row-effect" (List.length row.effects) row.row_meta
    @ indexed_containers "row-comma" (max 0 (List.length row.effects - 1)) row.row_meta

  let rec expr depth (node : Surface_ast.expr) =
    let children =
      match node.it with
      | Lit _ | Name _ | HashRef _ | GroupRef _ | Hole _ -> []
      | Call (fn, args) -> expr (depth + 1) fn @ List.concat_map (expr (depth + 1)) args
      | Fn (params, body) -> List.concat_map (pat (depth + 1)) params @ expr (depth + 1) body
      | Tuple items | List items -> List.concat_map (expr (depth + 1)) items
      | Block items -> List.concat_map (block_item (depth + 1)) items
      | Match (subject, clauses) ->
          expr (depth + 1) subject @ List.concat_map (clause (depth + 1)) clauses
      | If (cond, yes, no) -> expr (depth + 1) cond @ expr (depth + 1) yes @ expr (depth + 1) no
      | Pipe (left, right) -> expr (depth + 1) left @ expr (depth + 1) right
      | Handle (body, ret, ops) ->
          expr (depth + 1) body
          @ ret_clause (depth + 1) ret
          @ List.concat_map (op_clause (depth + 1)) ops
      | Quote (Surface body) -> expr (depth + 1) body
      | Quote (Raw _) -> []
      | Unquote body -> expr (depth + 1) body
      | Ann (subject, annotation) -> expr (depth + 1) subject @ ty (depth + 1) annotation
    in
    container "block" node.meta @ container "params" node.meta @ container "paren" node.meta
    @ container "list" node.meta @ slot Expr node.meta @ children

  and block_item depth = function
    | Surface_ast.Expr expression -> expr depth expression
    | Let { binder; params; value; meta; _ } ->
        container "params" meta @ slot Item meta
        @ pat (depth + 1) binder
        @ List.concat_map (pat (depth + 1)) params
        @ expr (depth + 1) value

  and clause depth (clause : Surface_ast.clause) =
    slot Clause clause.cmeta @ pat (depth + 1) clause.cpattern @ expr (depth + 1) clause.cbody

  and ret_clause depth (clause : Surface_ast.ret_clause) =
    slot Ret clause.rmeta @ pat (depth + 1) clause.rbinder @ expr (depth + 1) clause.rbody

  and op_clause depth (clause : Surface_ast.op_clause) =
    container "params" clause.ometa @ slot Op_clause clause.ometa
    @ List.concat_map (pat (depth + 1)) clause.oparams
    @ expr (depth + 1) clause.obody

  and pat depth (node : Surface_ast.pat) =
    let children =
      match node.it with
      | PWild | PBind _ | PLit _ | PHole _ -> []
      | PCon (_, args) | PTuple args -> List.concat_map (pat (depth + 1)) args
      | PAs (inner, _) -> pat (depth + 1) inner
    in
    slot Pat node.meta @ children

  and ty depth (node : Surface_ast.ty) =
    let children =
      match node.it with
      | TyName _ | TyVar _ | TyHash _ | TyHole _ -> []
      | TyApp (head, args) -> ty (depth + 1) head @ List.concat_map (ty (depth + 1)) args
      | TyArrow (params, row, result) ->
          List.concat_map (ty (depth + 1)) params
          @ slot Row row.row_meta @ row_slots row
          @ ty (depth + 1) result
      | TyTuple items -> List.concat_map (ty (depth + 1)) items
      | TyForall (tvars, rvars, body) -> forall_slots tvars rvars node.meta @ ty (depth + 1) body
    in
    container "params" node.meta @ container "forall" node.meta @ slot Ty node.meta @ children

  let field depth (field : Surface_ast.field) = slot Field field.meta @ ty (depth + 1) field.ty

  let constructor depth (constructor : Surface_ast.constructor) =
    container "params" constructor.meta
    @ slot Constructor constructor.meta
    @ List.concat_map (field (depth + 1)) constructor.fields

  let operation depth (operation : Surface_ast.operation) =
    container "params" operation.meta @ slot Operation operation.meta
    @ List.concat_map (ty (depth + 1)) operation.params
    @ ty (depth + 1) operation.result

  let top (node : Surface_ast.top) =
    match node.it with
    | TopExpr expression -> expr 0 expression
    | Signature (_, annotation) -> slot Decl node.meta @ ty 1 annotation
    | Definition { params; value; _ } ->
        container "params" node.meta @ slot Decl node.meta
        @ List.concat_map (pat 1) params
        @ expr 1 value
    | TypeDecl { constructors; _ } ->
        slot Decl node.meta @ List.concat_map (constructor 1) constructors
    | EffectDecl { operations; _ } -> slot Decl node.meta @ List.concat_map (operation 1) operations
    | RawTop _ | TopHole _ -> slot Damage node.meta

  let role_rank = function
    | Container _ -> 3
    | Decl | Damage | Item | Clause | Ret | Op_clause | Constructor | Operation | Field -> 2
    | Expr | Pat | Ty | Row -> 1

  let length slot = slot.span.Span.end_pos.offset - slot.span.start_pos.offset
  let starts slot token = slot.span.Span.start_pos.offset = token.Surface_lex.span.start_pos.offset
  let ends slot token = slot.span.Span.end_pos.offset = token.Surface_lex.span.end_pos.offset

  let choose_largest slots =
    List.fold_left
      (fun best candidate ->
        match best with
        | None -> Some candidate
        | Some current ->
            if
              length candidate > length current
              || length candidate = length current
                 && role_rank candidate.role > role_rank current.role
            then Some candidate
            else best)
      None slots

  let choose_smallest slots =
    List.fold_left
      (fun best candidate ->
        match best with
        | None -> Some candidate
        | Some current ->
            if
              length candidate < length current
              || length candidate = length current
                 && role_rank candidate.role > role_rank current.role
            then Some candidate
            else best)
      None slots

  let significant = function
    | Surface_lex.Comment _ | DocComment _ | Newline | Semi | Eof -> false
    | _ -> true

  type source_atom = { atom : Meta.trivia_atom; start_line : int; end_line : int }

  let source_atoms source tokens start_offset end_offset =
    let comments =
      List.filter
        (fun (token : Surface_lex.located) ->
          token.Surface_lex.span.start_pos.offset >= start_offset
          && token.span.end_pos.offset <= end_offset
          && match token.token with Comment _ | DocComment _ -> true | _ -> false)
        tokens
    in
    let layout start finish line =
      if finish <= start then []
      else
        [
          {
            atom = Meta.Layout (String.sub source start (finish - start));
            start_line = line;
            end_line = line;
          };
        ]
    in
    let rec build cursor line acc = function
      | [] -> List.rev_append acc (layout cursor end_offset line)
      | (token : Surface_lex.located) :: rest ->
          let before = layout cursor token.span.start_pos.offset line in
          let text =
            String.sub source token.span.start_pos.offset
              (token.span.end_pos.offset - token.span.start_pos.offset)
          in
          let atom =
            match token.token with
            | DocComment _ -> Meta.Doc text
            | Comment _ -> Meta.Comment text
            | _ -> assert false
          in
          let item =
            { atom; start_line = token.span.start_pos.line; end_line = token.span.end_pos.line }
          in
          build token.span.end_pos.offset token.span.end_pos.line
            (item :: List.rev_append before acc)
            rest
    in
    build start_offset
      (match comments with first :: _ -> first.span.start_pos.line | [] -> 1)
      [] comments

  let atoms items = List.map (fun item -> item.atom) items

  let update additions slot field values =
    let addition =
      Option.value ~default:(empty_addition ()) (Key_map.find_opt slot.key !additions)
    in
    field addition values;
    additions := Key_map.add slot.key addition !additions

  let append_leading addition values = addition.leading <- addition.leading @ values
  let append_trailing addition values = addition.trailing <- addition.trailing @ values
  let append_inner addition values = addition.inner <- addition.inner @ values
  let append_eof addition values = addition.eof <- addition.eof @ values
  let append_docs addition values = addition.docs <- addition.docs @ values
  let is_closing = function Surface_lex.RParen | RBrace | RBracket -> true | _ -> false
  let is_declaration slot = slot.role = Decl

  let is_structured_owner slot =
    match slot.role with
    | Container kind ->
        String.starts_with ~prefix:"row-" kind || String.starts_with ~prefix:"forall-" kind
    | _ -> false

  let doc_suffix_before line items =
    let rec collect expected docs = function
      | [] -> docs
      | { atom = Meta.Layout _; _ } :: rest -> collect expected docs rest
      | { atom = Meta.Doc _ as doc; start_line; end_line } :: rest when end_line = expected - 1 ->
          collect start_line (doc :: docs) rest
      | _ -> docs
    in
    collect line [] (List.rev items)

  let attach ~source ~tokens items =
    let slots = List.concat_map top items in
    let additions = ref Key_map.empty in
    let boundary_tokens =
      List.filter
        (fun token -> significant token.Surface_lex.token || token.token = Surface_lex.Eof)
        tokens
    in
    let file_meta = ref Meta.empty in
    let rec gaps previous = function
      | [] -> ()
      | next :: rest ->
          let start_offset =
            match previous with None -> 0 | Some token -> token.Surface_lex.span.end_pos.offset
          in
          let end_offset = next.Surface_lex.span.start_pos.offset in
          let gap = source_atoms source tokens start_offset end_offset in
          let possible_trailing, possible_remaining =
            match previous with
            | Some previous ->
                let rec split prefix = function
                  | ({ atom = Meta.Comment _ | Doc _; start_line; _ } as comment) :: tail
                    when start_line = previous.Surface_lex.span.end_pos.line ->
                      (List.rev (comment :: prefix), tail)
                  | item :: tail -> split (item :: prefix) tail
                  | [] -> ([], gap)
                in
                split [] gap
            | None -> ([], gap)
          in
          let trailing_target =
            match (previous, possible_trailing) with
            | Some previous, _ :: _ ->
                let candidates = List.filter (fun slot -> ends slot previous) slots in
                let structured = List.filter is_structured_owner candidates in
                if structured = [] then choose_largest candidates else choose_smallest structured
            | _ -> None
          in
          let remaining =
            match trailing_target with
            | Some slot ->
                update additions slot append_trailing (atoms possible_trailing);
                possible_remaining
            | None -> gap
          in
          if remaining <> [] then
            begin if next.token = Surface_lex.Eof then
              match List.rev items with
              | last :: _ ->
                  choose_largest
                    (List.filter
                       (fun slot -> match slot.role with Container _ -> false | _ -> true)
                       (top last))
                  |> Option.iter (fun slot -> update additions slot append_eof (atoms remaining))
              | [] -> file_meta := Meta.with_trivia Meta.key_trivia_eof (atoms remaining) !file_meta
            else
              let exact = List.filter (fun slot -> starts slot next) slots in
              let exact =
                match (exact, next.token, rest) with
                | [], Surface_lex.Bar, after_bar :: _ ->
                    List.filter (fun slot -> starts slot after_bar) slots
                | _ -> exact
              in
              let target =
                if is_closing next.token then
                  choose_smallest (List.filter (fun slot -> ends slot next) slots)
                else
                  match choose_largest exact with
                  | Some _ as target -> target
                  | None ->
                      choose_smallest
                        (List.filter
                           (fun slot ->
                             slot.span.start_pos.offset <= start_offset
                             && slot.span.end_pos.offset >= end_offset)
                           slots)
              in
              Option.iter
                (fun slot ->
                  if is_closing next.token then update additions slot append_inner (atoms remaining)
                  else
                    let docs =
                      if is_declaration slot then
                        doc_suffix_before next.Surface_lex.span.start_pos.line remaining
                      else []
                    in
                    if docs <> [] then begin
                      update additions slot append_docs docs;
                      update additions slot append_leading (atoms remaining)
                    end
                    else update additions slot append_leading (atoms remaining))
                target
            end;
          gaps (if next.token = Surface_lex.Eof then previous else Some next) rest
    in
    gaps None boundary_tokens;
    (!additions, !file_meta)

  let apply additions role meta =
    match Meta.span meta with
    | None -> meta
    | Some span -> (
        match Key_map.find_opt (key role span) additions with
        | None -> meta
        | Some addition ->
            meta
            |> Meta.append_trivia Meta.key_trivia addition.leading
            |> Meta.append_trivia Meta.key_trivia_trailing addition.trailing
            |> Meta.append_trivia Meta.key_trivia_inner addition.inner
            |> Meta.append_trivia Meta.key_trivia_eof addition.eof
            |> Meta.append_docs addition.docs)

  let apply_container additions kind meta =
    let container_meta = Meta.surface_container kind meta in
    if Meta.is_empty container_meta then meta
    else Meta.with_surface_container kind (apply additions (Container kind) container_meta) meta

  let apply_containers additions kinds meta =
    List.fold_left (fun meta kind -> apply_container additions kind meta) meta kinds

  let apply_indexed_containers additions kind count meta =
    List.fold_left
      (fun meta index ->
        let key = Printf.sprintf "%s/%d" kind index in
        apply_container additions key meta)
      meta (List.init count Fun.id)

  let apply_forall_owners additions tvars rvars meta =
    let forall_meta =
      Meta.surface_container "forall" meta
      |> apply_containers additions [ "forall-keyword"; "forall-bar"; "forall-dot" ]
      |> apply_indexed_containers additions "forall-tvar" (List.length tvars)
      |> apply_indexed_containers additions "forall-rvar" (List.length rvars)
    in
    Meta.with_surface_container "forall" forall_meta meta

  let apply_row_owners additions effect_count meta =
    meta
    |> apply_containers additions [ "row-open"; "row-bar"; "row-tail"; "row-close" ]
    |> apply_indexed_containers additions "row-effect" effect_count
    |> apply_indexed_containers additions "row-comma" (max 0 (effect_count - 1))

  let apply_owner additions role meta =
    meta |> apply additions role
    |> apply_container additions "params"
    |> apply_container additions "block" |> apply_container additions "paren"
    |> apply_container additions "list"
    |> apply_container additions "forall"

  let rec map_expr additions (expression : Surface_ast.expr) =
    let it =
      match expression.it with
      | (Lit _ | Name _ | HashRef _ | GroupRef _ | Hole _) as leaf -> leaf
      | Call (fn, args) -> Call (map_expr additions fn, List.map (map_expr additions) args)
      | Fn (params, body) -> Fn (List.map (map_pat additions) params, map_expr additions body)
      | Tuple items -> Tuple (List.map (map_expr additions) items)
      | List items -> List (List.map (map_expr additions) items)
      | Block items -> Block (List.map (map_block_item additions) items)
      | Match (subject, clauses) ->
          Match (map_expr additions subject, List.map (map_clause additions) clauses)
      | If (cond, yes, no) ->
          If (map_expr additions cond, map_expr additions yes, map_expr additions no)
      | Pipe (left, right) -> Pipe (map_expr additions left, map_expr additions right)
      | Handle (body, ret, ops) ->
          Handle (map_expr additions body, map_ret additions ret, List.map (map_op additions) ops)
      | Quote (Surface body) -> Quote (Surface (map_expr additions body))
      | Quote (Raw form) -> Quote (Raw form)
      | Unquote body -> Unquote (map_expr additions body)
      | Ann (subject, annotation) -> Ann (map_expr additions subject, map_ty additions annotation)
    in
    Surface_ast.{ it; meta = apply_owner additions Expr expression.meta }

  and map_block_item additions = function
    | Surface_ast.Expr expression -> Surface_ast.Expr (map_expr additions expression)
    | Let item ->
        Let
          {
            item with
            binder = map_pat additions item.binder;
            params = List.map (map_pat additions) item.params;
            value = map_expr additions item.value;
            meta = apply_owner additions Item item.meta;
          }

  and map_clause additions (clause : Surface_ast.clause) =
    Surface_ast.
      {
        cpattern = map_pat additions clause.cpattern;
        cbody = map_expr additions clause.cbody;
        cmeta = apply additions Clause clause.cmeta;
      }

  and map_ret additions (clause : Surface_ast.ret_clause) =
    Surface_ast.
      {
        rbinder = map_pat additions clause.rbinder;
        rbody = map_expr additions clause.rbody;
        rmeta = apply additions Ret clause.rmeta;
      }

  and map_op additions clause =
    {
      clause with
      oparams = List.map (map_pat additions) clause.oparams;
      obody = map_expr additions clause.obody;
      ometa = apply_owner additions Op_clause clause.ometa;
    }

  and map_pat additions (pattern : Surface_ast.pat) =
    let it =
      match pattern.it with
      | (PWild | PBind _ | PLit _ | PHole _) as leaf -> leaf
      | PCon (constructor, args) -> PCon (constructor, List.map (map_pat additions) args)
      | PTuple args -> PTuple (List.map (map_pat additions) args)
      | PAs (inner, name) -> PAs (map_pat additions inner, name)
    in
    Surface_ast.{ it; meta = apply additions Pat pattern.meta }

  and map_ty additions (annotation : Surface_ast.ty) =
    let it =
      match annotation.it with
      | (TyName _ | TyVar _ | TyHash _ | TyHole _) as leaf -> leaf
      | TyApp (head, args) -> TyApp (map_ty additions head, List.map (map_ty additions) args)
      | TyArrow (params, row, result) ->
          TyArrow
            ( List.map (map_ty additions) params,
              {
                row with
                row_meta =
                  row.row_meta |> apply additions Row
                  |> apply_row_owners additions (List.length row.effects);
              },
              map_ty additions result )
      | TyTuple items -> TyTuple (List.map (map_ty additions) items)
      | TyForall (tvars, rvars, body) -> TyForall (tvars, rvars, map_ty additions body)
    in
    let meta = apply_owner additions Ty annotation.meta in
    let meta =
      match annotation.it with
      | TyForall (tvars, rvars, _) -> apply_forall_owners additions tvars rvars meta
      | _ -> meta
    in
    Surface_ast.{ it; meta }

  let map_field additions (field : Surface_ast.field) =
    Surface_ast.
      { field with ty = map_ty additions field.ty; meta = apply additions Field field.meta }

  let map_constructor additions (constructor : Surface_ast.constructor) =
    {
      constructor with
      Surface_ast.fields = List.map (map_field additions) constructor.fields;
      meta = apply_owner additions Constructor constructor.meta;
    }

  let map_operation additions (operation : Surface_ast.operation) =
    {
      operation with
      Surface_ast.params = List.map (map_ty additions) operation.params;
      result = map_ty additions operation.result;
      meta = apply_owner additions Operation operation.meta;
    }

  let map_top additions (top_node : Surface_ast.top) =
    let open Surface_ast in
    let it, meta =
      match top_node.it with
      | TopExpr expression -> (TopExpr (map_expr additions expression), top_node.meta)
      | Signature (name, annotation) ->
          (Signature (name, map_ty additions annotation), apply additions Decl top_node.meta)
      | Definition definition ->
          ( Definition
              {
                definition with
                params = List.map (map_pat additions) definition.params;
                value = map_expr additions definition.value;
              },
            apply_owner additions Decl top_node.meta )
      | TypeDecl declaration ->
          ( TypeDecl
              {
                declaration with
                constructors = List.map (map_constructor additions) declaration.constructors;
              },
            apply additions Decl top_node.meta )
      | EffectDecl declaration ->
          ( EffectDecl
              {
                declaration with
                operations = List.map (map_operation additions) declaration.operations;
              },
            apply additions Decl top_node.meta )
      | (RawTop _ | TopHole _) as it -> (it, apply additions Damage top_node.meta)
    in
    { it; meta }

  let run ~source ~tokens items =
    let additions, file_meta = attach ~source ~tokens items in
    (List.map (map_top additions) items, file_meta)
end

let parse_tokens ~source tokens =
  let state =
    {
      source;
      tokens = Array.of_list tokens;
      index = 0;
      limit = None;
      recovery_depth = 0;
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
             (token_description state token));
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
  let items, meta = Trivia_ownership.run ~source ~tokens (List.rev !items) in
  Surface_ast.{ items; diagnostics = List.rev state.diagnostics; meta; source }

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

(** [strict_file recovered] is [strict] with the file-level trivia anchor retained. *)
let strict_file (recovered : Surface_ast.recovered) : (Surface_ast.file, Diag.t list) result =
  match strict recovered with
  | Ok tops -> Ok Surface_ast.{ tops; meta = recovered.meta }
  | Error diagnostics -> Error diagnostics

(** [parse_string ~file src] strictly parses a complete surface file. It returns every top-level
    item in document order, or source-ordered, span-bearing diagnostics after recovery. *)
let parse_string ~file src : (Surface_ast.top list, Diag.t list) result =
  strict (recover_string ~file src)

(** [parse_file ~file src] strictly parses [src] while retaining comment-only and EOF metadata. *)
let parse_file ~file src : (Surface_ast.file, Diag.t list) result =
  strict_file (recover_string ~file src)
