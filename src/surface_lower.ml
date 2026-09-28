(** Local lowering from recoverable surface syntax to the fixed 27-form kernel.

    This pass performs no store lookup. Names remain unresolved [Kernel.Var] nodes, while explicit
    hash and group references lower directly. *)

let ( let* ) = Result.bind

let diagnostic_spec = function
  | "E0204" ->
      ( Diag.Kernel,
        "An unquote appears outside a quote.",
        "Move the unquote inside a quote or remove the unquote wrapper." )
  | "E0205" ->
      ( Diag.Kernel,
        "A lambda parameter uses a refutable pattern.",
        "Use an irrefutable variable, wildcard, tuple, or as-pattern parameter." )
  | "E0206" ->
      ( Diag.Kernel,
        "A let binder uses a refutable pattern.",
        "Use an irrefutable variable, wildcard, tuple, or as-pattern binder." )
  | "E0209" -> (Diag.Kernel, "A match expression has no clauses.", "Add at least one match clause.")
  | "E1202" ->
      ( Diag.Surface,
        "Recovered syntax cannot be lowered.",
        "Fix the reported syntax damage before lowering the source." )
  | "E1230" ->
      ( Diag.Surface,
        "This surface node is outside the supported lowering boundary.",
        "Rewrite the node using the currently supported surface forms." )
  | "E1231" ->
      (Diag.Surface, "An expression block is empty.", "Add a final expression to the block.")
  | "E1232" ->
      ( Diag.Surface,
        "A local let is the final item in a block.",
        "Add an expression after the local let to produce the block value." )
  | "E1233" ->
      ( Diag.Surface,
        "A local recursive or function binding is malformed.",
        "Rewrite the binding with one supported name, parameter list, and body." )
  | "E1234" ->
      ( Diag.Surface,
        "A generated lowering node has no real source span.",
        "Preserve source spans on every surface node passed to lowering." )
  | "E1235" ->
      ( Diag.Surface,
        "A surface declaration is missing its required file context.",
        "Lower the complete ordered top-level file instead of this isolated declaration." )
  | "E1236" ->
      ( Diag.Surface,
        "An effect operation mode is missing or invalid.",
        "Declare the operation explicitly as once or multi." )
  | "E1237" ->
      ( Diag.Surface,
        "A labeled constructor pattern cannot be quoted.",
        "Use an explicit positional pattern inside `quote`, or move the labeled match outside the \
         quoted payload." )
  | "E1238" ->
      ( Diag.Surface,
        "A named call argument cannot be quoted.",
        "Use positional arguments inside `quote`, or move the named call outside the quoted \
         payload." )
  | "E1239" ->
      ( Diag.Surface,
        "A constructor declares the same field label twice.",
        "Give each field of the constructor a distinct label." )
  | "E1240" ->
      ( Diag.Surface,
        "A field label has different types in different constructors of one type.",
        "Use one field type for the label across the type's constructors, or rename one of the \
         labels." )
  | "E1241" ->
      ( Diag.Surface,
        "A generated field accessor collides with a name this file declares.",
        "Rename that declaration or the field label; the accessor is generated from the label." )
  | "E1243" ->
      ( Diag.Surface,
        "A block ends in `try`.",
        "Write the final expression itself; its Result is already the block's value." )
  | code -> raise (Diag.Bug_invalid_diagnostic ("unknown surface lowering code " ^ code))

let diagnostic ?span ~code cause =
  let domain, summary, next_step = diagnostic_spec code in
  Diag.error ?span ~domain ~code ~summary ~cause ~next_step ~contrast:None ()

let error ?meta ~code cause = Error [ diagnostic ?span:(Option.bind meta Meta.span) ~code cause ]

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
        (start_meta |> Meta.without_trivia
        |> Meta.with_span (Span.merge start_span end_span)
        |> Meta.with_surface_form form)
  | _ ->
      error ~meta:start_meta ~code:"E1234"
        (Printf.sprintf "cannot lower generated `%s` node without source spans" form)

let generated_single_meta ~form meta =
  match Meta.span meta with
  | Some _ -> Ok (meta |> Meta.without_trivia |> Meta.with_surface_form form)
  | None ->
      error ~meta ~code:"E1234"
        (Printf.sprintf "cannot lower generated `%s` node without a source span" form)

let generated_constructor_meta ~form meta =
  let* meta = generated_single_meta ~form meta in
  Ok (meta |> Meta.with_surface_generated form |> Meta.with_surface_ref_kind "con")

let has_call_labels expressions =
  List.exists
    (fun (expression : Surface_ast.expr) ->
      Option.is_some (Meta.surface_call_label expression.meta))
    expressions

let rec first_named_call_meta (expression : Surface_ast.expr) =
  let expressions values = List.find_map first_named_call_meta values in
  match expression.it with
  | Surface_ast.Call (_, arguments) when has_call_labels arguments -> Some expression.meta
  | Surface_ast.Call (fn, arguments) -> (
      match first_named_call_meta fn with Some _ as found -> found | None -> expressions arguments)
  | Surface_ast.Interpolation parts ->
      List.find_map
        (function
          | Surface_ast.IText _ -> None | Surface_ast.IExpr item -> first_named_call_meta item)
        parts
  | Surface_ast.Fn (_, body) | Surface_ast.Unquote body | Surface_ast.Ann (body, _) ->
      first_named_call_meta body
  | Surface_ast.Tuple items | Surface_ast.List items -> expressions items
  | Surface_ast.Block items ->
      List.find_map
        (function
          | Surface_ast.Expr item -> first_named_call_meta item
          | Surface_ast.Let binding -> first_named_call_meta binding.value
          | Surface_ast.Try item -> first_named_call_meta item.value)
        items
  | Surface_ast.Match (subject, clauses) -> (
      match first_named_call_meta subject with
      | Some _ as found -> found
      | None ->
          List.find_map
            (fun (clause : Surface_ast.clause) -> first_named_call_meta clause.cbody)
            clauses)
  | Surface_ast.If (condition, yes, no) -> expressions [ condition; yes; no ]
  | Surface_ast.Pipe (left, right) -> expressions [ left; right ]
  | Surface_ast.Handle (body, ret, operations) -> (
      match first_named_call_meta body with
      | Some _ as found -> found
      | None -> (
          match first_named_call_meta ret.Surface_ast.rbody with
          | Some _ as found -> found
          | None ->
              List.find_map
                (fun (operation : Surface_ast.op_clause) -> first_named_call_meta operation.obody)
                operations))
  | Surface_ast.Quote (Surface_ast.Surface body) -> first_named_call_meta body
  | Surface_ast.Quote (Surface_ast.Raw _)
  | Surface_ast.Lit _ | Surface_ast.Name _ | Surface_ast.HashRef _ | Surface_ast.GroupRef _
  | Surface_ast.Hole _ ->
      None

