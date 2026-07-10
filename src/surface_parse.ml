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
  mutable diagnostics : Diag.t list;
  mutable next_hole : int;
}

type parsed_type_atom = { ty : Surface_ast.ty; arrow_params : Surface_ast.ty list option }

let current state = state.tokens.(state.index)

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

let consume_separators state =
  let consumed = ref false in
  skip_comments state;
  while
    match (current state).Surface_lex.token with
    | Surface_lex.Newline | Surface_lex.Semi -> true
    | _ -> false
  do
    consumed := true;
    ignore (advance state);
    skip_comments state
  done;
  !consumed

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
  | _ ->
      let expression = parse_expr state ~allow_newlines:false in
      Surface_ast.{ it = TopExpr expression; meta = expression.meta }

let parse_tokens ~source tokens =
  let state =
    { source; tokens = Array.of_list tokens; index = 0; diagnostics = []; next_hole = 0 }
  in
  let items = ref [] in
  ignore (consume_separators state);
  while (current state).Surface_lex.token <> Surface_lex.Eof do
    items := parse_top state :: !items;
    skip_comments state;
    if (current state).Surface_lex.token <> Surface_lex.Eof then
      if not (consume_separators state) then begin
        let token = current state in
        report state token
          (Printf.sprintf "top-level items require a newline or `;`, found %s"
             (token_description token));
        synchronize_item state;
        ignore (consume_separators state)
      end
  done;
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
