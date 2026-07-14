(** Local affine-usage checking for resumptions of [once] operations.

    The type checker gives a once-clause binder {!Types.TResume}; this pass supplies the
    substructural part that ordinary unification intentionally does not attempt. It follows one
    captured continuation token through local aliases and contextually checked local helper
    parameters. Sequential subexpressions share a budget, while match arms are alternatives. A token
    may be dropped, called once, or moved into another parameter checked by this same pass; every
    other value use is an escape.

    This is deliberately local to one operation clause. It is not a general linear-type system, and
    failures are ordinary checker diagnostics rather than internal exceptions. *)

module SSet = Set.Make (String)
module SMap = Map.Make (String)

type consumption = { binder : string; meta : Meta.t }
type flow = consumption option list

type callable = {
  params : Kernel.pat list;
  body : Kernel.expr;
  closure : callable SMap.t;
  resolver : Hash.t -> resolved_callable option;
  recursive : bool;
}

and resolved_callable = {
  resolved_params : Kernel.pat list;
  resolved_body : Kernel.expr;
  resolved_recursive : bool;
}

type env = {
  aliases : SSet.t;
  callables : callable SMap.t;
  resolve_term : Hash.t -> resolved_callable option;
}

type value_context = Return | Argument | Storage | Scrutinee | Binding | Function

exception Reject of Diag.t

let span_text meta =
  match Meta.span meta with
  | Some span -> Span.to_string span
  | None -> "an unknown source location"

let reject ?hint ~code ~meta message =
  raise (Reject (Diag.error ?span:(Meta.span meta) ?hint ~code message))

let reject_double first second =
  reject ~code:"E0816" ~meta:second.meta
    ~hint:
      "a once resumption may be dropped or moved, but it may be consumed at most once on each \
       possible execution path"
    (Printf.sprintf
       "once resumption `%s` may be consumed twice on one possible execution path; first \
        consumption at %s, second consumption at %s"
       second.binder (span_text first.meta) (span_text second.meta))

let escape_message binder = function
  | Return ->
      Printf.sprintf "once resumption `%s` escapes by being returned from its handler clause" binder
  | Argument ->
      Printf.sprintf
        "once resumption `%s` escapes through a parameter that is not known to be Resume-typed"
        binder
  | Storage -> Printf.sprintf "once resumption `%s` cannot be stored in data" binder
  | Scrutinee -> Printf.sprintf "once resumption `%s` cannot be inspected as ordinary data" binder
  | Binding -> Printf.sprintf "once resumption `%s` escapes from an ordinary value binding" binder
  | Function ->
      Printf.sprintf "once resumption `%s` cannot be used as an ordinary function value" binder

let reject_escape ~binder ~meta context =
  reject ~code:"E0817" ~meta
    ~hint:
      "call the resumption once, drop it, or move it to a local parameter that is checked as \
       Resume-typed"
    (escape_message binder context)

let zero = [ None ]
let consume binder meta = [ Some { binder; meta } ]

(* Both expressions execute. Each side carries the possible token state at its exit; a pair of
   consumptions therefore witnesses one concrete path that spends the same budget twice. *)
let seq left right =
  List.concat_map
    (fun l ->
      List.map
        (fun r ->
          match (l, r) with
          | Some first, Some second -> reject_double first second
          | (Some _ as used), None | None, (Some _ as used) -> used
          | None, None -> None)
        right)
    left

let seq_all flows = List.fold_left seq zero flows
let alt flows = match flows with [] -> zero | _ -> List.concat flows

let rec pat_names (pat : Kernel.pat) =
  match pat.it with
  | Kernel.PVar name -> SSet.singleton name
  | Kernel.PAs (name, inner) -> SSet.add name (pat_names inner)
  | Kernel.PCon (_, items) | Kernel.PTuple items ->
      List.fold_left (fun names item -> SSet.union names (pat_names item)) SSet.empty items
  | Kernel.PWild | Kernel.PLit _ -> SSet.empty

