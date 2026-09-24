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
    | Surface_ast.Interpolation parts ->
        Surface_ast.Interpolation
          (List.map
             (function
               | Surface_ast.IText _ as text -> text
               | Surface_ast.IExpr embedded -> Surface_ast.IExpr (project_expr embedded))
             parts)
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
  | Surface_ast.Try item ->
      Surface_ast.Try
        { item with binder = Option.map project_pat item.binder; value = project_expr item.value }

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
  let constructor =
    match Surface_name.to_pascal name with Some spelling -> spelling | None -> name
  in
  Diag.warning
    ?span:(Meta.span pattern.Surface_ast.meta)
    ~domain:Surface ~code:"W1201"
    ~summary:"Lowercase pattern binds instead of matching a constructor"
    ~cause:
      (Printf.sprintf
         "Binding pattern `%s` binds a new name; it does not match the in-scope constructor `%s`, \
          which differs only in case."
         name constructor)
    ~next_step:
      (Printf.sprintf
         "Write `%s` to match the constructor, or rename the binding if it is meant to bind."
         constructor)
    ~contrast:
      (Some
         (Diag.contrast
            ~mistaken:(Printf.sprintf "`%s` matches the constructor `%s`" name constructor)
            ~intended:"A lowercase pattern always binds a new name"))
    ()

let warning_wide (pattern : Surface_ast.pat) fields =
  Diag.warning
    ?span:(Meta.span pattern.Surface_ast.meta)
    ~domain:Surface ~code:"W1202" ~summary:"Constructor pattern is difficult to review"
    ~cause:
      (Printf.sprintf
         "This positional constructor pattern has %d fields, which makes field positions hard to \
          track."
         fields)
    ~next_step:
      "Select the relevant fields with `Constructor(label: pattern, ...)`, or keep the positional \
       pattern to four fields or fewer."
    ~contrast:None ()

(** A match scrutinee is judged by what it contains, never by how many source lines the canonical
    formatter chose to spread it over (APP.9): a plain data expression that the formatter expanded
    is not harder to review than its one-line spelling, while a nested control construct or a large
    tree of calls is, however it is laid out. Function literals are values: their bodies add weight
    but are not nesting. *)
let large_match_scrutinee_weight = 12

type scrutinee_shape = Nested of string | Wide of int

let rec scrutinee_weight (expression : Surface_ast.expr) =
  let sum items = List.fold_left (fun total item -> total + scrutinee_weight item) 0 items in
  match expression.it with
  | Surface_ast.Lit _ | Surface_ast.Name _ | Surface_ast.HashRef _ | Surface_ast.GroupRef _
  | Surface_ast.Hole _ | Surface_ast.Quote _ ->
      0
  | Surface_ast.Interpolation parts ->
      1
      + List.fold_left
          (fun total part ->
            match part with
            | Surface_ast.IText _ -> total
            | Surface_ast.IExpr embedded -> total + scrutinee_weight embedded)
          0 parts
  | Surface_ast.Call (fn, args) -> 1 + scrutinee_weight fn + sum args
  | Surface_ast.Tuple items | Surface_ast.List items -> 1 + sum items
  | Surface_ast.Pipe (left, right) -> 1 + scrutinee_weight left + scrutinee_weight right
  | Surface_ast.Ann (inner, _) | Surface_ast.Unquote inner -> scrutinee_weight inner
  | Surface_ast.Fn (_, body) -> scrutinee_weight body
  (* the canonical printer drops the braces of a single-expression block, so the lint must see
     through them too or formatting could change the verdict *)
  | Surface_ast.Block [ Surface_ast.Expr inner ] -> scrutinee_weight inner
  | Surface_ast.Block _ | Surface_ast.Match _ | Surface_ast.If _ | Surface_ast.Handle _ -> 1

