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
let record_diagnostic state diagnostic = state.diagnostics <- diagnostic :: state.diagnostics
let token_description token = Surface_lex.show_token token.Surface_lex.token

let advance_recording_invalid state =
  let token = current state in
  (match token.Surface_lex.token with
  | Surface_lex.Invalid diagnostic -> record_diagnostic state diagnostic
  | _ -> ());
  advance state

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
    | Surface_lex.RParen | Surface_lex.RBrace | Surface_lex.Eof -> false
    | _ -> true
  do
    ignore (advance_recording_invalid state)
  done

let discard_parenthesized state =
  if (current state).Surface_lex.token = Surface_lex.LParen then begin
    let depth = ref 0 in
    let finished = ref false in
    while not !finished do
      let token = current state in
      match token.Surface_lex.token with
      | Surface_lex.LParen ->
          incr depth;
          ignore (advance state)
      | Surface_lex.RParen ->
          decr depth;
          ignore (advance state);
          if !depth = 0 then finished := true
      | Surface_lex.Eof | Surface_lex.RBrace -> finished := true
      | _ -> ignore (advance_recording_invalid state)
    done
  end

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

let expect state expected description =
  let token = current state in
  if token.Surface_lex.token = expected then Some (advance state)
  else begin
    report state token
      (Printf.sprintf "expected %s, found %s" description (token_description token));
    None
  end

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
  | Surface_lex.Invalid diagnostic ->
      record_diagnostic state diagnostic;
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
        let pattern =
          match (current state).Surface_lex.token with
          | Surface_lex.Keyword "as" ->
              let token = advance state in
              report_code state token "E1222" "`as` patterns arrive in SS.9, not SS.7";
              (match (current state).Surface_lex.token with
              | Surface_lex.Ident name when Surface_name.valid_lower_name name ->
                  ignore (advance state)
              | Surface_lex.Escaped (Surface_name.Term, _) -> ignore (advance state)
              | _ -> ());
              pat_hole state token
          | _ -> pattern
        in
        skip_list_space state;
        match (current state).Surface_lex.token with
        | Surface_lex.Comma ->
            ignore (advance state);
            skip_list_space state;
            if (current state).Surface_lex.token = Surface_lex.RParen then begin
              report state (current state) "parameter lists do not permit a trailing comma";
              let closing = advance state in
              (List.rev (pattern :: acc), closing)
            end
            else loop (pattern :: acc)
        | Surface_lex.RParen ->
            let closing = advance state in
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
  | Surface_lex.LParen ->
      let opening = advance state in
      let items, closing = parse_pattern_list state opening in
      Surface_ast.{ it = PTuple items; meta = meta_with_span (span_between opening closing) }
  | Surface_lex.Literal _ | Surface_lex.Ident _
  | Surface_lex.Escaped ((Surface_name.Con | Surface_name.Op), _)
  | Surface_lex.HashRef (_, Surface_name.Con) ->
      report_code state token "E1222"
        "SS.7 binding positions accept only `_`, lowercase binders, and tuple patterns";
      ignore (advance state);
      discard_parenthesized state;
      pat_hole state token
  | _ ->
      report_code state token "E1222"
        (Printf.sprintf "expected an irrefutable SS.7 pattern, found %s" (token_description token));
      if token.Surface_lex.token <> Surface_lex.Eof then ignore (advance_recording_invalid state);
      pat_hole state token

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
    | Surface_lex.Invalid diagnostic ->
        record_diagnostic state diagnostic;
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

let with_limit state limit f =
  let previous = state.limit in
  state.limit <- Some limit;
  Fun.protect ~finally:(fun () -> state.limit <- previous) f

let term_name = function
  | Surface_lex.Ident name when Surface_name.valid_lower_name name -> Some name
  | Surface_lex.Escaped (Surface_name.Term, name) -> Some name
  | _ -> None

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

let equation_definition_ahead state = equation_definition_ahead_at state state.index

let top_item_ahead state index =
  match (token_at state index).Surface_lex.token with
  | Surface_lex.Keyword ("type" | "effect") -> true
  | token -> (
      match term_name token with
      | None -> false
      | Some _ -> (
          let next = index_after_comments state (index + 1) in
          match (token_at state next).Surface_lex.token with
          | Surface_lex.Colon | Surface_lex.Equal -> true
          | _ -> equation_definition_ahead_at state index))

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

let meta_from_token_to_meta token meta =
  match Meta.span meta with
  | Some span -> meta_with_span (Span.merge token.Surface_lex.span span)
  | None -> meta_with_span token.span

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

let parse_top state =
  let token = current state in
  match token.Surface_lex.token with
  | Surface_lex.Invalid diagnostic ->
      record_diagnostic state diagnostic;
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
  parse_tokens ~source:src recovered.tokens

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
