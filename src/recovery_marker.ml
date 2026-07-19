(** Recursive detection of parser-recovery markers after surface lowering.

    Recovery markers are metadata, so every semantic boundary must reject them before metadata is
    erased or ignored. The traversal includes auxiliary kernel records and quoted [Form.t] payloads.
*)

let marked_meta meta = Option.is_some (Meta.surface_hole meta)

let rec form (value : Form.t) =
  marked_meta value.meta
  || List.exists (function Form.F nested -> form nested | _ -> false) value.args

let rec pat (pattern : Kernel.pat) =
  marked_meta pattern.meta
  ||
  match pattern.it with
  | Kernel.PWild | Kernel.PVar _ | Kernel.PLit _ -> false
  | Kernel.PCon (_, args) | Kernel.PTuple args -> List.exists pat args
  | Kernel.PAs (_, inner) -> pat inner

let rec ty (annotation : Kernel.ty) =
  marked_meta annotation.meta
  ||
  match annotation.it with
  | Kernel.TRef _ | Kernel.TVar _ -> false
  | Kernel.TApp (head, args) -> ty head || List.exists ty args
  | Kernel.TArrow (params, row, result) ->
      List.exists ty params || marked_meta row.Kernel.wmeta || ty result
  | Kernel.TTuple items -> List.exists ty items
  | Kernel.TForall (_, _, body) -> ty body

let rec expr (expression : Kernel.expr) =
  marked_meta expression.meta
  ||
  match expression.it with
  | Kernel.Lit _ | Kernel.Var _ | Kernel.Ref _ | Kernel.GroupRef _ -> false
  | Kernel.Lam (params, body) -> List.exists pat params || expr body
  | Kernel.App (fn, args) -> expr fn || List.exists expr args
  | Kernel.Let { binder; value; body; _ } -> pat binder || expr value || expr body
  | Kernel.Match (subject, clauses) ->
      expr subject
      || List.exists
           (fun clause -> marked_meta clause.Kernel.cmeta || pat clause.cpat || expr clause.cbody)
           clauses
  | Kernel.Tuple items -> List.exists expr items
  | Kernel.Handle { body; ret; ops } ->
      expr body || marked_meta ret.Kernel.rmeta || pat ret.rbinder || expr ret.rbody
      || List.exists
           (fun operation ->
             marked_meta operation.Kernel.ometa
             || List.exists pat operation.params || expr operation.obody)
           ops
  | Kernel.Quote payload -> form payload
  | Kernel.Unquote splice -> expr splice
  | Kernel.Ann (subject, annotation) -> expr subject || ty annotation

let decl (declaration : Kernel.decl) =
  marked_meta declaration.meta
  ||
  match declaration.it with
  | Kernel.DefTerm bindings ->
      List.exists
        (fun binding ->
          marked_meta binding.Kernel.bmeta
          || Option.fold ~none:false ~some:ty binding.annot
          || expr binding.value)
        bindings
  | Kernel.DefType { cons; _ } ->
      List.exists
        (fun constructor ->
          marked_meta constructor.Kernel.kmeta
          || List.exists
               (fun field -> marked_meta field.Kernel.fmeta || ty field.fty)
               constructor.fields)
        cons
  | Kernel.DefEffect { ops; _ } ->
      List.exists
        (fun operation ->
          marked_meta operation.Kernel.smeta
          || List.exists ty operation.op_params
          || ty operation.op_result)
        ops

let top = function
  | Kernel.Expr expression -> expr expression
  | Kernel.Decl declaration -> decl declaration

let diagnostic boundary =
  Diag.error ~domain:Surface ~code:"E1202"
    ~summary:"Recovered syntax cannot cross this semantic boundary."
    ~cause:(Printf.sprintf "Recovery holes are not valid input to %s." boundary)
    ~next_step:"Fix the reported syntax damage before checking, hashing, storing, or running it."
    ~contrast:None ()