let rec scrutinee_nesting (expression : Surface_ast.expr) =
  let first items = List.find_map scrutinee_nesting items in
  match expression.it with
  | Surface_ast.Match _ -> Some "a nested `match`"
  | Surface_ast.Handle _ -> Some "a nested `handle`"
  | Surface_ast.If _ -> Some "a nested `if`"
  | Surface_ast.Block [ Surface_ast.Expr inner ] -> scrutinee_nesting inner
  | Surface_ast.Block _ -> Some "a block"
  (* a function literal passed to a call is a value with its own scope (`async.scope(fn () ->
     ...)`, `list.fold(xs, seed, fn (acc, x) -> ...)`); its body is not the scrutinee's branch
     condition, so it is weighed but not reported as nesting *)
  | Surface_ast.Fn _ -> None
  | Surface_ast.Call (fn, args) -> first (fn :: args)
  | Surface_ast.Tuple items | Surface_ast.List items -> first items
  | Surface_ast.Pipe (left, right) -> first [ left; right ]
  | Surface_ast.Ann (inner, _) | Surface_ast.Unquote inner -> scrutinee_nesting inner
  | Surface_ast.Interpolation parts ->
      List.find_map
        (function Surface_ast.IText _ -> None | Surface_ast.IExpr e -> scrutinee_nesting e)
        parts
  | Surface_ast.Lit _ | Surface_ast.Name _ | Surface_ast.HashRef _ | Surface_ast.GroupRef _
  | Surface_ast.Hole _ | Surface_ast.Quote _ ->
      None

let scrutinee_shape (subject : Surface_ast.expr) =
  match scrutinee_nesting subject with
  | Some construct -> Some (Nested construct)
  | None ->
      let weight = scrutinee_weight subject in
      if weight > large_match_scrutinee_weight then Some (Wide weight) else None

let warning_large_scrutinee (subject : Surface_ast.expr) shape =
  let cause =
    match shape with
    | Nested construct ->
        Printf.sprintf "This match scrutinee contains %s, which obscures the branch conditions."
          construct
    | Wide weight ->
        Printf.sprintf
          "This match scrutinee combines %d calls and constructions; more than %d obscure the \
           branch conditions."
          weight large_match_scrutinee_weight
  in
  Diag.warning
    ?span:(Meta.span subject.Surface_ast.meta)
    ~domain:Surface ~code:"W1203" ~summary:"Match scrutinee is difficult to review" ~cause
    ~next_step:"Bind the expression with `let`, then match on that name." ~contrast:None ()

let declaration_header_name_meta (top : Surface_ast.top) =
  let name_meta = Meta.surface_container "declaration-name" top.meta in
  if Meta.is_empty name_meta then top.meta else name_meta

let rendered_names_length kind names =
  List.fold_left
    (fun length name -> length + 1 + String.length (Surface_name.render kind name))
    0 names

let type_header_length name vars =
  String.length "type "
  + String.length (Surface_name.render Surface_name.Type name)
  + rendered_names_length Surface_name.Tvar vars
  + String.length " ="

let uniform_effect_mode (operations : Surface_ast.operation list) =
  match operations with
  | { Surface_ast.mode = Some mode; _ } :: rest
    when List.for_all (fun operation -> operation.Surface_ast.mode = Some mode) rest ->
      Some mode
  | _ -> None

let effect_header_length name vars operations =
  let prefix =
    match uniform_effect_mode operations with
    | Some Kernel.Once -> "once effect "
    | Some Kernel.Multi -> "multi effect "
    | None -> "effect "
  in
  String.length prefix
  + String.length (Surface_name.render Surface_name.Effect name)
  + rendered_names_length Surface_name.Tvar vars
  + String.length " where {"

let warning_long_declaration_header (top : Surface_ast.top) kind name length =
  let rendered_name = Surface_name.render kind name in
  Diag.warning
    ?span:(Meta.span (declaration_header_name_meta top))
    ~domain:Surface ~code:"W1204"
    ~summary:"Declaration header exceeds the canonical formatter width"
    ~cause:
      (Printf.sprintf
         "The shortest legal header for `%s` is %d bytes, but the canonical formatter width is %d \
          bytes; `.jac` requires this header to remain on one logical line."
         rendered_name length Surface_print.default_width)
    ~next_step:"Shorten the declaration name or its type-variable list." ~contrast:None ()

let long_declaration_header_warning top kind name length =
  if length > Surface_print.default_width then
    [ warning_long_declaration_header top kind name length ]
  else []

let quantifier_prefix_length type_vars row_vars =
  String.length "forall"
  + rendered_names_length Surface_name.Tvar type_vars
  + (if row_vars = [] then 0 else String.length " |")
  + rendered_names_length Surface_name.Rvar row_vars
  + String.length "."