let shadow env names =
  {
    aliases = SSet.diff env.aliases names;
    callables = SSet.fold (fun name map -> SMap.remove name map) names env.callables;
    resolve_term = env.resolve_term;
  }

let rec free_alias (env : env) (expr : Kernel.expr) : (string * Meta.t) option =
  let first xs = List.find_map (free_alias env) xs in
  match expr.it with
  | Kernel.Var name when SSet.mem name env.aliases -> Some (name, expr.meta)
  | Kernel.Lit _ | Kernel.Var _ | Kernel.Ref _ | Kernel.GroupRef _ -> None
  | Kernel.Lam (params, body) ->
      let bound =
        List.fold_left (fun names pat -> SSet.union names (pat_names pat)) SSet.empty params
      in
      free_alias (shadow env bound) body
  | Kernel.App (fn, args) -> (
      match free_alias env fn with Some _ as found -> found | None -> first args)
  | Kernel.Let { isrec; binder; value; body } -> (
      let bound = pat_names binder in
      let value_env = if isrec then shadow env bound else env in
      match free_alias value_env value with
      | Some _ as found -> found
      | None -> free_alias (shadow env bound) body)
  | Kernel.Match (scrutinee, clauses) -> (
      match free_alias env scrutinee with
      | Some _ as found -> found
      | None ->
          List.find_map
            (fun ({ Kernel.cpat; cbody; _ } : Kernel.clause) ->
              free_alias (shadow env (pat_names cpat)) cbody)
            clauses)
  | Kernel.Tuple items -> first items
  | Kernel.Handle { body; ret; ops } -> (
      match free_alias env body with
      | Some _ as found -> found
      | None -> (
          match free_alias (shadow env (pat_names ret.rbinder)) ret.rbody with
          | Some _ as found -> found
          | None ->
              List.find_map
                (fun (clause : Kernel.opclause) ->
                  let bound =
                    List.fold_left
                      (fun names pat -> SSet.union names (pat_names pat))
                      (SSet.singleton clause.resume) clause.params
                  in
                  free_alias (shadow env bound) clause.obody)
                ops))
  | Kernel.Quote payload -> free_alias_in_quote env payload
  | Kernel.Unquote inner | Kernel.Ann (inner, _) -> free_alias env inner

and free_alias_in_quote env payload =
  let rec walk ?(level = 0) form =
    if form.Form.head = "unquote" && level = 0 then
      match form.Form.args with
      | [ Form.F splice ] -> (
          match Kernel.expr_of_form splice with Ok expr -> free_alias env expr | Error _ -> None)
      | _ -> None
    else
      let level =
        match form.Form.head with "quote" -> level + 1 | "unquote" -> level - 1 | _ -> level
      in
      List.find_map (function Form.F nested -> walk ~level nested | _ -> None) form.Form.args
  in
  walk payload

let alias_expr env (expr : Kernel.expr) =
  let rec unwrap expr =
    match expr.Kernel.it with Kernel.Ann (inner, _) -> unwrap inner | _ -> expr
  in
  let expr = unwrap expr in
  match expr.it with
  | Kernel.Var name when SSet.mem name env.aliases -> Some (name, expr.meta)
  | _ -> None

let callable_expr env (expr : Kernel.expr) =
  let rec unwrap expr =
    match expr.Kernel.it with Kernel.Ann (inner, _) -> unwrap inner | _ -> expr
  in
  let expr = unwrap expr in
  match expr.it with
  | Kernel.Var name -> SMap.find_opt name env.callables
  | Kernel.Ref (hash, Kernel.Term) ->
      Option.map
        (fun resolved ->
          {
            params = resolved.resolved_params;
            body = resolved.resolved_body;
            closure = SMap.empty;
            resolver = env.resolve_term;
            recursive = resolved.resolved_recursive;
          })
        (env.resolve_term hash)
  | Kernel.Lam (params, body) ->
      Some { params; body; closure = env.callables; resolver = env.resolve_term; recursive = false }
  | _ -> None

