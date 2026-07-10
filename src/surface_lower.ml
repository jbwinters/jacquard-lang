(** Local lowering from recoverable surface syntax to the fixed 27-form kernel.

    This pass performs no store lookup. Names remain unresolved [Kernel.Var] nodes, while explicit
    hash and group references lower directly. *)

let ( let* ) = Result.bind

let error ?meta ~code message =
  Error [ Diag.error ?span:(Option.bind meta Meta.span) ~code message ]

let rec map_results f = function
  | [] -> Ok []
  | item :: rest ->
      let* item = f item in
      let* rest = map_results f rest in
      Ok (item :: rest)

let kernel_gref = function
  | Surface_ast.Named name -> Kernel.Named name
  | Surface_ast.Hashed hash -> Kernel.Hashed hash

let generated_meta ~form start_meta end_meta =
  match (Meta.span start_meta, Meta.span end_meta) with
  | Some start_span, Some end_span ->
      Ok
        (start_meta
        |> Meta.with_span (Span.merge start_span end_span)
        |> Meta.with_surface_form form)
  | _ ->
      error ~meta:start_meta ~code:"E1234"
        (Printf.sprintf "cannot lower generated `%s` node without source spans" form)

let generated_single_meta ~form meta =
  match Meta.span meta with
  | Some _ -> Ok (Meta.with_surface_form form meta)
  | None ->
      error ~meta ~code:"E1234"
        (Printf.sprintf "cannot lower generated `%s` node without a source span" form)

let rec lower_pat (pat : Surface_ast.pat) : (Kernel.pat, Diag.t list) result =
  let node it = Kernel.{ it; meta = pat.meta } in
  match pat.it with
  | Surface_ast.PWild -> Ok (node Kernel.PWild)
  | Surface_ast.PBind name -> Ok (node (Kernel.PVar name))
  | Surface_ast.PTuple items ->
      let* items = map_results lower_pat items in
      Ok (node (Kernel.PTuple items))
  | Surface_ast.PLit _ | Surface_ast.PCon _ | Surface_ast.PAs _ ->
      error ~meta:pat.meta ~code:"E1230"
        "SS.7 lowering accepts only irrefutable wildcard, binder, and tuple patterns"
  | Surface_ast.PHole _ ->
      error ~meta:pat.meta ~code:"E1202" "cannot lower a recovered surface pattern hole"

and lower_ty (ty : Surface_ast.ty) : (Kernel.ty, Diag.t list) result =
  let node it = Kernel.{ it; meta = ty.meta } in
  match ty.it with
  | Surface_ast.TyName name -> Ok (node (Kernel.TRef (Kernel.Named name)))
  | Surface_ast.TyVar name -> Ok (node (Kernel.TVar name))
  | Surface_ast.TyHash hash -> Ok (node (Kernel.TRef (Kernel.Hashed hash)))
  | Surface_ast.TyApp (head, args) ->
      let* head = lower_ty head in
      let* args = map_results lower_ty args in
      Ok (node (Kernel.TApp (head, args)))
  | Surface_ast.TyTuple items ->
      let* items = map_results lower_ty items in
      Ok (node (Kernel.TTuple items))
  | Surface_ast.TyArrow (params, row, result) ->
      let* params = map_results lower_ty params in
      let* result = lower_ty result in
      let row =
        Kernel.
          {
            effects = List.map kernel_gref row.Surface_ast.effects;
            rvar = row.tail;
            wmeta = row.row_meta;
          }
      in
      Ok (node (Kernel.TArrow (params, row, result)))
  | Surface_ast.TyForall (tyvars, rowvars, body) ->
      let* body = lower_ty body in
      Ok (node (Kernel.TForall (tyvars, rowvars, body)))
  | Surface_ast.TyHole _ ->
      error ~meta:ty.meta ~code:"E1202" "cannot lower a recovered surface type hole"