let quantifier_prefix_meta (annotation : Surface_ast.ty) =
  let prefix = Meta.surface_container "forall" annotation.meta in
  if Meta.is_empty prefix then annotation.meta else prefix

let warning_long_quantifier_prefix (annotation : Surface_ast.ty) length =
  Diag.warning
    ?span:(Meta.span (quantifier_prefix_meta annotation))
    ~domain:Surface ~code:"W1205" ~summary:"Quantifier prefix exceeds line width"
    ~cause:
      (Printf.sprintf
         "The shortest legal `forall` prefix is %d bytes, but the canonical formatter width is %d \
          bytes; `.jac` requires the quantified variables and `.` to remain on one logical line."
         length Surface_print.default_width)
    ~next_step:"Split the declaration or reduce its quantified variables." ~contrast:None ()

let rec long_quantifier_prefix_warnings (annotation : Surface_ast.ty) =
  let annotations values = List.concat_map long_quantifier_prefix_warnings values in
  match annotation.it with
  | Surface_ast.TyForall (type_vars, row_vars, body) ->
      let length = quantifier_prefix_length type_vars row_vars in
      let here =
        if length > Surface_print.default_width then
          [ warning_long_quantifier_prefix annotation length ]
        else []
      in
      here @ long_quantifier_prefix_warnings body
  | Surface_ast.TyApp (head, args) -> long_quantifier_prefix_warnings head @ annotations args
  | Surface_ast.TyArrow (params, _, result) ->
      annotations params @ long_quantifier_prefix_warnings result
  | Surface_ast.TyTuple items -> annotations items
  | Surface_ast.TyName _ | Surface_ast.TyVar _ | Surface_ast.TyHash _ | Surface_ast.TyHole _ -> []

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
    | Surface_ast.PCon (_, args)
      when Meta.surface_form pattern.meta <> Some "labeled-pattern" && List.length args > 4 ->
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
  | Surface_ast.Interpolation parts ->
      List.concat_map
        (function
          | Surface_ast.IText _ -> []
          | Surface_ast.IExpr embedded -> lint_expr names constructors embedded)
        parts
  | Surface_ast.Call (fn, args) -> lint_expr names constructors fn @ exprs args
  | Surface_ast.Fn (params, body) -> pats params @ lint_expr names constructors body
  | Surface_ast.Tuple items | Surface_ast.List items -> exprs items
  | Surface_ast.Block items -> List.concat_map (lint_block_item names constructors) items
  | Surface_ast.Match (subject, clauses) ->
      let large_scrutinee =
        match scrutinee_shape subject with
        | None -> []
        | Some shape -> [ warning_large_scrutinee subject shape ]
      in
      large_scrutinee
      @ lint_expr names constructors subject
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
  | Surface_ast.Quote (Surface_ast.Surface body) ->
      (* quoted code is data: the formatter rewrites a raw `jqd { ... }` quote into surface
         syntax, so a scrutinee warning inside a quote would appear only after formatting;
         pattern lints still apply to quoted surface syntax as before *)
      List.filter
        (fun warning -> Diag.code_or_uncoded warning <> "W1203")
        (lint_expr names constructors body)
  | Surface_ast.Quote (Surface_ast.Raw _) -> []
  | Surface_ast.Unquote body -> lint_expr names constructors body
  | Surface_ast.Ann (subject, annotation) ->
      lint_expr names constructors subject @ long_quantifier_prefix_warnings annotation

and lint_block_item names constructors = function
  | Surface_ast.Expr expression -> lint_expr names constructors expression
  | Surface_ast.Let binding ->
      lint_pat names constructors binding.binder
      @ List.concat_map (lint_pat names constructors) binding.params
      @ lint_expr names constructors binding.value
  | Surface_ast.Try item ->
      Option.fold ~none:[] ~some:(lint_pat names constructors) item.binder
      @ lint_expr names constructors item.value