let rec lower_pat_at ~quote_depth (pat : Surface_ast.pat) : (Kernel.pat, Diag.t list) result =
  let node it = Kernel.{ it; meta = pat.meta } in
  if quote_depth > 0 && Meta.surface_form pat.meta = Some "labeled-pattern" then
    error ~meta:pat.meta ~code:"E1237"
      "quoted code stores positional kernel patterns and cannot retain a surface field selection"
  else
    match pat.it with
    | Surface_ast.PWild -> Ok (node Kernel.PWild)
    | Surface_ast.PBind name -> Ok (node (Kernel.PVar name))
    | Surface_ast.PLit literal -> Ok (node (Kernel.PLit literal))
    | Surface_ast.PCon (constructor, args) ->
        let* args = map_results (lower_pat_at ~quote_depth) args in
        Ok (node (Kernel.PCon (kernel_gref constructor, args)))
    | Surface_ast.PTuple items ->
        let* items = map_results (lower_pat_at ~quote_depth) items in
        Ok (node (Kernel.PTuple items))
    | Surface_ast.PAs (inner, name) ->
        let* inner = lower_pat_at ~quote_depth inner in
        Ok (node (Kernel.PAs (name, inner)))
    | Surface_ast.PHole _ ->
        error ~meta:pat.meta ~code:"E1202" "cannot lower a recovered surface pattern hole"

(** [lower_pat pat] lowers any complete surface pattern outside a quoted payload without resolving
    constructor names. Recovery holes fail with E1202. *)
let lower_pat pat = lower_pat_at ~quote_depth:0 pat

let ensure_irrefutable ~code ~message (pat : Kernel.pat) =
  if Kernel.is_irrefutable pat then Ok pat else error ~meta:pat.meta ~code message

let lower_irrefutable_pat ?(quote_depth = 0) ~code ~message pat =
  let* pat = lower_pat_at ~quote_depth pat in
  ensure_irrefutable ~code ~message pat

let lower_lambda_params ?(quote_depth = 0) params =
  map_results
    (lower_irrefutable_pat ~quote_depth ~code:"E0205"
       ~message:
         "`lam` parameters must be irrefutable patterns (pwild, pvar, or ptuple/pas of those)")
    params

let validate_quote_payload meta payload =
  let wrapper = Form.form ~meta "quote" [ Form.F payload ] in
  match Kernel.expr_of_form wrapper with
  | Ok { Kernel.it = Kernel.Quote _; _ } -> Ok ()
  | Ok _ -> error ~meta ~code:"E1230" "internal quote validation produced a non-quote expression"
  | Error diagnostics -> Error diagnostics

(* Constructor and operation intent is semantic quoted data, not metadata. A level-0 unquote is an
   expression boundary and is resolved before hashing, so its payload must retain ordinary
   expression encoding. *)
let rec encode_quote_refs ?(level = 0) (form : Form.t) =
  if String.equal form.Form.head "unquote" && level = 0 then form
  else
    match (form.Form.head, form.Form.args, Meta.surface_ref_kind form.Form.meta) with
    | "var", [ Form.Sym name ], Some (("con" | "op") as kind) ->
        { form with Form.head = Kernel.surface_ref_head; args = [ Form.Sym kind; Form.Sym name ] }
    | _ ->
        let level =
          match form.Form.head with "quote" -> level + 1 | "unquote" -> level - 1 | _ -> level
        in
        {
          form with
          Form.args =
            List.map
              (function
                | Form.F child -> Form.F (encode_quote_refs ~level child) | scalar -> scalar)
              form.Form.args;
        }

(** [lower_ty ty] lowers a complete surface type without resolving named type/effect references. *)
let rec lower_ty (ty : Surface_ast.ty) : (Kernel.ty, Diag.t list) result =
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
      let* () =
        match row.row_hole with
        | None -> Ok ()
        | Some _ ->
            error ~meta:row.row_meta ~code:"E1202"
              "cannot lower a recovered surface effect-row hole"
      in
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