let is_constructor (expr : Kernel.expr) =
  let rec unwrap expr =
    match expr.Kernel.it with Kernel.Ann (inner, _) -> unwrap inner | _ -> expr
  in
  match (unwrap expr).it with Kernel.Ref (_, Kernel.Con) -> true | _ -> false

let rec analyze (env : env) ~(context : value_context) (expr : Kernel.expr) : flow =
  match expr.it with
  | Kernel.Lit _ | Kernel.Ref _ | Kernel.GroupRef _ -> zero
  | Kernel.Var name ->
      if SSet.mem name env.aliases then reject_escape ~binder:name ~meta:expr.meta context else zero
  | Kernel.Lam (params, body) -> (
      let bound =
        List.fold_left (fun names pat -> SSet.union names (pat_names pat)) SSet.empty params
      in
      let capture_env = shadow env bound in
      match free_alias capture_env body with
      | Some (binder, occurrence) ->
          reject ~code:"E0817" ~meta:expr.meta
            ~hint:"pass the once resumption as a Resume-typed parameter instead of capturing it"
            (Printf.sprintf
               "once resumption `%s` escapes into a closure captured here (free use at %s)" binder
               (span_text occurrence))
      | None -> zero)
  | Kernel.App (fn, args) -> (
      match alias_expr env fn with
      | Some (binder, _) ->
          seq (seq_all (List.map (analyze env ~context:Argument) args)) (consume binder expr.meta)
      | None ->
          let callee = callable_expr env fn in
          let constructor = is_constructor fn in
          let fn_flow = analyze env ~context:Function fn in
          let arg_flows =
            List.mapi
              (fun index arg ->
                match alias_expr env arg with
                | None -> analyze env ~context:Argument arg
                | Some (binder, alias_meta) -> (
                    if constructor then reject_escape ~binder ~meta:alias_meta Storage
                    else
                      match callee with
                      | Some callable ->
                          check_transfer callable index ~binder ~transfer_meta:alias_meta;
                          consume binder alias_meta
                      | None -> reject_escape ~binder ~meta:alias_meta Argument))
              args
          in
          seq fn_flow (seq_all arg_flows))
  | Kernel.Let { isrec; binder; value; body } -> (
      let bound = pat_names binder in
      let body_base = shadow env bound in
      match (binder.it, alias_expr env value) with
      | Kernel.PVar alias, Some _ ->
          (* Aliasing does not clone the token: both names refer to one budget. A later use of both
             aliases is rejected by the path composition above. *)
          let body_env =
            { body_base with aliases = SSet.add alias body_base.aliases |> SSet.union env.aliases }
          in
          analyze body_env ~context body
      | Kernel.PVar name, None -> (
          match callable_expr env value with
          | Some callable ->
              let value_flow = analyze env ~context:Binding value in
              let callable = { callable with recursive = isrec } in
              let body_env =
                {
                  aliases = SSet.diff env.aliases bound;
                  callables = SMap.add name callable body_base.callables;
                  resolve_term = env.resolve_term;
                }
              in
              seq value_flow (analyze body_env ~context body)
          | None ->
              seq
                (analyze (if isrec then shadow env bound else env) ~context:Binding value)
                (analyze body_base ~context body))
      | _ ->
          seq
            (analyze (if isrec then shadow env bound else env) ~context:Binding value)
            (analyze body_base ~context body))
  | Kernel.Match (scrutinee, clauses) ->
      let scrutinee_flow = analyze env ~context:Scrutinee scrutinee in
      let arms =
        List.map
          (fun ({ Kernel.cpat; cbody; _ } : Kernel.clause) ->
            analyze (shadow env (pat_names cpat)) ~context cbody)
          clauses
      in
      seq scrutinee_flow (alt arms)
  | Kernel.Tuple items -> seq_all (List.map (analyze env ~context:Storage) items)
  | Kernel.Handle { body; ret; ops } ->
      let body_flow = analyze env ~context:Binding body in
      let reject_clause_capture meta bound clause_body =
        match free_alias (shadow env bound) clause_body with
        | None -> ()
        | Some (binder, occurrence) ->
            reject ~code:"E0817" ~meta
              ~hint:"do not capture an outer once resumption in a nested handler clause"
              (Printf.sprintf
                 "once resumption `%s` escapes into a nested handler clause captured here (free \
                  use at %s)"
                 binder (span_text occurrence))
      in
      reject_clause_capture ret.rmeta (pat_names ret.rbinder) ret.rbody;
      List.iter
        (fun (clause : Kernel.opclause) ->
          let bound =
            List.fold_left
              (fun names pat -> SSet.union names (pat_names pat))
              (SSet.singleton clause.resume) clause.params
          in
          reject_clause_capture clause.ometa bound clause.obody)
        ops;
      body_flow
  | Kernel.Quote payload -> (
      match free_alias_in_quote env payload with
      | None -> zero
      | Some (binder, occurrence) ->
          reject ~code:"E0817" ~meta:expr.meta
            ~hint:"a once resumption cannot cross a quote boundary"
            (Printf.sprintf
               "once resumption `%s` escapes into quoted code captured here (splice at %s)" binder
               (span_text occurrence)))
  | Kernel.Unquote inner -> analyze env ~context:Argument inner
  | Kernel.Ann (subject, _) -> analyze env ~context subject

