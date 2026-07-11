(** Hole-tolerant, diagnostic-only checking for recovered `.jac` trees.

    This module is the editor boundary. It projects parser holes to metadata-marked kernel sentinels
    and invokes the recovery service in {!Check}; hole sentinels contribute a fresh type and no
    effects. The projection is not returned. Semantic entry points independently reject any marked
    tree. Strict compile/run/hash callers must use {!Surface_parse.strict} and
    {!Surface_lower.lower_tops} instead. *)

type report = {
  diagnostics : Diag.t list;
  signatures : (string * Types.scheme) list;
      (** Successfully checked names from independent analysis islands, in analysis order. *)
}

let rec project_pat (pattern : Surface_ast.pat) =
  let it =
    match pattern.it with
    | (Surface_ast.PWild | Surface_ast.PBind _ | Surface_ast.PLit _) as leaf -> leaf
    | Surface_ast.PCon (constructor, args) ->
        Surface_ast.PCon (constructor, List.map project_pat args)
    | Surface_ast.PTuple items -> Surface_ast.PTuple (List.map project_pat items)
    | Surface_ast.PAs (inner, name) -> Surface_ast.PAs (project_pat inner, name)
    | Surface_ast.PHole _ -> Surface_ast.PWild
  in
  { pattern with Surface_ast.it }

let rec project_ty (annotation : Surface_ast.ty) =
  let it =
    match annotation.it with
    | (Surface_ast.TyName _ | Surface_ast.TyVar _ | Surface_ast.TyHash _) as leaf -> leaf
    | Surface_ast.TyApp (head, args) -> Surface_ast.TyApp (project_ty head, List.map project_ty args)
    | Surface_ast.TyArrow (params, row, result) ->
        let row =
          match row.Surface_ast.row_hole with
          | None -> row
          | Some id ->
              {
                row with
                effects = [];
                tail = Some (Printf.sprintf "surface-row-hole-%d" id);
                row_hole = None;
              }
        in
        Surface_ast.TyArrow (List.map project_ty params, row, project_ty result)
    | Surface_ast.TyTuple items -> Surface_ast.TyTuple (List.map project_ty items)
    | Surface_ast.TyForall (types, rows, body) -> Surface_ast.TyForall (types, rows, project_ty body)
    | Surface_ast.TyHole id -> Surface_ast.TyVar (Printf.sprintf "surface-hole-%d" id)
  in
  { annotation with Surface_ast.it }

let rec project_expr (expression : Surface_ast.expr) =
  let it =
    match expression.it with
    | (Surface_ast.Lit _ | Surface_ast.Name _ | Surface_ast.HashRef _ | Surface_ast.GroupRef _) as
      leaf ->
        leaf
    | Surface_ast.Call (fn, args) -> Surface_ast.Call (project_expr fn, List.map project_expr args)
    | Surface_ast.Fn (params, body) ->
        Surface_ast.Fn (List.map project_pat params, project_expr body)
    | Surface_ast.Tuple items -> Surface_ast.Tuple (List.map project_expr items)
    | Surface_ast.List items -> Surface_ast.List (List.map project_expr items)
    | Surface_ast.Block items -> Surface_ast.Block (List.map project_block_item items)
    | Surface_ast.Match (subject, clauses) ->
        Surface_ast.Match
          ( project_expr subject,
            List.map
              (fun (clause : Surface_ast.clause) ->
                {
                  clause with
                  Surface_ast.cpattern = project_pat clause.cpattern;
                  cbody = project_expr clause.cbody;
                })
              clauses )
    | Surface_ast.If (condition, yes, no) ->
        Surface_ast.If (project_expr condition, project_expr yes, project_expr no)
    | Surface_ast.Pipe (left, right) -> Surface_ast.Pipe (project_expr left, project_expr right)
    | Surface_ast.Handle (body, ret, operations) ->
        Surface_ast.Handle
          ( project_expr body,
            {
              ret with
              Surface_ast.rbinder = project_pat ret.rbinder;
              rbody = project_expr ret.rbody;
            },
            List.map
              (fun (operation : Surface_ast.op_clause) ->
                {
                  operation with
                  Surface_ast.oparams = List.map project_pat operation.oparams;
                  obody = project_expr operation.obody;
                })
              operations )
    | Surface_ast.Quote (Surface_ast.Surface body) ->
        Surface_ast.Quote (Surface_ast.Surface (project_expr body))
    | Surface_ast.Quote (Surface_ast.Raw _ as raw) -> Surface_ast.Quote raw
    | Surface_ast.Unquote body -> Surface_ast.Unquote (project_expr body)
    | Surface_ast.Ann (subject, annotation) ->
        Surface_ast.Ann (project_expr subject, project_ty annotation)
    | Surface_ast.Hole _ -> Surface_ast.Lit (Kernel.LInt 0)
  in
  { expression with Surface_ast.it }

