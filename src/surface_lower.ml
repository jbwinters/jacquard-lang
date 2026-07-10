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

(** [lower_pat pat] lowers any complete surface pattern without resolving constructor names. *)
let rec lower_pat (pat : Surface_ast.pat) : (Kernel.pat, Diag.t list) result =
  let node it = Kernel.{ it; meta = pat.meta } in
  match pat.it with
  | Surface_ast.PWild -> Ok (node Kernel.PWild)
  | Surface_ast.PBind name -> Ok (node (Kernel.PVar name))
  | Surface_ast.PLit literal -> Ok (node (Kernel.PLit literal))
  | Surface_ast.PCon (constructor, args) ->
      let* args = map_results lower_pat args in
      Ok (node (Kernel.PCon (kernel_gref constructor, args)))
  | Surface_ast.PTuple items ->
      let* items = map_results lower_pat items in
      Ok (node (Kernel.PTuple items))
  | Surface_ast.PAs (inner, name) ->
      let* inner = lower_pat inner in
      Ok (node (Kernel.PAs (name, inner)))
  | Surface_ast.PHole _ ->
      error ~meta:pat.meta ~code:"E1202" "cannot lower a recovered surface pattern hole"

let ensure_irrefutable ~code ~message (pat : Kernel.pat) =
  if Kernel.is_irrefutable pat then Ok pat else error ~meta:pat.meta ~code message

let lower_irrefutable_pat ~code ~message pat =
  let* pat = lower_pat pat in
  ensure_irrefutable ~code ~message pat

let lower_lambda_params params =
  map_results
    (lower_irrefutable_pat ~code:"E0205"
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
  | Surface_ast.Name name -> Ok (node (Kernel.Var name))
  | Surface_ast.HashRef (hash, kind) -> Ok (node (Kernel.Ref (hash, kind)))
  | Surface_ast.GroupRef index -> Ok (node (Kernel.GroupRef index))
  | Surface_ast.Call (fn, args) ->
      let* fn = lower_expr_node ~quote_depth fn in
      let* args = map_results (lower_expr_node ~quote_depth) args in
      Ok (node (Kernel.App (fn, args)))
  | Surface_ast.Fn (params, body) ->
      let* params = lower_lambda_params params in
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
        let* cpat = lower_pat clause.cpattern in
        let* cbody = lower_expr_node ~quote_depth clause.cbody in
        Ok Kernel.{ cpat; cbody; cmeta = clause.cmeta }
      in
      let* subject = lower_expr_node ~quote_depth subject in
      match clauses with
      | [] -> error ~meta:expr.meta ~code:"E0209" "`match` requires at least one clause"
      | _ ->
          let* clauses = map_results lower_clause clauses in
          Ok (node (Kernel.Match (subject, clauses))))
  | Surface_ast.Handle (body, ret, ops) ->
      let lower_op (op : Surface_ast.op_clause) =
        let* params = map_results lower_pat op.oparams in
        let* obody = lower_expr_node ~quote_depth op.obody in
        Ok
          Kernel.
            { op = kernel_gref op.operation; params; resume = op.oresume; obody; ometa = op.ometa }
      in
      let* body = lower_expr_node ~quote_depth body in
      let* rbinder = lower_pat ret.rbinder in
      let* rbody = lower_expr_node ~quote_depth ret.rbody in
      let* ops = map_results lower_op ops in
      let ret = Kernel.{ rbinder; rbody; rmeta = ret.rmeta } in
      Ok (node (Kernel.Handle { body; ret; ops }))
  | Surface_ast.Quote quote_body ->
      let* payload =
        match quote_body with
        | Surface_ast.Raw payload -> Ok payload
        | Surface_ast.Surface body ->
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
  | Surface_ast.List _ | Surface_ast.If _ | Surface_ast.Pipe _ ->
      error ~meta:expr.meta ~code:"E1230"
        "this surface form is not part of the implemented local-lowering slice"

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
          Diag.error ?span ~code:"E1232"
            "a block must end in an expression; a final local `let` has no value";
        ]
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
          lower_irrefutable_pat ~code:"E0206" ~message:"`let` binders must be irrefutable patterns"
            binder
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
      let* params = lower_lambda_params params in
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
    unquote fails with E0204. It also returns span-bearing diagnostics for recovery holes,
    unsupported later-slice forms, malformed recursive bindings, empty blocks, final local lets, or
    missing spans needed by generated sequence nodes. *)
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
              (Diag.error ?span:(Meta.span top.meta) ~code:"E0303"
                 (Printf.sprintf "binding `%s` appears more than once in this definition run" name))
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
      (* SS.8 represents labels only. Accessor generation belongs to its separately reviewed owner. *)
      Ok (Kernel.Decl Kernel.{ it = DefType { tname = name; tvars = vars; cons }; meta = top.meta })
  | Surface_ast.EffectDecl { name; vars; operations } ->
      let lower_operation (operation : Surface_ast.operation) =
        let* op_params = map_results lower_ty operation.params in
        let* op_result = lower_ty operation.result in
        Ok Kernel.{ op_name = operation.name; op_params; op_result; smeta = operation.meta }
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

(** [lower_tops tops] lowers a complete strictly parsed file. It attaches each signature to its
    adjacent same-name definition, partitions uninterrupted definition runs into exact SCCs, and
    emits SCC declarations dependency-first with source-stable ties. Bare expressions and type,
    effect, or raw declarations retain document order and break definition runs. *)
let lower_tops tops =
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
    | top :: rest ->
        let* acc = flush acc run in
        let* top = lower_nonterm_top top in
        loop (top :: acc) [] rest
  in
  loop [] [] tops

type file = { tops : Kernel.top list; meta : Meta.t }

(** [lower_file file] lowers all tops while retaining the hash-excluded file trivia anchor. *)
let lower_file (file : Surface_ast.file) =
  let* tops = lower_tops file.tops in
  Ok { tops; meta = file.meta }