let lint_top names constructors (top : Surface_ast.top) =
  match top.it with
  | Surface_ast.Definition { params; value; _ } ->
      List.concat_map (lint_pat names constructors) params @ lint_expr names constructors value
  | Surface_ast.TopExpr expression -> lint_expr names constructors expression
  | Surface_ast.Signature (_, annotation) -> long_quantifier_prefix_warnings annotation
  | Surface_ast.TypeDecl { name; vars; constructors } ->
      long_declaration_header_warning top Surface_name.Type name (type_header_length name vars)
      @ List.concat_map long_quantifier_prefix_warnings
          (List.concat_map
             (fun (constructor : Surface_ast.constructor) ->
               List.map (fun (field : Surface_ast.field) -> field.ty) constructor.fields)
             constructors)
  | Surface_ast.EffectDecl { name; vars; operations } ->
      long_declaration_header_warning top Surface_name.Effect name
        (effect_header_length name vars operations)
      @ List.concat_map long_quantifier_prefix_warnings
          (List.concat_map
             (fun (operation : Surface_ast.operation) -> operation.params @ [ operation.result ])
             operations)
  | Surface_ast.RawTop _ | Surface_ast.TopHole _ -> []

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

(** [lint ~names tops] reports surface-only review warnings in source order. It does not lower,
    rewrite, resolve, or typecheck the input. *)
let lint ~names tops = lint_file names tops

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
  match Diag.span diagnostic with Some span -> span.Span.start_pos.offset | None -> max_int

let sort_diagnostics diagnostics =
  List.stable_sort
    (fun left right -> Int.compare (diagnostic_offset left) (diagnostic_offset right))
    diagnostics

let same_diagnostic left right =
  Diag.code left = Diag.code right
  && Diag.span left = Diag.span right
  && String.equal (Diag.summary left) (Diag.summary right)
  && String.equal (Diag.cause left) (Diag.cause right)

let deduplicate diagnostics =
  List.fold_left
    (fun unique diagnostic ->
      if List.exists (same_diagnostic diagnostic) unique then unique else unique @ [ diagnostic ])
    [] diagnostics

(* [poisoned] (name, kind) pairs are those a malformed or failed declaration of the analyzed file
   would have bound. A file's own declaration shadows a same-kind prelude binding in strict
   checking, so a poisoned pair must not fall through to that binding (`print`, `record`, `Some`,
   ...): it resolves to nothing, and the resulting E0301 is a consequence rather than a finding.
   Other kinds of the same name (a prelude term beside a poisoned constructor) stay visible, as in
   strict checking. *)
let analysis_names ?(recovery_fields = fun _ -> None) ?(poisoned = ref []) base additions call_abis
    =
  let lookup name =
    let local =
      List.filter_map
        (fun (local_name, entry) -> if local_name = name then Some entry else None)
        !additions
    in
    let local_kinds = List.map (fun entry -> entry.Resolve.kind) local in
    local
    @ List.filter
        (fun entry ->
          (not (List.mem entry.Resolve.kind local_kinds))
          && not (List.mem (name, entry.Resolve.kind) !poisoned))
        (base.Resolve.lookup name)
  in
  {
    Resolve.lookup;
    all_names = (fun () -> List.map fst !additions @ base.Resolve.all_names ());
    constructor_fields =
      (fun hash ->
        match recovery_fields hash with
        | Some fields -> Some fields
        | None -> base.Resolve.constructor_fields hash);
    callable_abi =
      (fun hash ->
        match List.find_opt (fun (known, _) -> Hash.equal known hash) !call_abis with
        | Some (_, abi) -> Some abi
        | None -> base.Resolve.callable_abi hash);
  }

let recovery_member_hashes identity bindings =
  List.mapi
    (fun index binding ->
      Hash.of_string
        (Printf.sprintf "surface-recovery-member:%s:%d:%s" identity index binding.Kernel.bname))
    bindings

let binding_call_abi (binding : Kernel.binding) =
  match binding.value.it with
  | Kernel.Lam (parameters, _) ->
      let slots =
        List.map (fun parameter -> Meta.surface_call_label parameter.Kernel.meta) parameters
      in
      if List.for_all Option.is_none slots then None else Some slots
  | _ -> None

(** [declared_names top] lists the kernel spellings a top-level item would bind: the definition
    name, or the type/effect name with its constructors/operations. It works on damaged items too,
    which is what lets a malformed declaration poison exactly the references that depend on it. *)