and project_block_item = function
  | Surface_ast.Expr expression -> Surface_ast.Expr (project_expr expression)
  | Surface_ast.Let binding ->
      Surface_ast.Let
        {
          binding with
          binder = project_pat binding.binder;
          params = List.map project_pat binding.params;
          value = project_expr binding.value;
        }

let project_top (top : Surface_ast.top) =
  let it =
    match top.it with
    | Surface_ast.Signature (name, annotation) -> Surface_ast.Signature (name, project_ty annotation)
    | Surface_ast.Definition definition ->
        Surface_ast.Definition
          {
            definition with
            params = List.map project_pat definition.params;
            value = project_expr definition.value;
          }
    | Surface_ast.TypeDecl declaration ->
        Surface_ast.TypeDecl
          {
            declaration with
            constructors =
              List.map
                (fun (constructor : Surface_ast.constructor) ->
                  {
                    constructor with
                    Surface_ast.fields =
                      List.map
                        (fun (field : Surface_ast.field) ->
                          { field with Surface_ast.ty = project_ty field.ty })
                        constructor.fields;
                  })
                declaration.constructors;
          }
    | Surface_ast.EffectDecl declaration ->
        Surface_ast.EffectDecl
          {
            declaration with
            operations =
              List.map
                (fun (operation : Surface_ast.operation) ->
                  {
                    operation with
                    Surface_ast.params = List.map project_ty operation.params;
                    result = project_ty operation.result;
                  })
                declaration.operations;
          }
    | Surface_ast.TopExpr expression -> Surface_ast.TopExpr (project_expr expression)
    | (Surface_ast.RawTop _ | Surface_ast.TopHole _) as leaf -> leaf
  in
  { top with Surface_ast.it }

module String_set = Set.Make (String)

let warning_case (pattern : Surface_ast.pat) name =
  Diag.warning
    ?span:(Meta.span pattern.Surface_ast.meta)
    ~code:"W1201"
    ~hint:
      (Printf.sprintf
         "`%s` is an always-matching binder; use the PascalCase constructor spelling to match the \
          constructor"
         name)
    (Printf.sprintf "binding pattern `%s` shadows an in-scope constructor that differs only in case"
       name)

let warning_wide (pattern : Surface_ast.pat) fields =
  Diag.warning
    ?span:(Meta.span pattern.Surface_ast.meta)
    ~code:"W1202"
    ~hint:
      "D36 keeps labeled constructor patterns unavailable for now; keep positional matches to four \
       fields or fewer"
    (Printf.sprintf
       "this positional constructor pattern has %d fields; labeled constructor patterns are the \
        future fix"
       fields)

let constructor_in_names names name =
  List.exists (fun entry -> entry.Resolve.kind = Resolve.KCon) (names.Resolve.lookup name)

let rec lint_pat names constructors (pattern : Surface_ast.pat) =
  let nested =
    match pattern.it with
    | Surface_ast.PCon (_, args) | Surface_ast.PTuple args ->
        List.concat_map (lint_pat names constructors) args
    | Surface_ast.PAs (inner, _) -> lint_pat names constructors inner
    | Surface_ast.PWild | Surface_ast.PBind _ | Surface_ast.PLit _ | Surface_ast.PHole _ -> []
  in
  let here =
    match pattern.it with
    | Surface_ast.PBind name
      when Meta.surface_ref_kind pattern.meta <> Some "term"
           && (String_set.mem name constructors || constructor_in_names names name) ->
        [ warning_case pattern name ]
    | Surface_ast.PCon (_, args) when List.length args > 4 ->
        [ warning_wide pattern (List.length args) ]
    | _ -> []
  in
  here @ nested