and check_transfer callable index ~binder ~transfer_meta =
  if callable.recursive then
    reject ~code:"E0817" ~meta:transfer_meta
      ~hint:"move the resumption only to a non-recursive local helper with a visibly affine body"
      (Printf.sprintf
         "once resumption `%s` cannot be transferred to a recursive parameter because its call \
          count is not locally bounded"
         binder);
  match List.nth_opt callable.params index with
  | Some { Kernel.it = Kernel.PWild; _ } -> ()
  | Some { Kernel.it = Kernel.PVar parameter; _ } ->
      let callables =
        List.fold_left
          (fun callables pat ->
            SSet.fold (fun name map -> SMap.remove name map) (pat_names pat) callables)
          callable.closure callable.params
      in
      ignore
        (analyze
           { aliases = SSet.singleton parameter; callables; resolve_term = callable.resolver }
           ~context:Return callable.body)
  | Some parameter ->
      reject ~code:"E0817" ~meta:parameter.meta
        ~hint:"bind the transferred resumption to one variable or `_`"
        (Printf.sprintf
           "once resumption `%s` cannot be transferred through a destructuring parameter" binder)
  | None ->
      (* Ordinary type inference will also report the arity mismatch, but retaining a local affine
         failure makes this API safe when used independently. *)
      reject ~code:"E0817" ~meta:transfer_meta
        (Printf.sprintf "once resumption `%s` has no receiving parameter at this call" binder)

(** [check_clause ~resolve_term ~resume body] verifies the affine contract of one [once] operation
    clause. [resolve_term] may expose a stored lambda so moving the token into a top-level helper is
    checked contextually just like a local helper; absent or non-lambda terms remain escape
    boundaries.

    Successful clauses consume the bound resumption on zero or one occurrence along every possible
    execution path. Failure returns exactly one E0816 (duplication) or E0817 (escape) diagnostic;
    the duplication message identifies both consumption spans, and capture failures point at the
    closure, quote, or nested-handler capture site. *)
let check_clause ?(resolve_term = fun _ -> None) ~resume (body : Kernel.expr) :
    (unit, Diag.t list) result =
  try
    ignore
      (analyze
         { aliases = SSet.singleton resume; callables = SMap.empty; resolve_term }
         ~context:Return body);
    Ok ()
  with Reject diagnostic -> Error [ diagnostic ]