let declared_names (top : Surface_ast.top) =
  let kernel name = match Surface_name.of_pascal name with Some kernel -> kernel | None -> name in
  match top.it with
  | Surface_ast.Definition { name; _ } -> [ (name, Resolve.KTerm) ]
  | Surface_ast.TypeDecl { name; constructors; _ } ->
      (kernel name, Resolve.KType)
      :: List.map
           (fun (c : Surface_ast.constructor) -> (kernel c.Surface_ast.name, Resolve.KCon))
           constructors
      (* D36 accessors fail with their declaration *)
      @ List.map (fun accessor -> (accessor, Resolve.KTerm)) (Surface_lower.accessor_names top)
  | Surface_ast.EffectDecl { name; operations; _ } ->
      (kernel name, Resolve.KEffect)
      :: List.map (fun (o : Surface_ast.operation) -> (o.Surface_ast.name, Resolve.KOp)) operations
  | Surface_ast.Signature _ | Surface_ast.TopExpr _ | Surface_ast.RawTop _ | Surface_ast.TopHole _
    ->
      []

(** [analyze ~names ctx recovered] returns parser diagnostics, surface lints, and at most one
    resolution/checking error per lowered top-level island, all in deterministic source order. Holes
    behave as fresh types and contribute no effects, allowing later independent definitions to be
    checked. No analyzed declaration is installed in a store, and no analysis projection is returned
    to callers. *)