let rec lint_expr names constructors (expression : Surface_ast.expr) =
  let pats patterns = List.concat_map (lint_pat names constructors) patterns in
  let exprs expressions = List.concat_map (lint_expr names constructors) expressions in
  match expression.it with
  | Surface_ast.Lit _ | Surface_ast.Name _ | Surface_ast.HashRef _ | Surface_ast.GroupRef _
  | Surface_ast.Hole _ ->
      []
  | Surface_ast.Call (fn, args) -> lint_expr names constructors fn @ exprs args
  | Surface_ast.Fn (params, body) -> pats params @ lint_expr names constructors body
  | Surface_ast.Tuple items | Surface_ast.List items -> exprs items
  | Surface_ast.Block items -> List.concat_map (lint_block_item names constructors) items
  | Surface_ast.Match (subject, clauses) ->
      lint_expr names constructors subject
      @ List.concat_map
          (fun (clause : Surface_ast.clause) ->
            lint_pat names constructors clause.Surface_ast.cpattern
            @ lint_expr names constructors clause.cbody)
          clauses
  | Surface_ast.If (condition, yes, no) -> exprs [ condition; yes; no ]
  | Surface_ast.Pipe (left, right) -> exprs [ left; right ]
  | Surface_ast.Handle (body, ret, operations) ->
      lint_expr names constructors body
      @ lint_pat names constructors ret.rbinder
      @ lint_expr names constructors ret.rbody
      @ List.concat_map
          (fun (operation : Surface_ast.op_clause) ->
            pats operation.Surface_ast.oparams @ lint_expr names constructors operation.obody)
          operations
  | Surface_ast.Quote (Surface_ast.Surface body) -> lint_expr names constructors body
  | Surface_ast.Quote (Surface_ast.Raw _) -> []
  | Surface_ast.Unquote body -> lint_expr names constructors body
  | Surface_ast.Ann (subject, _) -> lint_expr names constructors subject

and lint_block_item names constructors = function
  | Surface_ast.Expr expression -> lint_expr names constructors expression
  | Surface_ast.Let binding ->
      lint_pat names constructors binding.binder
      @ List.concat_map (lint_pat names constructors) binding.params
      @ lint_expr names constructors binding.value

let lint_top names constructors (top : Surface_ast.top) =
  match top.it with
  | Surface_ast.Definition { params; value; _ } ->
      List.concat_map (lint_pat names constructors) params @ lint_expr names constructors value
  | Surface_ast.TopExpr expression -> lint_expr names constructors expression
  | Surface_ast.Signature _ | Surface_ast.TypeDecl _ | Surface_ast.EffectDecl _
  | Surface_ast.RawTop _ | Surface_ast.TopHole _ ->
      []

let lint_file names tops =
  let rec loop constructors diagnostics = function
    | [] -> List.rev diagnostics
    | top :: rest ->
        let warnings = lint_top names constructors top in
        let constructors =
          match top.Surface_ast.it with
          | Surface_ast.TypeDecl { constructors = declared; _ } ->
              List.fold_left
                (fun scope (constructor : Surface_ast.constructor) ->
                  String_set.add constructor.Surface_ast.name scope)
                constructors declared
          | _ -> constructors
        in
        loop constructors (List.rev_append warnings diagnostics) rest
  in
  loop String_set.empty [] tops

let is_definition_top (top : Surface_ast.top) =
  match top.it with Surface_ast.Signature _ | Surface_ast.Definition _ -> true | _ -> false

let chunks tops =
  let flush run chunks = match run with [] -> chunks | _ -> List.rev run :: chunks in
  let rec loop run chunks = function
    | [] -> List.rev (flush run chunks)
    | ({ Surface_ast.it = Surface_ast.TopHole _; _ } as _hole) :: rest ->
        loop [] (flush run chunks) rest
    | top :: rest when is_definition_top top -> loop (project_top top :: run) chunks rest
    | top :: rest -> loop [] ([ project_top top ] :: flush run chunks) rest
  in
  loop [] [] tops