and lower_expr_node ?(quote_depth = 0) (expr : Surface_ast.expr) : (Kernel.expr, Diag.t list) result
    =
  let node it = Kernel.{ it; meta = expr.meta } in
  match expr.it with
  | Surface_ast.Lit literal -> Ok (node (Kernel.Lit literal))
  | Surface_ast.Interpolation parts ->
      let lower_part = function
        | Surface_ast.IText (text, meta) ->
            Ok
              Kernel.
                {
                  it = Lit (LText text);
                  meta = Meta.with_surface_generated "interpolation-text" meta;
                }
        | Surface_ast.IExpr expression -> lower_expr_node ~quote_depth expression
      in
      let* args = map_results lower_part parts in
      let fn =
        Kernel.
          {
            it = Var "text.join";
            meta =
              expr.meta |> Meta.without_trivia
              |> Meta.with_surface_generated "interpolation-callee"
              |> Meta.with_surface_reference;
          }
      in
      Ok Kernel.{ it = App (fn, args); meta = Meta.with_surface_form "interpolation" expr.meta }
  | Surface_ast.Name name -> Ok (node (Kernel.Var name))
  | Surface_ast.HashRef (hash, kind) -> Ok (node (Kernel.Ref (hash, kind)))
  | Surface_ast.GroupRef index -> Ok (node (Kernel.GroupRef index))
  | Surface_ast.Call (fn, args) ->
      let named = has_call_labels args in
      if quote_depth > 0 && named then
        error ~meta:expr.meta ~code:"E1238"
          "quoted code stores positional kernel applications and cannot retain named argument \
           labels"
      else
        let* fn = lower_expr_node ~quote_depth fn in
        let* args = map_results (lower_expr_node ~quote_depth) args in
        let surface_form_name = if named then "named-call" else "call" in
        Ok Kernel.{ it = App (fn, args); meta = Meta.with_surface_form surface_form_name expr.meta }
  | Surface_ast.Fn (params, body) ->
      let* params = lower_lambda_params ~quote_depth params in
      let* body = lower_expr_node ~quote_depth body in
      Ok Kernel.{ it = Lam (params, body); meta = Meta.with_surface_form "fn" expr.meta }
  | Surface_ast.Tuple items ->
      let* items = map_results (lower_expr_node ~quote_depth) items in
      Ok (node (Kernel.Tuple items))
  | Surface_ast.Ann (subject, ty) ->
      let* subject = lower_expr_node ~quote_depth subject in
      let* ty = lower_ty ty in
      Ok (node (Kernel.Ann (subject, ty)))
  | Surface_ast.Block items ->
      let* lowered = lower_block ~quote_depth expr.meta items in
      let meta = Meta.merge_trivia expr.meta lowered.Kernel.meta in
      let meta =
        match Meta.span lowered.Kernel.meta with
        | Some span -> Meta.with_span span meta
        | None -> meta
      in
      Ok { lowered with Kernel.meta }
  | Surface_ast.Match (subject, clauses) -> (
      let lower_clause (clause : Surface_ast.clause) =
        let* cpat = lower_pat_at ~quote_depth clause.cpattern in
        let* cbody = lower_expr_node ~quote_depth clause.cbody in
        Ok Kernel.{ cpat; cbody; cmeta = clause.cmeta }
      in
      let* subject = lower_expr_node ~quote_depth subject in
      match clauses with
      | [] -> error ~meta:expr.meta ~code:"E0209" "`match` requires at least one clause"
      | _ ->
          let* clauses = map_results lower_clause clauses in
          Ok (node (Kernel.Match (subject, clauses))))
  | Surface_ast.If (condition, yes, no) ->
      let* condition = lower_expr_node ~quote_depth condition in
      let* yes = lower_expr_node ~quote_depth yes in
      let* no = lower_expr_node ~quote_depth no in
      let* true_meta = generated_single_meta ~form:"if-true" condition.meta in
      let* false_meta = generated_single_meta ~form:"if-false" condition.meta in
      let* true_clause_meta = generated_single_meta ~form:"if-then" yes.meta in
      let* false_clause_meta = generated_single_meta ~form:"if-else" no.meta in
      let true_pat = Kernel.{ it = PCon (Named "true", []); meta = true_meta } in
      let false_pat = Kernel.{ it = PCon (Named "false", []); meta = false_meta } in
      let clauses =
        [
          Kernel.{ cpat = true_pat; cbody = yes; cmeta = true_clause_meta };
          Kernel.{ cpat = false_pat; cbody = no; cmeta = false_clause_meta };
        ]
      in
      Ok Kernel.{ it = Match (condition, clauses); meta = Meta.with_surface_form "if" expr.meta }
  | Surface_ast.List items -> (
      let* items = map_results (lower_expr_node ~quote_depth) items in
      (* Generated interior nodes descend from the list expression's metadata, but a call-site
         label or argument container belongs only to the whole list: an interior `cons` or `nil`
         must never present the enclosing argument's label to the list constructor's own ABI. *)
      let internal_meta ~form meta =
        let* meta = generated_single_meta ~form meta in
        Ok
          (meta
          |> Meta.without_surface_container "list"
          |> Meta.without_surface_container "call-argument"
          |> Meta.without_surface_call_label)
      in
      let* nil_meta = internal_meta ~form:"list-nil" expr.meta in
      let nil_meta =
        nil_meta |> Meta.with_surface_generated "list-nil" |> Meta.with_surface_ref_kind "con"
      in
      let nil = Kernel.{ it = Var "nil"; meta = nil_meta } in
      let rec build index = function
        | [] -> Ok nil
        | item :: rest ->
            let* tail = build (index + 1) rest in
            let* fn_meta =
              generated_constructor_meta ~form:"list-cons-constructor" item.Kernel.meta
            in
            let fn_meta = Meta.without_surface_container "list" fn_meta in
            let fn = Kernel.{ it = Var "cons"; meta = fn_meta } in
            let* generated_meta = generated_meta ~form:"list-tail" item.Kernel.meta expr.meta in
            let generated_meta = Meta.without_surface_container "list" generated_meta in
            let meta =
              if index = 0 then Meta.with_surface_form "list" expr.meta else generated_meta
            in
            Ok Kernel.{ it = App (fn, [ item; tail ]); meta }
      in
      match items with
      | [] ->
          Ok
            {
              nil with
              Kernel.meta =
                expr.meta |> Meta.with_surface_form "list"
                |> Meta.with_surface_generated "list"
                |> Meta.with_surface_ref_kind "con";
            }
      | _ -> build 0 items)
  | Surface_ast.Pipe (left, right) ->
      let* left = lower_expr_node ~quote_depth left in
      let* fn, args, right_meta =
        match right.Surface_ast.it with
        | Surface_ast.Call (fn, args) ->
            let named = has_call_labels args in
            if quote_depth > 0 && named then
              error ~meta:right.meta ~code:"E1238"
                "quoted code stores positional kernel applications and cannot retain named \
                 argument labels"
            else
              let* fn = lower_expr_node ~quote_depth fn in
              let* args = map_results (lower_expr_node ~quote_depth) args in
              let form = if named then "pipe-named-call" else "pipe-call" in
              Ok (fn, args, Meta.with_surface_form form right.meta)
        | _ ->
            let* right = lower_expr_node ~quote_depth right in
            Ok ({ right with Kernel.meta = Meta.without_trivia right.meta }, [], right.meta)
      in
      let meta = Meta.with_surface_container "pipe-rhs" right_meta expr.meta in
      let meta =
        match Meta.span expr.meta with Some span -> Meta.with_span span meta | None -> meta
      in
      Ok Kernel.{ it = App (fn, left :: args); meta = Meta.with_surface_form "pipe" meta }
  | Surface_ast.Handle (body, ret, ops) ->
      let lower_op (op : Surface_ast.op_clause) =
        let* params = map_results (lower_pat_at ~quote_depth) op.oparams in
        let* obody = lower_expr_node ~quote_depth op.obody in
        Ok
          Kernel.
            { op = kernel_gref op.operation; params; resume = op.oresume; obody; ometa = op.ometa }
      in
      let* body = lower_expr_node ~quote_depth body in
      let* rbinder = lower_pat_at ~quote_depth ret.rbinder in
      let* rbody = lower_expr_node ~quote_depth ret.rbody in
      let* ops = map_results lower_op ops in
      let ret = Kernel.{ rbinder; rbody; rmeta = ret.rmeta } in
      Ok (node (Kernel.Handle { body; ret; ops }))
  | Surface_ast.Quote quote_body ->
      let* payload =
        match quote_body with
        | Surface_ast.Raw payload -> Ok payload
        | Surface_ast.Surface body ->
            let* () =
              match first_named_call_meta body with
              | None -> Ok ()
              | Some meta ->
                  error ~meta ~code:"E1238"
                    "quoted code stores positional kernel applications and cannot retain named \
                     argument labels"
            in
            let* body = lower_expr_node ~quote_depth:(quote_depth + 1) body in
            Ok (encode_quote_refs (Kernel.expr_to_form body))
      in
      let* () = if quote_depth = 0 then validate_quote_payload expr.meta payload else Ok () in
      Ok (node (Kernel.Quote payload))
  | Surface_ast.Unquote splice ->
      if quote_depth = 0 then
        error ~meta:expr.meta ~code:"E0204" "`unquote` is only legal under `quote`"
      else
        let* splice = lower_expr_node ~quote_depth:(quote_depth - 1) splice in
        Ok (node (Kernel.Unquote splice))
  | Surface_ast.Hole _ ->
      error ~meta:expr.meta ~code:"E1202" "cannot lower a recovered surface expression hole"