let analyze ~names ctx (recovered : Surface_ast.recovered) : report =
  let recovery = Check.start_recovery ctx in
  let additions = ref [] in
  let call_abis = ref [] in
  (* Names bound by a malformed declaration, or by a declaration that could not be analyzed only
     because it referenced such a name. A reference to one of them is a consequence of the
     originating error, not a finding of its own, so the checker reports the originating error once
     and keeps independent later errors (APP.8). *)
  let poisoned = ref [] in
  let evolving_names =
    analysis_names
      ~recovery_fields:(Check.recovery_constructor_fields recovery)
      ~poisoned names additions call_abis
  in
  let island = ref 0 in
  let diagnostics = ref (recovered.diagnostics @ lint ~names recovered.items) in
  let signatures = ref [] in
  (* a failed or malformed redeclaration supersedes an earlier recovered binding of the same
     (name, kind), as a later declaration would in strict checking *)
  let poison_pairs pairs =
    poisoned := pairs @ !poisoned;
    additions :=
      List.filter
        (fun (name, entry) ->
          not (List.exists (fun (n, k) -> String.equal n name && k = entry.Resolve.kind) pairs))
        !additions
  in
  let poison tops = List.iter (fun top -> poison_pairs (declared_names top)) tops in
  (* a reference is a consequence only when a poisoned pair of the same name could have satisfied
     the position; a poisoned constructor used where a type is required is a genuine mistake *)
  let is_consequence error =
    match Resolve.reference_of error with
    | Some (name, kinds) ->
        List.exists
          (fun (poisoned_name, kind) -> String.equal poisoned_name name && List.mem kind kinds)
          !poisoned
    | None -> false
  in
  (* the diagnostics of one item minus its consequences, so a genuine mistake beside a poisoned
     reference is the one reported and an item with consequences alone is silent *)
  let findings errors = List.filter (fun error -> not (is_consequence error)) errors in
  let add_one_error errors =
    match sort_diagnostics errors with
    | first :: _ -> diagnostics := !diagnostics @ [ first ]
    | [] -> ()
  in
  let kernel_names (top : Kernel.top) =
    match top with
    | Kernel.Decl { Kernel.it = Kernel.DefTerm bindings; _ } ->
        List.map (fun binding -> (binding.Kernel.bname, Resolve.KTerm)) bindings
    | Kernel.Decl { Kernel.it = Kernel.DefType { tname; cons; _ }; _ } ->
        (tname, Resolve.KType)
        :: List.map (fun (c : Kernel.conspec) -> (c.Kernel.con_name, Resolve.KCon)) cons
    | Kernel.Decl { Kernel.it = Kernel.DefEffect { ename; ops; _ }; _ } ->
        (ename, Resolve.KEffect)
        :: List.map (fun (o : Kernel.opspec) -> (o.Kernel.op_name, Resolve.KOp)) ops
    | Kernel.Expr _ -> []
  in
  (* a resolution failure caused only by poisoned names poisons the item's own names in turn
     instead of being reported *)
  let check_lowered tops =
    List.iter
      (fun top ->
        let identity = string_of_int !island in
        incr island;
        (* whichever way an item fails, the names it would have bound are consequences of that
           failure for every later reference, so they never produce a second finding *)
        let failed errors =
          add_one_error (findings errors);
          poison_pairs (kernel_names top)
        in
        match Resolve.resolve_w evolving_names top with
        | Error errors -> failed errors
        | Ok ((Kernel.Decl { Kernel.it = Kernel.DefType _ | Kernel.DefEffect _; _ } as resolved), _)
          when Recovery_marker.top resolved ->
            (* the parser already reported the damage; checking or hashing a damaged declaration
               would only add a span-less consequence, so its names are poisoned instead *)
            poison_pairs (kernel_names resolved)
        | Ok (resolved, resolve_warnings) -> (
            diagnostics := !diagnostics @ resolve_warnings;
            match Check.check_recovery_top ~identity recovery resolved with
            | Error errors -> failed errors
            | Ok checked -> (
                diagnostics := !diagnostics @ checked.Check.warnings;
                if not (Surface_lower.is_generated_accessor resolved) then
                  signatures := List.rev_append checked.names !signatures;
                match resolved with
                | Kernel.Decl ({ Kernel.it = Kernel.DefType _ | Kernel.DefEffect _; _ } as decl)
                  -> (
                    match Check.register_recovery_decl recovery decl with
                    | Ok (entries, abis) -> (
                        let conflict =
                          List.find_opt
                            (fun (hash, slots) ->
                              match List.assoc_opt hash !call_abis with
                              | Some known -> known <> slots
                              | None -> false)
                            abis
                        in
                        match conflict with
                        | Some (hash, _) ->
                            (* the store refuses a second companion for the same callable
                               hash (E0612); recovery must not silently pick one *)
                            failed
                              [
                                Diag.error ?span:(Meta.span decl.Kernel.meta) ~domain:Store
                                  ~code:"E0612"
                                  ~summary:"A callable hash already has a different named-call ABI."
                                  ~cause:
                                    (Printf.sprintf
                                       "callable %s is already bound to a different call-abi-v1 \
                                        companion"
                                       (Hash.to_hex hash))
                                  ~next_step:
                                    "Keep the published labels, or make a semantic code change \
                                     that gives the callable a new hash."
                                  ~contrast:None ();
                              ]
                        | None ->
                            additions := entries @ !additions;
                            call_abis := abis @ !call_abis)
                    | Error errors -> failed errors)
                | Kernel.Decl { Kernel.it = Kernel.DefTerm bindings; _ } ->
                    let hashes = recovery_member_hashes identity bindings in
                    additions :=
                      List.map2
                        (fun binding hash ->
                          (binding.Kernel.bname, { Resolve.hash; kind = Resolve.KTerm }))
                        bindings hashes
                      @ !additions;
                    call_abis :=
                      (List.map2
                         (fun binding hash ->
                           Option.map (fun abi -> (hash, abi)) (binding_call_abi binding))
                         bindings hashes
                      |> List.filter_map Fun.id)
                      @ !call_abis
                | Kernel.Expr _ -> ())))
      tops
  in
  (* accessor collisions (E1241) are judged against the whole file, not one chunk *)
  let explicit_terms = Surface_lower.explicit_term_names recovered.items in
  List.iter
    (fun chunk ->
      match Surface_lower.lower_tops ~explicit_terms chunk with
      | Ok tops -> check_lowered tops
      | Error _ when List.length chunk > 1 ->
          List.iter
            (fun unit ->
              match Surface_lower.lower_tops ~explicit_terms unit with
              | Ok tops -> check_lowered tops
              | Error errors ->
                  poison unit;
                  add_one_error errors)
            (definition_units chunk)
      | Error errors ->
          poison chunk;
          add_one_error errors)
    (chunks recovered.items);
  {
    diagnostics = !diagnostics |> deduplicate |> sort_diagnostics;
    signatures = List.rev !signatures;
  }