let definition_units tops =
  let rec loop units = function
    | ({ Surface_ast.it = Surface_ast.Signature _; _ } as signature)
      :: ({ Surface_ast.it = Surface_ast.Definition _; _ } as definition)
      :: rest ->
        loop ([ signature; definition ] :: units) rest
    | top :: rest -> loop ([ top ] :: units) rest
    | [] -> List.rev units
  in
  loop [] tops

let diagnostic_offset diagnostic =
  match diagnostic.Diag.span with Some span -> span.Span.start_pos.offset | None -> max_int

let sort_diagnostics diagnostics =
  List.stable_sort
    (fun left right -> Int.compare (diagnostic_offset left) (diagnostic_offset right))
    diagnostics

let same_diagnostic left right =
  left.Diag.code = right.Diag.code && left.span = right.span && left.message = right.message

let deduplicate diagnostics =
  List.fold_left
    (fun unique diagnostic ->
      if List.exists (same_diagnostic diagnostic) unique then unique else unique @ [ diagnostic ])
    [] diagnostics

let analysis_names base additions =
  let lookup name =
    let local =
      List.filter_map
        (fun (local_name, entry) -> if local_name = name then Some entry else None)
        !additions
    in
    let local_kinds = List.map (fun entry -> entry.Resolve.kind) local in
    local
    @ List.filter
        (fun entry -> not (List.mem entry.Resolve.kind local_kinds))
        (base.Resolve.lookup name)
  in
  { Resolve.lookup; all_names = (fun () -> List.map fst !additions @ base.Resolve.all_names ()) }

let recovery_member_hashes identity bindings =
  List.mapi
    (fun index binding ->
      Hash.of_string
        (Printf.sprintf "surface-recovery-member:%s:%d:%s" identity index binding.Kernel.bname))
    bindings

(** [analyze ~names ctx recovered] returns parser diagnostics, surface lints, and at most one
    resolution/checking error per lowered top-level island, all in deterministic source order. Holes
    behave as fresh types and contribute no effects, allowing later independent definitions to be
    checked. No analyzed declaration is installed in a store, and no analysis projection is returned
    to callers. *)
let analyze ~names ctx (recovered : Surface_ast.recovered) : report =
  let recovery = Check.start_recovery ctx in
  let additions = ref [] in
  let evolving_names = analysis_names names additions in
  let island = ref 0 in
  let diagnostics = ref (recovered.diagnostics @ lint_file names recovered.items) in
  let signatures = ref [] in
  let add_one_error errors =
    match sort_diagnostics errors with
    | first :: _ -> diagnostics := !diagnostics @ [ first ]
    | [] -> ()
  in
  let check_lowered tops =
    List.iter
      (fun top ->
        let identity = string_of_int !island in
        incr island;
        match Resolve.resolve_w evolving_names top with
        | Error errors -> add_one_error errors
        | Ok (resolved, resolve_warnings) -> (
            diagnostics := !diagnostics @ resolve_warnings;
            match Check.check_recovery_top ~identity recovery resolved with
            | Error errors -> add_one_error errors
            | Ok checked -> (
                diagnostics := !diagnostics @ checked.Check.warnings;
                signatures := List.rev_append checked.names !signatures;
                match resolved with
                | Kernel.Decl { Kernel.it = Kernel.DefTerm bindings; _ } ->
                    let hashes = recovery_member_hashes identity bindings in
                    additions :=
                      List.map2
                        (fun binding hash ->
                          (binding.Kernel.bname, { Resolve.hash; kind = Resolve.KTerm }))
                        bindings hashes
                      @ !additions
                | Kernel.Decl { Kernel.it = Kernel.DefType _ | Kernel.DefEffect _; _ }
                | Kernel.Expr _ ->
                    ())))
      tops
  in
  List.iter
    (fun chunk ->
      match Surface_lower.lower_tops chunk with
      | Ok tops -> check_lowered tops
      | Error _ when List.length chunk > 1 ->
          List.iter
            (fun unit ->
              match Surface_lower.lower_tops unit with
              | Ok tops -> check_lowered tops
              | Error errors -> add_one_error errors)
            (definition_units chunk)
      | Error errors -> add_one_error errors)
    (chunks recovered.items);
  {
    diagnostics = !diagnostics |> deduplicate |> sort_diagnostics;
    signatures = List.rev !signatures;
  }
