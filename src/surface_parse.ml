(** Recovering recursive-descent control structure for `.jac`.

    Grammar productions land incrementally in SS.7-SS.15. This module already owns the durable
    boundaries: token cursor, diagnostics, span-bearing holes, separator handling, and
    synchronization at newline, semicolon, [}], and [|]. *)

(** [kernel_name_of_pascal] is the parser/resolver's D34 boundary for ordinary uppercase names.
    Kind-tagged escapes instead use {!Surface_name.decode_escaped}. *)
let kernel_name_of_pascal surface = Surface_name.of_pascal surface

type state = {
  tokens : Surface_lex.located array;
  mutable index : int;
  mutable diagnostics : Diag.t list;
  mutable next_hole : int;
}

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

let report state token message =
  state.diagnostics <-
    Diag.error ~span:token.Surface_lex.span ~code:"E1220" message :: state.diagnostics

let record_diagnostic state diagnostic = state.diagnostics <- diagnostic :: state.diagnostics
let token_description token = Surface_lex.show_token token.Surface_lex.token

let rec skip_trivia state =
  match (current state).Surface_lex.token with
  | Surface_lex.Comment _ | Surface_lex.DocComment _ ->
      ignore (advance state);
      skip_trivia state
  | _ -> ()

let rec skip_separators state =
  skip_trivia state;
  match (current state).Surface_lex.token with
  | Surface_lex.Newline | Surface_lex.Semi ->
      ignore (advance state);
      skip_separators state
  | _ -> ()

let is_sync = function
  | Surface_lex.Newline | Surface_lex.Semi | Surface_lex.RBrace | Surface_lex.Bar
  | Surface_lex.Invalid _ | Surface_lex.Eof ->
      true
  | _ -> false

let synchronize state =
  while not (is_sync (current state).Surface_lex.token) do
    ignore (advance state)
  done

let expr_hole state token =
  let id, meta = hole_meta state token.Surface_lex.span in
  Surface_ast.{ it = Hole id; meta }

let top_hole state token =
  let id, meta = hole_meta state token.Surface_lex.span in
  Surface_ast.{ it = TopHole id; meta }

let expr_of_atom token =
  let meta = meta_with_span token.Surface_lex.span in
  let node it = Some Surface_ast.{ it; meta } in
  match token.Surface_lex.token with
  | Surface_lex.Literal literal -> node (Surface_ast.Lit literal)
  | Surface_lex.Ident name -> node (Surface_ast.Name name)
  | Surface_lex.Escaped ((Surface_name.Term | Surface_name.Con | Surface_name.Op), name) ->
      node (Surface_ast.Name name)
  | Surface_lex.HashRef (hash, Surface_name.Term) -> node (Surface_ast.HashRef (hash, Kernel.Term))
  | Surface_lex.HashRef (hash, Surface_name.Con) -> node (Surface_ast.HashRef (hash, Kernel.Con))
  | Surface_lex.HashRef (hash, Surface_name.Op) -> node (Surface_ast.HashRef (hash, Kernel.Op))
  | Surface_lex.GroupRef index -> node (Surface_ast.GroupRef index)
  | _ -> None

let rec parse_block state opening =
  let items = ref [] in
  let closing_span = ref opening.Surface_lex.span in
  let finished = ref false in
  while not !finished do
    skip_separators state;
    let token = current state in
    match token.Surface_lex.token with
    | Surface_lex.RBrace ->
        closing_span := token.span;
        ignore (advance state);
        finished := true
    | Surface_lex.Eof ->
        state.diagnostics <-
          Diag.error ~span:token.span ~code:"E1221" "expected `}` before end of file"
          :: state.diagnostics;
        items := Surface_ast.Expr (expr_hole state token) :: !items;
        closing_span := token.span;
        finished := true
    | Surface_lex.Invalid diagnostic ->
        record_diagnostic state diagnostic;
        items := Surface_ast.Expr (expr_hole state token) :: !items;
        ignore (advance state)
    | Surface_lex.Bar ->
        report state token "stray `|` inside block; expected an expression";
        items := Surface_ast.Expr (expr_hole state token) :: !items;
        ignore (advance state)
    | Surface_lex.LBrace ->
        let nested = parse_block state (advance state) in
        items := Surface_ast.Expr nested :: !items
    | _ -> (
        match expr_of_atom token with
        | Some expression ->
            ignore (advance state);
            items := Surface_ast.Expr expression :: !items
        | None ->
            report state token
              (Printf.sprintf "expected an expression, found %s" (token_description token));
            items := Surface_ast.Expr (expr_hole state token) :: !items;
            ignore (advance state);
            synchronize state)
  done;
  let meta = meta_with_span (Span.merge opening.span !closing_span) in
  Surface_ast.{ it = Block (List.rev !items); meta }

let parse_top state =
  let token = current state in
  match token.Surface_lex.token with
  | Surface_lex.LBrace ->
      let opening = advance state in
      let expression = parse_block state opening in
      Surface_ast.{ it = TopExpr expression; meta = expression.meta }
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
  | _ -> (
      match expr_of_atom token with
      | Some expression ->
          ignore (advance state);
          Surface_ast.{ it = TopExpr expression; meta = expression.meta }
      | None ->
          report state token
            (Printf.sprintf "expected a top-level item, found %s" (token_description token));
          let hole = top_hole state token in
          ignore (advance state);
          synchronize state;
          hole)

let parse_tokens tokens =
  let state = { tokens = Array.of_list tokens; index = 0; diagnostics = []; next_hole = 0 } in
  let items = ref [] in
  let finished = ref false in
  while not !finished do
    skip_separators state;
    match (current state).Surface_lex.token with
    | Surface_lex.Eof -> finished := true
    | _ -> items := parse_top state :: !items
  done;
  Surface_ast.{ items = List.rev !items; diagnostics = List.rev state.diagnostics }

(** [recover_string] returns a partial tree and source-ordered diagnostics. Lexical damage becomes
    an in-order hole, allowing valid surrounding items and later parser errors to survive. *)
let recover_string ~file src : Surface_ast.recovered =
  let recovered = Surface_lex.lex_recover ~file src in
  parse_tokens recovered.tokens

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
    item in document order, or diagnostics when syntax recovery was required. *)
let parse_string ~file src : (Surface_ast.top list, Diag.t list) result =
  strict (recover_string ~file src)