and lower_expr_node (expr : Surface_ast.expr) : (Kernel.expr, Diag.t list) result =
  let node it = Kernel.{ it; meta = expr.meta } in
  match expr.it with
  | Surface_ast.Lit literal -> Ok (node (Kernel.Lit literal))
  | Surface_ast.Name name -> Ok (node (Kernel.Var name))
  | Surface_ast.HashRef (hash, kind) -> Ok (node (Kernel.Ref (hash, kind)))
  | Surface_ast.GroupRef index -> Ok (node (Kernel.GroupRef index))
  | Surface_ast.Call (fn, args) ->
      let* fn = lower_expr_node fn in
      let* args = map_results lower_expr_node args in
      Ok (node (Kernel.App (fn, args)))
  | Surface_ast.Fn (params, body) ->
      let* params = map_results lower_pat params in
      let* body = lower_expr_node body in
      Ok Kernel.{ it = Lam (params, body); meta = Meta.with_surface_form "fn" expr.meta }
  | Surface_ast.Tuple items ->
      let* items = map_results lower_expr_node items in
      Ok (node (Kernel.Tuple items))
  | Surface_ast.Ann (subject, ty) ->
      let* subject = lower_expr_node subject in
      let* ty = lower_ty ty in
      Ok (node (Kernel.Ann (subject, ty)))
  | Surface_ast.Block items -> lower_block expr.meta items
  | Surface_ast.Hole _ ->
      error ~meta:expr.meta ~code:"E1202" "cannot lower a recovered surface expression hole"
  | Surface_ast.List _ | Surface_ast.Match _ | Surface_ast.If _ | Surface_ast.Pipe _
  | Surface_ast.Handle _ | Surface_ast.Quote _ | Surface_ast.Unquote _ ->
      error ~meta:expr.meta ~code:"E1230" "this surface form is not part of SS.7 lowering"

and lower_block block_meta = function
  | [] -> error ~meta:block_meta ~code:"E1231" "an expression block cannot be empty"
  | [ Surface_ast.Expr expression ] -> lower_expr_node expression
  | [ Surface_ast.Let { binder; value; _ } ] ->
      let span =
        match (Meta.span binder.Surface_ast.meta, Meta.span value.Surface_ast.meta) with
        | Some left, Some right -> Some (Span.merge left right)
        | Some span, None | None, Some span -> Some span
        | None, None -> Meta.span block_meta
      in
      Error
        [
          Diag.error ?span ~code:"E1232"
            "a block must end in an expression; a final local `let` has no value";
        ]
  | Surface_ast.Expr value :: rest ->
      let* value = lower_expr_node value in
      let* body = lower_block block_meta rest in
      let* binder_meta = generated_single_meta ~form:"block-sequence-wildcard" value.meta in
      let binder = Kernel.{ it = PWild; meta = binder_meta } in
      let* meta = generated_meta ~form:"block-sequence" value.meta body.meta in
      Ok Kernel.{ it = Let { isrec = false; binder; value; body }; meta }
  | Surface_ast.Let { recursive; binder; params; value } :: rest ->
      let* body = lower_block block_meta rest in
      if recursive then lower_recursive_let binder params value body
      else if params <> [] then
        error ~meta:binder.meta ~code:"E1233"
          "non-recursive local bindings cannot use function shorthand"
      else
        let* binder = lower_pat binder in
        let* value = lower_expr_node value in
        let* meta = generated_meta ~form:"let" binder.meta body.meta in
        Ok Kernel.{ it = Let { isrec = false; binder; value; body }; meta }

and lower_recursive_let (binder : Surface_ast.pat) params value body =
  match binder.it with
  | Surface_ast.PBind name ->
      let* params = map_results lower_pat params in
      let* value = lower_expr_node value in
      let* lambda_meta = generated_meta ~form:"let-rec-fn" binder.meta value.meta in
      let lambda = Kernel.{ it = Lam (params, value); meta = lambda_meta } in
      let kernel_binder = Kernel.{ it = PVar name; meta = binder.meta } in
      let* meta = generated_meta ~form:"let-rec" binder.meta body.Kernel.meta in
      Ok Kernel.{ it = Let { isrec = true; binder = kernel_binder; value = lambda; body }; meta }
  | _ ->
      error ~meta:binder.meta ~code:"E1233"
        "`let rec` requires a lowercase name followed by a parameter list"

(** [lower_expr expr] locally lowers an SS.7 expression to existing kernel forms without resolving
    store names. It returns span-bearing diagnostics for recovery holes, unsupported later-slice
    forms, malformed recursive bindings, empty blocks, final local lets, or missing spans needed by
    generated sequence nodes. *)
let lower_expr = lower_expr_node