and lower_block ~quote_depth block_meta = function
  | [] -> error ~meta:block_meta ~code:"E1231" "an expression block cannot be empty"
  | [ Surface_ast.Expr expression ] -> lower_expr_node ~quote_depth expression
  | [ Surface_ast.Let { value; meta = item_meta; _ } ] ->
      let span =
        match (Meta.span item_meta, Meta.span value.Surface_ast.meta) with
        | Some left, Some right -> Some (Span.merge left right)
        | Some span, None | None, Some span -> Some span
        | None, None -> Meta.span block_meta
      in
      Error
        [
          diagnostic ?span ~code:"E1232"
            "A block must end in an expression; a final local `let` has no value.";
        ]
  | [ Surface_ast.Try { meta = item_meta; _ } ] ->
      error ~meta:item_meta ~code:"E1243"
        "A block cannot end in `try`: the value of the final item is already the block's Result; \
         write the expression itself."
  | Surface_ast.Try { binder; value; meta = item_meta } :: rest ->
      (* SX.29 (D77): the rest of the block becomes the Ok arm; an Err is re-wrapped unchanged as
         the block's value. Plain kernel `match`; the hash equals the hand-written match. *)
      let* body = lower_block ~quote_depth block_meta rest in
      let* value = lower_expr_node ~quote_depth value in
      let* payload =
        match binder with
        | Some binder ->
            lower_irrefutable_pat ~quote_depth ~code:"E0206"
              ~message:"`let … = try` binders must be irrefutable patterns" binder
        | None ->
            let* meta = generated_single_meta ~form:"try-discard" value.Kernel.meta in
            Ok Kernel.{ it = PWild; meta }
      in
      let* ok_meta = generated_single_meta ~form:"try-ok" value.Kernel.meta in
      let* err_meta = generated_single_meta ~form:"try-err" value.Kernel.meta in
      let* err_binder_meta = generated_single_meta ~form:"try-err-binder" value.Kernel.meta in
      let* err_value_meta = generated_single_meta ~form:"try-err-value" value.Kernel.meta in
      let* err_constructor_meta =
        generated_constructor_meta ~form:"try-err-constructor" value.Kernel.meta
      in
      let* rewrap_meta = generated_single_meta ~form:"try-err-rewrap" value.Kernel.meta in
      let* ok_clause_meta = generated_single_meta ~form:"try-ok-clause" item_meta in
      let* err_clause_meta = generated_single_meta ~form:"try-err-clause" item_meta in
      let error_name = "error" in
      let clauses =
        [
          Kernel.
            {
              cpat = { it = PCon (Named "ok", [ payload ]); meta = ok_meta };
              cbody = body;
              cmeta = ok_clause_meta;
            };
          Kernel.
            {
              cpat =
                {
                  it = PCon (Named "err", [ { it = PVar error_name; meta = err_binder_meta } ]);
                  meta = err_meta;
                };
              cbody =
                {
                  it =
                    App
                      ( { it = Var "err"; meta = err_constructor_meta },
                        [ { it = Var error_name; meta = err_value_meta } ] );
                  meta = rewrap_meta;
                };
              cmeta = err_clause_meta;
            };
        ]
      in
      let form = match binder with Some _ -> "try" | None -> "try-bare" in
      let* meta = generated_meta ~form item_meta body.meta in
      let span = Meta.span meta in
      let meta = Meta.merge_trivia item_meta meta in
      let meta = match span with Some span -> Meta.with_span span meta | None -> meta in
      Ok Kernel.{ it = Match (value, clauses); meta }
  | Surface_ast.Expr value :: rest ->
      let* value = lower_expr_node ~quote_depth value in
      let* body = lower_block ~quote_depth block_meta rest in
      let* binder_meta = generated_single_meta ~form:"block-sequence-wildcard" value.meta in
      let binder = Kernel.{ it = PWild; meta = binder_meta } in
      let* meta = generated_meta ~form:"block-sequence" value.meta body.meta in
      Ok Kernel.{ it = Let { isrec = false; binder; value; body }; meta }
  | Surface_ast.Let { recursive; binder; params; value; meta = item_meta } :: rest ->
      let* body = lower_block ~quote_depth block_meta rest in
      if recursive then lower_recursive_let ~quote_depth ~item_meta binder params value body
      else if params <> [] then
        error ~meta:binder.meta ~code:"E1233"
          "non-recursive local bindings cannot use function shorthand"
      else
        let* binder =
          lower_irrefutable_pat ~quote_depth ~code:"E0206"
            ~message:"`let` binders must be irrefutable patterns" binder
        in
        let* value = lower_expr_node ~quote_depth value in
        let* meta = generated_meta ~form:"let" item_meta body.meta in
        let span = Meta.span meta in
        let meta = Meta.merge_trivia item_meta meta in
        let meta = match span with Some span -> Meta.with_span span meta | None -> meta in
        Ok Kernel.{ it = Let { isrec = false; binder; value; body }; meta }

and lower_recursive_let ~quote_depth ~item_meta (binder : Surface_ast.pat) params value body =
  match binder.it with
  | Surface_ast.PBind name ->
      let* params = lower_lambda_params ~quote_depth params in
      let* value = lower_expr_node ~quote_depth value in
      let* lambda_meta = generated_meta ~form:"let-rec-fn" binder.meta value.meta in
      let lambda_meta =
        Meta.with_surface_container "params" (Meta.surface_container "params" item_meta) lambda_meta
      in
      let lambda = Kernel.{ it = Lam (params, value); meta = lambda_meta } in
      let kernel_binder = Kernel.{ it = PVar name; meta = binder.meta } in
      let* meta = generated_meta ~form:"let-rec" item_meta body.Kernel.meta in
      let span = Meta.span meta in
      let meta = Meta.merge_trivia item_meta meta in
      let meta = match span with Some span -> Meta.with_span span meta | None -> meta in
      Ok Kernel.{ it = Let { isrec = true; binder = kernel_binder; value = lambda; body }; meta }
  | _ ->
      error ~meta:binder.meta ~code:"E1233"
        "`let rec` requires a lowercase name followed by a parameter list"

(** [lower_expr expr] locally lowers a surface expression to existing kernel forms without resolving
    store names. Handler operation intent and staged quote payloads are preserved; a top-level
    unquote fails with E0204, and a labeled pattern in quoted surface syntax fails with E1237. It
    also returns span-bearing diagnostics for recovery holes, unsupported later-slice forms,
    malformed recursive bindings, empty blocks, final local lets, or missing spans needed by
    generated sequence nodes. *)
let lower_expr expr = lower_expr_node expr

module String_set = Set.Make (String)

exception Bug_scc_schedule of string

let merge_meta left right =
  let merged = Meta.merge_trivia left right in
  match (Meta.span left, Meta.span right) with
  | Some left_span, Some right_span -> Meta.with_span (Span.merge left_span right_span) merged
  | Some _, None -> merged
  | None, Some span -> Meta.with_span span merged
  | None, None -> merged

let lower_definition ?annotation (top : Surface_ast.top) =
  match top.it with
  | Surface_ast.Definition { name; equation; params; value } ->
      let* annot =
        match annotation with
        | None -> Ok None
        | Some (_, ty) -> Result.map Option.some (lower_ty ty)
      in
      let* value = lower_expr_node value in
      let* value =
        if equation then
          let* params = lower_lambda_params params in
          Ok
            Kernel.
              {
                it = Lam (params, value);
                meta =
                  top.meta |> Meta.without_trivia
                  |> Meta.without_surface_container "params"
                  |> Meta.with_surface_form "equation-definition";
              }
        else Ok value
      in
      let bmeta =
        match annotation with
        | Some (signature_meta, _) ->
            let definition_meta =
              match (Meta.span signature_meta, Meta.span top.meta) with
              | Some signature_span, Some definition_span ->
                  Meta.with_span (Span.merge signature_span definition_span) top.meta
              | Some span, None -> Meta.with_span span top.meta
              | None, _ -> top.meta
            in
            Meta.with_signature signature_meta definition_meta
        | None -> top.meta
      in
      let bmeta = if equation then Meta.with_surface_form "equation-definition" bmeta else bmeta in
      Ok Kernel.{ bname = name; annot; value; bmeta }
  | _ -> error ~meta:top.meta ~code:"E1235" "expected a surface term definition"

let rec pattern_names (pat : Kernel.pat) =
  match pat.it with
  | Kernel.PWild | Kernel.PLit _ -> String_set.empty
  | Kernel.PVar name -> String_set.singleton name
  | Kernel.PCon (_, args) | Kernel.PTuple args ->
      List.fold_left
        (fun names arg -> String_set.union names (pattern_names arg))
        String_set.empty args
  | Kernel.PAs (name, inner) -> String_set.add name (pattern_names inner)

let quote_live_splices payload =
  let rec visit level (form : Form.t) =
    if String.equal form.Form.head "unquote" && level = 0 then
      match form.Form.args with
      | [ Form.F splice ] -> (
          match Kernel.expr_of_form splice with Ok expr -> [ expr ] | Error _ -> [])
      | _ -> []
    else
      let level =
        match form.Form.head with "quote" -> level + 1 | "unquote" -> level - 1 | _ -> level
      in
      List.concat_map (function Form.F child -> visit level child | _ -> []) form.Form.args
  in
  visit 0 payload

(** [free_names expr] returns unresolved term names read by [expr], excluding lexical pattern
    binders and quoted data. Only expressions in live unquotes contribute names from a quote. *)
let rec free_names (expr : Kernel.expr) =
  let unions expressions =
    List.fold_left
      (fun names expression -> String_set.union names (free_names expression))
      String_set.empty expressions
  in
  match expr.it with
  | Kernel.Lit _ | Kernel.Ref _ | Kernel.GroupRef _ -> String_set.empty
  | Kernel.Var name -> (
      match Meta.surface_ref_kind expr.meta with
      | Some ("con" | "op") -> String_set.empty
      | Some "term" | Some _ | None -> String_set.singleton name)
  | Kernel.Lam (params, body) ->
      let bound =
        List.fold_left
          (fun names param -> String_set.union names (pattern_names param))
          String_set.empty params
      in
      String_set.diff (free_names body) bound
  | Kernel.App (fn, args) -> String_set.union (free_names fn) (unions args)
  | Kernel.Let { isrec; binder; value; body } ->
      let bound = pattern_names binder in
      let value_names = free_names value in
      let value_names = if isrec then String_set.diff value_names bound else value_names in
      String_set.union value_names (String_set.diff (free_names body) bound)
  | Kernel.Match (subject, clauses) ->
      List.fold_left
        (fun names clause ->
          String_set.union names
            (String_set.diff (free_names clause.Kernel.cbody) (pattern_names clause.Kernel.cpat)))
        (free_names subject) clauses
  | Kernel.Tuple items -> unions items
  | Kernel.Handle { body; ret; ops } ->
      let names =
        String_set.union (free_names body)
          (String_set.diff (free_names ret.Kernel.rbody) (pattern_names ret.Kernel.rbinder))
      in
      List.fold_left
        (fun names operation ->
          let bound =
            List.fold_left
              (fun bound param -> String_set.union bound (pattern_names param))
              (String_set.singleton operation.Kernel.resume)
              operation.Kernel.params
          in
          String_set.union names (String_set.diff (free_names operation.Kernel.obody) bound))
        names ops
  | Kernel.Quote payload -> unions (quote_live_splices payload)
  | Kernel.Unquote splice -> free_names splice
  | Kernel.Ann (subject, _) -> free_names subject

let definition_edges bindings =
  let bindings = Array.of_list bindings in
  let by_name = Hashtbl.create (Array.length bindings) in
  Array.iteri
    (fun index binding ->
      let prior = Option.value ~default:[] (Hashtbl.find_opt by_name binding.Kernel.bname) in
      Hashtbl.replace by_name binding.Kernel.bname (index :: prior))
    bindings;
  let edges =
    Array.map
      (fun binding ->
        String_set.fold
          (fun name indices ->
            match Hashtbl.find_opt by_name name with
            | Some targets -> List.rev_append targets indices
            | None -> indices)
          (free_names binding.Kernel.value) []
        |> List.sort_uniq Int.compare)
      bindings
  in
  (bindings, edges)

let strongly_connected_components edges =
  let count = Array.length edges in
  let next_index = ref 0 in
  let indices = Array.make count (-1) in
  let lowlinks = Array.make count 0 in
  let on_stack = Array.make count false in
  let stack = Stack.create () in
  let components = ref [] in
  let rec visit vertex =
    indices.(vertex) <- !next_index;
    lowlinks.(vertex) <- !next_index;
    incr next_index;
    Stack.push vertex stack;
    on_stack.(vertex) <- true;
    List.iter
      (fun target ->
        if indices.(target) = -1 then begin
          visit target;
          lowlinks.(vertex) <- min lowlinks.(vertex) lowlinks.(target)
        end
        else if on_stack.(target) then lowlinks.(vertex) <- min lowlinks.(vertex) indices.(target))
      edges.(vertex);
    if lowlinks.(vertex) = indices.(vertex) then begin
      let members = ref [] in
      let finished = ref false in
      while not !finished do
        let member =
          match Stack.pop_opt stack with
          | Some member -> member
          | None -> raise (Bug_scc_schedule "Tarjan stack exhausted before its component root")
        in
        on_stack.(member) <- false;
        members := member :: !members;
        finished := member = vertex
      done;
      components := List.sort Int.compare !members :: !components
    end
  in
  for vertex = 0 to count - 1 do
    if indices.(vertex) = -1 then visit vertex
  done;
  Array.of_list (List.rev !components)

let dependency_first_components edges components =
  let component_of = Array.make (Array.length edges) (-1) in
  Array.iteri
    (fun component members -> List.iter (fun member -> component_of.(member) <- component) members)
    components;
  let dependencies =
    Array.mapi
      (fun component members ->
        List.concat_map (fun member -> edges.(member)) members
        |> List.filter_map (fun target ->
            let target_component = component_of.(target) in
            if target_component = component then None else Some target_component)
        |> List.sort_uniq Int.compare)
      components
  in
  let emitted = Array.make (Array.length components) false in
  let rec schedule remaining acc =
    if remaining = 0 then List.rev acc
    else
      let ready =
        List.init (Array.length components) Fun.id
        |> List.filter (fun component ->
            (not emitted.(component))
            && List.for_all (fun dependency -> emitted.(dependency)) dependencies.(component))
      in
      let component =
        List.fold_left
          (fun best candidate ->
            match best with
            | None -> Some candidate
            | Some current ->
                let first = function
                  | member :: _ -> member
                  | [] -> raise (Bug_scc_schedule "Tarjan emitted an empty component")
                in
                if first components.(candidate) < first components.(current) then Some candidate
                else best)
          None ready
      in
      let component =
        match component with
        | Some component -> component
        | None -> raise (Bug_scc_schedule "condensation graph has no dependency-ready component")
      in
      emitted.(component) <- true;
      schedule (remaining - 1) (component :: acc)
  in
  schedule (Array.length components) []

let duplicate_definition_diagnostics definitions =
  let seen = Hashtbl.create (List.length definitions) in
  List.filter_map
    (fun (top, _) ->
      match top.Surface_ast.it with
      | Surface_ast.Definition { name; _ } ->
          if Hashtbl.mem seen name then
            Some
              (Diag.error ?span:(Meta.span top.meta) ~domain:Resolution ~code:"E0303"
                 ~summary:"A definition run contains a duplicate binding name."
                 ~cause:
                   (Printf.sprintf "Binding `%s` appears more than once in this definition run."
                      name)
                 ~next_step:"Rename or remove the duplicate definition binding." ~contrast:None ())
          else begin
            Hashtbl.add seen name ();
            None
          end
      | _ -> None)
    definitions

let lower_definition_run definitions =
  match duplicate_definition_diagnostics definitions with
  | _ :: _ as diagnostics -> Error diagnostics
  | [] ->
      let* bindings =
        map_results (fun (top, annotation) -> lower_definition ?annotation top) definitions
      in
      let bindings, edges = definition_edges bindings in
      let components = strongly_connected_components edges in
      let order = dependency_first_components edges components in
      Ok
        (List.map
           (fun component ->
             let members = List.map (Array.get bindings) components.(component) in
             let meta =
               match members with
               | [] -> Meta.empty
               | first :: rest ->
                   List.fold_left
                     (fun meta binding ->
                       merge_meta meta (Meta.without_trivia binding.Kernel.bmeta))
                     (Meta.without_trivia first.Kernel.bmeta)
                     rest
             in
             Kernel.Decl
               Kernel.{ it = DefTerm members; meta = Meta.with_surface_form "definition-scc" meta })
           order)

(* --- D36 labeled fields: declaration validation and generated accessors (SX.27) --- *)

let surface_spelling kernel = Option.value (Surface_name.to_pascal kernel) ~default:kernel

(* Field types are compared before names resolve, so only a difference that resolution cannot
   erase is refused: effect rows compare as sets, and a type mentioning a hash reference is left to
   the checker, which still types the accessor's clauses against each other. *)
let rec mentions_hash (ty : Kernel.ty) =
  match ty.it with
  | Kernel.TRef (Kernel.Hashed _) -> true
  | Kernel.TRef (Kernel.Named _) | Kernel.TVar _ -> false
  | Kernel.TApp (fn, args) -> mentions_hash fn || List.exists mentions_hash args
  | Kernel.TArrow (params, row, result) ->
      List.exists mentions_hash params
      || List.exists (function Kernel.Hashed _ -> true | Kernel.Named _ -> false) row.effects
      || mentions_hash result
  | Kernel.TTuple items -> List.exists mentions_hash items
  | Kernel.TForall (_, _, body) -> mentions_hash body

let rec with_sorted_rows (ty : Kernel.ty) : Kernel.ty =
  let gref_key = function Kernel.Named name -> name | Kernel.Hashed hash -> Hash.to_hex hash in
  let it =
    match ty.it with
    | Kernel.TRef _ | Kernel.TVar _ -> ty.it
    | Kernel.TApp (fn, args) -> Kernel.TApp (with_sorted_rows fn, List.map with_sorted_rows args)
    | Kernel.TArrow (params, row, result) ->
        let effects =
          List.sort (fun left right -> String.compare (gref_key left) (gref_key right)) row.effects
        in
        Kernel.TArrow
          (List.map with_sorted_rows params, { row with effects }, with_sorted_rows result)
    | Kernel.TTuple items -> Kernel.TTuple (List.map with_sorted_rows items)
    | Kernel.TForall (tvars, rvars, body) -> Kernel.TForall (tvars, rvars, with_sorted_rows body)
  in
  { ty with it }

let field_types_differ (left : Kernel.ty) (right : Kernel.ty) =
  (not (mentions_hash left || mentions_hash right))
  && not
       (Form.equal_ignoring_meta
          (Kernel.ty_to_form (with_sorted_rows left))
          (Kernel.ty_to_form (with_sorted_rows right)))

(** [field_label_errors ~type_name constructors] rejects a label declared twice by one constructor
    (E1239) and a label whose field type differs between constructors (E1240), at the later field. A
    label that only some constructors carry is valid; it simply has no generated accessor. *)
let field_label_errors ~type_name (constructors : Kernel.conspec list) =
  let rec check_constructors seen = function
    | [] -> Ok ()
    | (constructor : Kernel.conspec) :: rest ->
        let rec check_fields own seen = function
          | [] -> check_constructors seen rest
          | (field : Kernel.field) :: fields -> (
              match field.label with
              | None -> check_fields own seen fields
              | Some label when List.mem label own ->
                  error ~meta:field.fmeta ~code:"E1239"
                    (Printf.sprintf
                       "constructor `%s` of type `%s` declares the field label `%s` twice"
                       (surface_spelling constructor.con_name)
                       (surface_spelling type_name) label)
              | Some label -> (
                  match List.assoc_opt label seen with
                  | Some (first_constructor, first_ty) when field_types_differ first_ty field.fty ->
                      error ~meta:field.fmeta ~code:"E1240"
                        (Printf.sprintf
                           "field label `%s` of type `%s` has one type in constructor `%s` and a \
                            different type in constructor `%s`"
                           label (surface_spelling type_name)
                           (surface_spelling first_constructor)
                           (surface_spelling constructor.con_name))
                  | Some _ -> check_fields (label :: own) seen fields
                  | None ->
                      check_fields (label :: own)
                        ((label, (constructor.con_name, field.fty)) :: seen)
                        fields))
        in
        check_fields [] seen constructor.fields
  in
  check_constructors [] constructors

(** [accessor_marker] is the [surface-generated] provenance of a D36 accessor declaration. *)
let accessor_marker = "constructor-accessor"

(** [setter_marker] is the [surface-generated] provenance of an SX.28 setter declaration. *)
let setter_marker = "constructor-setter"

(** [is_generated_accessor top] holds for a declaration generated from a labeled field, an accessor
    or a setter. Signature listings omit these, as the printer does, so generated boilerplate is
    never shown. *)
let is_generated_accessor = function
  | Kernel.Decl declaration -> (
      match Meta.surface_generated declaration.meta with
      | Some marker -> marker = accessor_marker || marker = setter_marker
      | None -> false)
  | Kernel.Expr _ -> false

(** [accessor_name ~type_name label] is the D36 accessor name [<type-kebab>.<label>]. *)
let accessor_name ~type_name label = type_name ^ "." ^ label

(** [setter_name ~type_name label] is the SX.28 setter name [<type-kebab>.with-<label>]. *)
let setter_name ~type_name label = type_name ^ ".with-" ^ label

(** [eligible_labels ~type_name constructors] are the labels of the first constructor that every
    constructor carries, in declaration order, whose accessor name is a valid symbol (an escaped
    type name ending in [?] or [!] has no dotted namespace). Only these have a pure, total accessor;
    E1239 and E1240 have already made each such label unique within its constructor and uniformly
    typed. *)
let eligible_labels ~type_name (constructors : Kernel.conspec list) =
  match constructors with
  | [] -> []
  | first :: rest ->
      List.filter_map (fun (field : Kernel.field) -> field.label) first.fields
      |> List.filter (fun label ->
          Reader.valid_symbol (accessor_name ~type_name label)
          && List.for_all
               (fun (constructor : Kernel.conspec) ->
                 List.exists
                   (fun (field : Kernel.field) -> field.label = Some label)
                   constructor.fields)
               rest)

(** [generated_accessor ~type_name constructors label] is the ordinary pure definition
    [<type>.<label>(value) = match value { | C(label: field) -> field ... }], one clause per
    constructor. Every node carries the first labeled field's span and [surface-generated]
    provenance, which canonical identity excludes and the surface printer suppresses. *)
let generated_accessor ~type_name (constructors : Kernel.conspec list) label =
  let origin =
    List.find
      (fun (field : Kernel.field) -> field.label = Some label)
      (List.hd constructors).Kernel.fields
  in
  let meta = origin.fmeta |> Meta.without_trivia |> Meta.with_surface_generated accessor_marker in
  let node it = Kernel.{ it; meta } in
  let clause (constructor : Kernel.conspec) =
    let arguments =
      List.map
        (fun (field : Kernel.field) ->
          node (if field.label = Some label then Kernel.PVar "field" else Kernel.PWild))
        constructor.fields
    in
    Kernel.
      {
        cpat = node (PCon (Named constructor.con_name, arguments));
        cbody = node (Var "field");
        cmeta = meta;
      }
  in
  let value =
    node
      (Kernel.Lam
         ( [ node (Kernel.PVar "value") ],
           node (Kernel.Match (node (Kernel.Var "value"), List.map clause constructors)) ))
  in
  Kernel.Decl
    {
      it = DefTerm [ { bname = accessor_name ~type_name label; annot = None; value; bmeta = meta } ];
      meta;
    }

(** [generated_setter ~type_name constructors label] is the ordinary pure definition
    [<type>.with-<label>(value, <label>: field) = match value { | C(a, _, c) -> C(a, field, c) ...
     }], one clause per constructor, each rebuilding the constructor it matched with the one field
    replaced. The second parameter carries the field's label as its call label, so the store derives
    the [call-abi-v1] companion (positional, named <label>) and a call reads
    [rota-staff.with-available(person, available: Nil)]. Its identity is its hand-written twin's:
    binder names and provenance are not part of [HASH_V0]. A type-changing update of a parametric
    field falls out of the twin's inferred scheme. *)
let generated_setter ~type_name (constructors : Kernel.conspec list) label =
  let origin =
    List.find
      (fun (field : Kernel.field) -> field.label = Some label)
      (List.hd constructors).Kernel.fields
  in
  let meta = origin.fmeta |> Meta.without_trivia |> Meta.with_surface_generated setter_marker in
  let node it = Kernel.{ it; meta } in
  let kept index = Printf.sprintf "kept-%d" index in
  let clause (constructor : Kernel.conspec) =
    let arguments =
      List.mapi
        (fun index (field : Kernel.field) ->
          node (if field.label = Some label then Kernel.PWild else Kernel.PVar (kept index)))
        constructor.fields
    in
    let rebuilt =
      List.mapi
        (fun index (field : Kernel.field) ->
          node (Kernel.Var (if field.label = Some label then "field" else kept index)))
        constructor.fields
    in
    let callee =
      Kernel.{ it = Var constructor.con_name; meta = Meta.with_surface_ref_kind "con" meta }
    in
    Kernel.
      {
        cpat = node (PCon (Named constructor.con_name, arguments));
        cbody = node (App (callee, rebuilt));
        cmeta = meta;
      }
  in
  let value =
    node
      (Kernel.Lam
         ( [
             node (Kernel.PVar "value");
             Kernel.{ it = PVar "field"; meta = Meta.with_surface_call_label label meta };
           ],
           node (Kernel.Match (node (Kernel.Var "value"), List.map clause constructors)) ))
  in
  Kernel.Decl
    {
      it = DefTerm [ { bname = setter_name ~type_name label; annot = None; value; bmeta = meta } ];
      meta;
    }

(** [generated_accessors ~explicit_terms ~type_name constructors] generates one accessor per
    eligible label, refusing with E1241 an accessor whose name an explicit term of the same file
    already defines. *)
let generated_accessors ~explicit_terms ~type_name (constructors : Kernel.conspec list) =
  map_results
    (fun label ->
      let name = accessor_name ~type_name label in
      if List.mem name explicit_terms then
        let origin =
          List.find
            (fun (field : Kernel.field) -> field.label = Some label)
            (List.hd constructors).Kernel.fields
        in
        error ~meta:origin.fmeta ~code:"E1241"
          (Printf.sprintf
             "the accessor `%s` generated for field label `%s` of type `%s` collides with `%s`, \
              which this file declares explicitly"
             name label (surface_spelling type_name) name)
      else Ok (generated_accessor ~type_name constructors label))
    (eligible_labels ~type_name constructors)

(** [generated_setters ~explicit_terms ~type_name constructors] generates one setter per label that
    earns an accessor (SX.28, DES.4 Phase 1), refusing with E1241 a setter whose name an explicit
    term of the file or one of the type's own accessors already binds. *)
let generated_setters ~explicit_terms ~type_name (constructors : Kernel.conspec list) =
  let labels = eligible_labels ~type_name constructors in
  let accessors = List.map (accessor_name ~type_name) labels in
  map_results
    (fun label ->
      let name = setter_name ~type_name label in
      if List.mem name explicit_terms || List.mem name accessors then
        let origin =
          List.find
            (fun (field : Kernel.field) -> field.label = Some label)
            (List.hd constructors).Kernel.fields
        in
        error ~meta:origin.fmeta ~code:"E1241"
          (Printf.sprintf
             "the setter `%s` generated for field label `%s` of type `%s` collides with `%s`, \
              which this file or the type's own field accessors already bind"
             name label (surface_spelling type_name) name)
      else Ok (generated_setter ~type_name constructors label))
    (List.filter (fun label -> Reader.valid_symbol (setter_name ~type_name label)) labels)

let lower_nonterm_top (top : Surface_ast.top) =
  match top.it with
  | Surface_ast.TopExpr expr -> Result.map (fun expr -> Kernel.Expr expr) (lower_expr_node expr)
  | Surface_ast.TypeDecl { name; vars; constructors } ->
      let lower_field (field : Surface_ast.field) =
        let* fty = lower_ty field.ty in
        Ok Kernel.{ label = field.label; fty; fmeta = field.meta }
      in
      let lower_constructor (constructor : Surface_ast.constructor) =
        let* fields = map_results lower_field constructor.fields in
        Ok Kernel.{ con_name = constructor.name; fields; kmeta = constructor.meta }
      in
      let* cons = map_results lower_constructor constructors in
      let* () = field_label_errors ~type_name:name cons in
      (* accessors need the whole file (E1241); [lower_tops] generates them after this decl *)
      Ok (Kernel.Decl Kernel.{ it = DefType { tname = name; tvars = vars; cons }; meta = top.meta })
  | Surface_ast.EffectDecl { name; vars; operations } ->
      let lower_operation (operation : Surface_ast.operation) =
        let* op_mode =
          match operation.mode with
          | Some mode -> Ok mode
          | None ->
              error ~meta:operation.meta ~code:"E1236"
                (Printf.sprintf
                   "surface effect operation `%s` requires an explicit `once` or `multi` mode; \
                    during migration, choose `once` unless its handler deliberately searches, \
                    captures, or reuses continuations"
                   operation.name)
        in
        let* op_params = map_results lower_ty operation.params in
        let* op_result = lower_ty operation.result in
        Ok
          Kernel.{ op_name = operation.name; op_mode; op_params; op_result; smeta = operation.meta }
      in
      let* ops = map_results lower_operation operations in
      Ok
        (Kernel.Decl Kernel.{ it = DefEffect { ename = name; evars = vars; ops }; meta = top.meta })
  | Surface_ast.RawTop form ->
      let* lowered = Kernel.of_form form in
      let merge_raw_meta kernel_meta =
        let merged = Meta.merge_trivia top.meta (Meta.without_trivia kernel_meta) in
        let merged =
          match Meta.span top.meta with Some span -> Meta.with_span span merged | None -> merged
        in
        merged
        |> Meta.with_surface_container "bootstrap" kernel_meta
        |> Meta.with_surface_form "raw-top"
      in
      Ok
        (match lowered with
        | Kernel.Expr expr -> Kernel.Expr { expr with Kernel.meta = merge_raw_meta expr.meta }
        | Kernel.Decl decl -> Kernel.Decl { decl with Kernel.meta = merge_raw_meta decl.meta })
  | Surface_ast.TopHole _ ->
      error ~meta:top.meta ~code:"E1202" "cannot lower a recovered surface top-level hole"
  | Surface_ast.Signature _ | Surface_ast.Definition _ ->
      error ~meta:top.meta ~code:"E1235"
        "term signatures and definitions must be lowered in file context"

(** [lower_top top] lowers one non-signature top-level item. A definition is treated as a singleton
    run, so self-reference still resolves through its enclosing [DefTerm]. A signature requires
    [lower_tops] so its adjacency can be preserved. *)
let lower_top top =
  match top.Surface_ast.it with
  | Surface_ast.Definition _ -> (
      let* lowered = lower_definition_run [ (top, None) ] in
      match lowered with
      | [ lowered ] -> Ok lowered
      | _ -> raise (Bug_scc_schedule "a singleton definition run did not produce one component"))
  | _ -> lower_nonterm_top top

(** [accessor_names top] computes the eligible accessor names from surface labels alone. *)
let accessor_names (top : Surface_ast.top) =
  match top.it with
  | Surface_ast.TypeDecl { name; constructors; _ } -> (
      let type_name = Option.value (Surface_name.of_pascal name) ~default:name in
      let labels (constructor : Surface_ast.constructor) =
        List.filter_map (fun (field : Surface_ast.field) -> field.label) constructor.fields
      in
      match constructors with
      | [] -> []
      | first :: rest ->
          labels first
          |> List.filter (fun label -> List.for_all (fun c -> List.mem label (labels c)) rest)
          |> List.concat_map (fun label ->
              [ accessor_name ~type_name label; setter_name ~type_name label ])
          |> List.filter Reader.valid_symbol)
  | _ -> []

(** [explicit_term_names tops] are the names the file's own definitions, effect operations, and raw
    bootstrap [defterm] tops bind, which generated accessors must not collide with (E1241). *)
let explicit_term_names tops =
  List.concat_map
    (fun (top : Surface_ast.top) ->
      match top.it with
      | Surface_ast.Definition { name; _ } -> [ name ]
      | Surface_ast.EffectDecl { operations; _ } ->
          List.map (fun (operation : Surface_ast.operation) -> operation.name) operations
      | Surface_ast.RawTop form -> (
          match Kernel.of_form form with
          | Ok (Kernel.Decl { it = Kernel.DefTerm bindings; _ }) ->
              List.map (fun (binding : Kernel.binding) -> binding.bname) bindings
          | Ok _ | Error _ -> [])
      | _ -> [])
    tops

(** [lower_tops tops] lowers a complete strictly parsed file. It attaches each signature to its
    adjacent same-name definition, partitions uninterrupted definition runs into exact SCCs, and
    emits SCC declarations dependency-first with source-stable ties. Bare expressions and type,
    effect, or raw declarations retain document order and break definition runs. Each surface type
    declaration is followed by its generated D36 field accessors ({!generated_accessors}); an
    accessor whose name an explicit definition of the file also defines fails with E1241. *)
let lower_tops ?explicit_terms tops =
  let explicit_terms =
    match explicit_terms with Some names -> names | None -> explicit_term_names tops
  in
  let flush acc run =
    match run with
    | [] -> Ok acc
    | _ ->
        let* lowered = lower_definition_run (List.rev run) in
        Ok (List.rev_append lowered acc)
  in
  let rec loop acc run = function
    | [] ->
        let* acc = flush acc run in
        Ok (List.rev acc)
    | ({ Surface_ast.it = Surface_ast.Signature (name, ty); _ } as signature)
      :: ({ Surface_ast.it = Surface_ast.Definition definition; _ } as definition_top)
      :: rest
      when String.equal name definition.name ->
        loop acc ((definition_top, Some (signature.meta, ty)) :: run) rest
    | ({ Surface_ast.it = Surface_ast.Signature _; _ } as signature) :: _ ->
        error ~meta:signature.meta ~code:"E1235"
          "a signature must be immediately followed by a definition of the same name"
    | ({ Surface_ast.it = Surface_ast.Definition _; _ } as definition) :: rest ->
        loop acc ((definition, None) :: run) rest
    | source :: rest -> (
        let* acc = flush acc run in
        let* top = lower_nonterm_top source in
        match top with
        (* D36: only a surface type declaration generates accessors, since only it is validated
           here; a raw bootstrap declaration keeps the bootstrap carrier's meaning *)
        | Kernel.Decl { it = DefType { tname; cons; _ }; _ }
          when match source.Surface_ast.it with Surface_ast.TypeDecl _ -> true | _ -> false ->
            let* accessors = generated_accessors ~explicit_terms ~type_name:tname cons in
            let* setters = generated_setters ~explicit_terms ~type_name:tname cons in
            loop (List.rev_append setters (List.rev_append accessors (top :: acc))) [] rest
        | _ -> loop (top :: acc) [] rest)
  in
  loop [] [] tops

type file = { tops : Kernel.top list; meta : Meta.t }

(** [lower_file file] lowers all tops while retaining the hash-excluded file trivia anchor. *)
let lower_file (file : Surface_ast.file) =
  let* tops = lower_tops file.tops in
  Ok { tops; meta = file.meta }
