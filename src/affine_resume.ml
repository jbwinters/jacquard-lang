(** Local affine-usage checking for resumptions of [once] operations.

    The type checker gives a once-clause binder {!Types.TResume}; this pass supplies the
    substructural part that ordinary unification intentionally does not attempt. It follows one
    captured continuation token through local aliases and contextually checked local helper
    parameters. Sequential subexpressions share a budget, while match arms are alternatives; aligned
    sequential matches over the same immutable scrutinee retain that correlation rather than
    inventing infeasible cross-arm paths. A token may be dropped, called once, or moved into another
    parameter checked by this same pass; every other value use is an escape.

    This is deliberately local to one operation clause. It is not a general linear-type system, and
    failures are ordinary checker diagnostics returned as results. *)

module SSet = Set.Make (String)
module SMap = Map.Make (String)

type consumption = { binder : string; meta : Meta.t }

type stable_scrutinee =
  | Free of string
  | Bound of int
  | Global of Hash.t * Kernel.refkind
  | Group of int
  | Literal of Kernel.lit
  | Constructor of Hash.t * stable_scrutinee list
  | Tuple_value of stable_scrutinee list

type flow = { unused : bool; used : consumption option; partition : partition option }

and partition = { scrutinee : stable_scrutinee; arms : (Kernel.pat * flow) list }
(** A bounded abstraction of all paths through an expression. [unused] records whether some path
    leaves the token untouched, while [used] retains one consumption witness. [partition] preserves
    the arm summaries of a match over one immutable scrutinee, allowing a later aligned match over
    the same value to compose pointwise instead of inventing infeasible cross-arm paths. Independent
    or unrecognized control flow falls back to the conservative existential summary; concrete path
    products are never enumerated. *)

type callable = {
  key : string;
  params : Kernel.pat list;
  body : Kernel.expr;
  closure : callable SMap.t;
  stable_closure : stable_scrutinee SMap.t;
  resolver : Hash.t -> resolved_callable option;
  recursive : bool;
  diagnostic_source : string option;
  state : state;
}

and resolved_callable = {
  resolved_key : string;
  resolved_source : string;
  resolved_params : Kernel.pat list;
  resolved_body : Kernel.expr;
  resolved_recursive : bool;
}

and state = {
  summaries : (string, (flow, Diag.t) result) Hashtbl.t;
  mutable next_callable : int;
  mutable next_stable : int;
  check_duplication : bool;
  defer_out_of_range_transfer : bool;
  eliminate_resume_result : bool;
}

type clause_context = Ordinary | Immediately_applied_transformer

type env = {
  aliases : SSet.t;
  callables : callable SMap.t;
  stables : stable_scrutinee SMap.t;
  resolve_term : Hash.t -> resolved_callable option;
  diagnostic_source : string option;
  state : state;
}

type value_context = Return | Argument | Storage | Scrutinee | Binding | Function

let ( let* ) = Result.bind

let diagnostic_meta env meta =
  match (env.diagnostic_source, Meta.span meta) with
  | Some file, Some span ->
      Meta.with_span
        (Span.make ~file ~start_pos:span.Span.start_pos ~end_pos:span.Span.end_pos)
        meta
  | Some _, None | None, _ -> meta

let span_text meta =
  match Meta.span meta with
  | Some span -> Span.to_string span
  | None -> "an unknown source location"

let span_text_in env meta = span_text (diagnostic_meta env meta)

let reject ?next_step ~code ~meta cause =
  let summary =
    match code with
    | "E0816" -> "A once resumption may be consumed twice on one execution path."
    | "E0817" -> "A once resumption escapes its handler clause."
    | _ -> raise (Diag.Bug_invalid_diagnostic ("unknown affine diagnostic code " ^ code))
  in
  let next_step =
    Option.value next_step
      ~default:
        (match code with
        | "E0816" -> "Make every possible execution path consume the resumption at most once."
        | "E0817" -> "Consume, drop, or transfer the resumption within its affine clause boundary."
        | _ -> assert false)
  in
  Error
    (Diag.error ?span:(Meta.span meta) ~domain:Checker ~code ~summary ~cause ~next_step
       ~contrast:None ())

let reject_double first second =
  reject ~code:"E0816" ~meta:second.meta
    ~next_step:
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

let reject_escape env ~binder ~meta context =
  reject ~code:"E0817" ~meta:(diagnostic_meta env meta)
    ~next_step:
      "call the resumption once, drop it, or move it to a local parameter that is checked as \
       Resume-typed"
    (escape_message binder context)

let zero = { unused = true; used = None; partition = None }

let consume env binder meta =
  { unused = false; used = Some { binder; meta = diagnostic_meta env meta }; partition = None }

(** [summary_seq state left right] is the conservative composition used when no shared immutable
    scrutinee partition proves which arms are feasible together. *)
let summary_seq state left right =
  match (left.used, right.used) with
  | Some first, Some second when state.check_duplication -> reject_double first second
  | Some used, Some _ ->
      Ok { unused = left.unused && right.unused; used = Some used; partition = None }
  | Some used, None ->
      Ok { unused = left.unused && right.unused; used = Some used; partition = None }
  | None, Some used ->
      Ok { unused = left.unused && right.unused; used = Some used; partition = None }
  | None, None -> Ok { unused = left.unused && right.unused; used = None; partition = None }

let alt flows =
  match flows with
  | [] -> zero
  | _ ->
      {
        unused = List.exists (fun flow -> flow.unused) flows;
        used = List.find_map (fun flow -> flow.used) flows;
        partition = None;
      }

let equal_lit left right =
  match (left, right) with
  | Kernel.LInt left, Kernel.LInt right -> left = right
  | Kernel.LReal left, Kernel.LReal right ->
      Float.compare left right = 0 || (left = 0.0 && right = 0.0)
  | Kernel.LText left, Kernel.LText right -> String.equal left right
  | Kernel.LInt _, (Kernel.LReal _ | Kernel.LText _)
  | Kernel.LReal _, (Kernel.LInt _ | Kernel.LText _)
  | Kernel.LText _, (Kernel.LInt _ | Kernel.LReal _) ->
      false

let equal_gref left right =
  match (left, right) with
  | Kernel.Named left, Kernel.Named right -> String.equal left right
  | Kernel.Hashed left, Kernel.Hashed right -> Hash.equal left right
  | Kernel.Named _, Kernel.Hashed _ | Kernel.Hashed _, Kernel.Named _ -> false

let rec equal_pattern left right =
  match (left.Kernel.it, right.Kernel.it) with
  | (Kernel.PWild | Kernel.PVar _), (Kernel.PWild | Kernel.PVar _) -> true
  | Kernel.PLit left, Kernel.PLit right -> equal_lit left right
  | Kernel.PCon (left_ref, left_args), Kernel.PCon (right_ref, right_args) ->
      equal_gref left_ref right_ref && equal_patterns left_args right_args
  | Kernel.PTuple left, Kernel.PTuple right -> equal_patterns left right
  | Kernel.PAs (_, left), Kernel.PAs (_, right) -> equal_pattern left right
  | Kernel.PAs (_, left), _ -> equal_pattern left right
  | _, Kernel.PAs (_, right) -> equal_pattern left right
  | (Kernel.PWild | Kernel.PVar _ | Kernel.PLit _ | Kernel.PCon _ | Kernel.PTuple _), _ -> false

and equal_patterns left right =
  List.length left = List.length right && List.for_all2 equal_pattern left right

let rec equal_scrutinee left right =
  match (left, right) with
  | Free left, Free right -> String.equal left right
  | Bound left, Bound right -> left = right
  | Global (left_hash, left_kind), Global (right_hash, right_kind) ->
      Hash.equal left_hash right_hash && left_kind = right_kind
  | Group left, Group right -> left = right
  | Literal left, Literal right -> equal_lit left right
  | Constructor (left_hash, left_args), Constructor (right_hash, right_args) ->
      Hash.equal left_hash right_hash
      && List.length left_args = List.length right_args
      && List.for_all2 equal_scrutinee left_args right_args
  | Tuple_value left, Tuple_value right ->
      List.length left = List.length right && List.for_all2 equal_scrutinee left right
  | (Free _ | Bound _ | Global _ | Group _ | Literal _ | Constructor _ | Tuple_value _), _ -> false

let aligned_partitions left right =
  equal_scrutinee left.scrutinee right.scrutinee
  && List.length left.arms = List.length right.arms
  && List.for_all2
       (fun (left_pattern, _) (right_pattern, _) -> equal_pattern left_pattern right_pattern)
       left.arms right.arms

let partitioned scrutinee arms =
  let summary = alt (List.map snd arms) in
  { summary with partition = Some { scrutinee; arms } }

(** [seq state left right] composes two expressions that both execute. Aligned partitions over the
    same immutable scrutinee compose arm by arm, so mutually exclusive correlated branches stay
    exclusive. A partition composed with an unpartitioned summary is checked once per arm. Unknown
    relationships retain [summary_seq]'s conservative behavior. *)
let rec seq state left right =
  match (left.partition, right.partition) with
  | Some left_partition, Some right_partition when aligned_partitions left_partition right_partition
    ->
      let rec combine arms left_arms right_arms =
        match (left_arms, right_arms) with
        | [], [] -> Ok (List.rev arms)
        | (pattern, left_flow) :: left_rest, (_, right_flow) :: right_rest ->
            let* flow = seq state left_flow right_flow in
            combine ((pattern, flow) :: arms) left_rest right_rest
        | [], _ :: _ | _ :: _, [] -> failwith "Bug_affine_resume: aligned partition arity"
      in
      let* arms = combine [] left_partition.arms right_partition.arms in
      Ok (partitioned left_partition.scrutinee arms)
  | Some partition, None ->
      let rec combine arms = function
        | [] -> Ok (List.rev arms)
        | (pattern, flow) :: rest ->
            let* flow = seq state flow right in
            combine ((pattern, flow) :: arms) rest
      in
      let* arms = combine [] partition.arms in
      Ok (partitioned partition.scrutinee arms)
  | None, Some partition ->
      let rec combine arms = function
        | [] -> Ok (List.rev arms)
        | (pattern, flow) :: rest ->
            let* flow = seq state left flow in
            combine ((pattern, flow) :: arms) rest
      in
      let* arms = combine [] partition.arms in
      Ok (partitioned partition.scrutinee arms)
  | Some _, Some _ | None, None -> summary_seq state left right

let rec pat_names (pat : Kernel.pat) =
  match pat.it with
  | Kernel.PVar name -> SSet.singleton name
  | Kernel.PAs (name, inner) -> SSet.add name (pat_names inner)
  | Kernel.PCon (_, items) | Kernel.PTuple items ->
      List.fold_left (fun names item -> SSet.union names (pat_names item)) SSet.empty items
  | Kernel.PWild | Kernel.PLit _ -> SSet.empty

let shadow env names =
  let stables =
    SSet.fold
      (fun name stables ->
        let id = env.state.next_stable in
        env.state.next_stable <- id + 1;
        SMap.add name (Bound id) stables)
      names env.stables
  in
  {
    aliases = SSet.diff env.aliases names;
    callables = SSet.fold (fun name map -> SMap.remove name map) names env.callables;
    stables;
    resolve_term = env.resolve_term;
    diagnostic_source = env.diagnostic_source;
    state = env.state;
  }

let fresh_callable_key env =
  let id = env.state.next_callable in
  env.state.next_callable <- id + 1;
  Printf.sprintf "local:%d" id

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

(** [quote_has_live_splice payload] reports whether evaluating a quote payload evaluates an unquote.
    Such a quote is not an effect-free argument for immediate transformer elimination. *)
let rec quote_has_live_splice ?(level = 0) (payload : Form.t) =
  if payload.head = "unquote" && level = 0 then true
  else
    let nested_level =
      match payload.head with "quote" -> level + 1 | "unquote" -> level - 1 | _ -> level
    in
    List.exists
      (function Form.F nested -> quote_has_live_splice ~level:nested_level nested | _ -> false)
      payload.args

let rec is_immediate_transformer_argument (expr : Kernel.expr) =
  match expr.it with
  | Kernel.Lit _ | Kernel.Lam _ | Kernel.Var _ | Kernel.Ref _ | Kernel.GroupRef _ -> true
  | Kernel.Quote payload -> not (quote_has_live_splice payload)
  | Kernel.Tuple items -> List.for_all is_immediate_transformer_argument items
  | Kernel.App ({ it = Kernel.Ref (_, Kernel.Con); _ }, args) ->
      List.for_all is_immediate_transformer_argument args
  | Kernel.Ann (inner, _) -> is_immediate_transformer_argument inner
  | Kernel.App _ | Kernel.Let _ | Kernel.Match _ | Kernel.Handle _ | Kernel.Unquote _ -> false

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
            key = "stored:" ^ resolved.resolved_key;
            params = resolved.resolved_params;
            body = resolved.resolved_body;
            closure = SMap.empty;
            stable_closure = SMap.empty;
            resolver = env.resolve_term;
            recursive = resolved.resolved_recursive;
            diagnostic_source = Some resolved.resolved_source;
            state = env.state;
          })
        (env.resolve_term hash)
  | Kernel.Lam (params, body) ->
      Some
        {
          key = fresh_callable_key env;
          params;
          body;
          closure = env.callables;
          stable_closure = env.stables;
          resolver = env.resolve_term;
          recursive = false;
          diagnostic_source = env.diagnostic_source;
          state = env.state;
        }
  | _ -> None

let is_constructor (expr : Kernel.expr) =
  let rec unwrap expr =
    match expr.Kernel.it with Kernel.Ann (inner, _) -> unwrap inner | _ -> expr
  in
  match (unwrap expr).it with Kernel.Ref (_, Kernel.Con) -> true | _ -> false

let rec stable_scrutinee env (expr : Kernel.expr) =
  let rec unwrap expr =
    match expr.Kernel.it with Kernel.Ann (inner, _) -> unwrap inner | _ -> expr
  in
  match (unwrap expr).it with
  | Kernel.Var name -> Some (Option.value ~default:(Free name) (SMap.find_opt name env.stables))
  | Kernel.Ref (hash, Kernel.Con) -> Some (Constructor (hash, []))
  | Kernel.Ref (hash, kind) -> Some (Global (hash, kind))
  | Kernel.GroupRef index -> Some (Group index)
  | Kernel.Lit literal -> Some (Literal literal)
  | Kernel.Tuple items ->
      Option.map
        (fun items -> Tuple_value items)
        (List.fold_right (stable_cons env) items (Some []))
  | Kernel.App ({ it = Kernel.Ref (hash, Kernel.Con); _ }, args) ->
      Option.map
        (fun args -> Constructor (hash, args))
        (List.fold_right (stable_cons env) args (Some []))
  | Kernel.Lam _ | Kernel.App _ | Kernel.Let _ | Kernel.Match _ | Kernel.Handle _ | Kernel.Quote _
  | Kernel.Unquote _ | Kernel.Ann _ ->
      None

and stable_cons env expression tail =
  match (stable_scrutinee env expression, tail) with
  | Some head, Some tail -> Some (head :: tail)
  | None, _ | _, None -> None

let rec analyze ?(result_is_immediately_eliminated = false) (env : env) ~(context : value_context)
    (expr : Kernel.expr) : (flow, Diag.t) result =
  match expr.it with
  | Kernel.Lit _ | Kernel.Ref _ | Kernel.GroupRef _ -> Ok zero
  | Kernel.Var name ->
      if SSet.mem name env.aliases then reject_escape env ~binder:name ~meta:expr.meta context
      else Ok zero
  | Kernel.Lam (params, body) -> (
      let bound =
        List.fold_left (fun names pat -> SSet.union names (pat_names pat)) SSet.empty params
      in
      let capture_env = shadow env bound in
      match free_alias capture_env body with
      | Some (binder, occurrence) ->
          reject ~code:"E0817" ~meta:(diagnostic_meta env expr.meta)
            ~next_step:
              "Pass the once resumption as a Resume-typed parameter instead of capturing it."
            (Printf.sprintf
               "once resumption `%s` escapes into a closure captured here (free use at %s)" binder
               (span_text_in env occurrence))
      | None -> Ok zero)
  | Kernel.App (fn, args) -> (
      match alias_expr env fn with
      | Some (binder, _) ->
          let* args_flow = analyze_sequence env ~context:Argument args in
          if
            env.state.eliminate_resume_result
            && (not result_is_immediately_eliminated)
            && not (env.state.defer_out_of_range_transfer && List.length args <> 1)
          then
            reject ~code:"E0817" ~meta:(diagnostic_meta env expr.meta)
              ~next_step:
                "immediately apply the resumption result exactly once as the function child of a \
                 nested application whose arguments are syntactic values"
              (Printf.sprintf
                 "once resumption `%s` may produce a transformer carrying a later once resumption; \
                  its result must be eliminated immediately"
                 binder)
          else seq env.state args_flow (consume env binder expr.meta)
      | None ->
          let callee = callable_expr env fn in
          let constructor = is_constructor fn in
          let result_is_immediately_eliminated =
            List.for_all is_immediate_transformer_argument args
          in
          let* fn_flow = analyze ~result_is_immediately_eliminated env ~context:Function fn in
          let* args_flow = analyze_arguments env ~callee ~constructor args in
          seq env.state fn_flow args_flow)
  | Kernel.Let { isrec; binder; value; body } -> (
      let bound = pat_names binder in
      let body_base = shadow env bound in
      let body_base =
        match (binder.it, stable_scrutinee env value) with
        | Kernel.PVar name, Some stable ->
            { body_base with stables = SMap.add name stable body_base.stables }
        | _ -> body_base
      in
      match (binder.it, alias_expr env value) with
      | Kernel.PVar alias, Some _ ->
          (* Aliasing does not clone the token: both names refer to one budget. A later use of both
             aliases is rejected by sequential composition. *)
          let body_env =
            { body_base with aliases = SSet.add alias body_base.aliases |> SSet.union env.aliases }
          in
          let* body_flow = analyze body_env ~context body in
          Ok body_flow
      | Kernel.PVar name, None -> (
          match callable_expr env value with
          | Some callable ->
              let* value_flow = analyze env ~context:Binding value in
              let callable = { callable with recursive = isrec } in
              let body_env =
                {
                  aliases = SSet.diff env.aliases bound;
                  callables = SMap.add name callable body_base.callables;
                  stables = body_base.stables;
                  resolve_term = env.resolve_term;
                  diagnostic_source = env.diagnostic_source;
                  state = env.state;
                }
              in
              let* body_flow = analyze body_env ~context body in
              seq env.state value_flow body_flow
          | None ->
              let value_env = if isrec then shadow env bound else env in
              let* value_flow = analyze value_env ~context:Binding value in
              let* body_flow = analyze body_base ~context body in
              seq env.state value_flow body_flow)
      | _ ->
          let value_env = if isrec then shadow env bound else env in
          let* value_flow = analyze value_env ~context:Binding value in
          let* body_flow = analyze body_base ~context body in
          seq env.state value_flow body_flow)
  | Kernel.Match (scrutinee, clauses) ->
      let* scrutinee_flow = analyze env ~context:Scrutinee scrutinee in
      let* arms = analyze_arms env ~context clauses in
      let branch_flow =
        match stable_scrutinee env scrutinee with
        | Some scrutinee ->
            partitioned scrutinee
              (List.map2
                 (fun ({ Kernel.cpat; _ } : Kernel.clause) flow -> (cpat, flow))
                 clauses arms)
        | None -> alt arms
      in
      seq env.state scrutinee_flow branch_flow
  | Kernel.Tuple items -> analyze_sequence env ~context:Storage items
  | Kernel.Handle { body; ret; ops } ->
      let* body_flow = analyze env ~context:Binding body in
      let* () = check_clause_capture env ret.rmeta (pat_names ret.rbinder) ret.rbody in
      let* () = check_operation_captures env ops in
      Ok body_flow
  | Kernel.Quote payload -> (
      match free_alias_in_quote env payload with
      | None -> Ok zero
      | Some (binder, occurrence) ->
          reject ~code:"E0817" ~meta:(diagnostic_meta env expr.meta)
            ~next_step:"Keep the once resumption outside quoted code."
            (Printf.sprintf
               "once resumption `%s` escapes into quoted code captured here (splice at %s)" binder
               (span_text_in env occurrence)))
  | Kernel.Unquote inner -> analyze env ~context:Argument inner
  | Kernel.Ann (subject, _) -> analyze ~result_is_immediately_eliminated env ~context subject

and analyze_sequence env ~context expressions =
  let rec loop accumulated = function
    | [] -> Ok accumulated
    | expression :: rest ->
        let* next = analyze env ~context expression in
        let* accumulated = seq env.state accumulated next in
        loop accumulated rest
  in
  loop zero expressions

and analyze_arguments env ~callee ~constructor args =
  let rec loop index accumulated = function
    | [] -> Ok accumulated
    | argument :: rest ->
        let* argument_flow =
          match alias_expr env argument with
          | None -> analyze env ~context:Argument argument
          | Some (binder, alias_meta) -> (
              if constructor then reject_escape env ~binder ~meta:alias_meta Storage
              else
                match callee with
                | Some callable ->
                    let* () =
                      check_transfer callable index ~binder
                        ~transfer_meta:(diagnostic_meta env alias_meta)
                    in
                    Ok (consume env binder alias_meta)
                | None -> reject_escape env ~binder ~meta:alias_meta Argument)
        in
        let* accumulated = seq env.state accumulated argument_flow in
        loop (index + 1) accumulated rest
  in
  loop 0 zero args

and analyze_arms env ~context clauses =
  let rec loop flows = function
    | [] -> Ok (List.rev flows)
    | ({ Kernel.cpat; cbody; _ } : Kernel.clause) :: rest ->
        let bound = pat_names cpat in
        let* flow = analyze (shadow env bound) ~context cbody in
        loop (flow :: flows) rest
  in
  loop [] clauses

and check_clause_capture env meta bound clause_body =
  match free_alias (shadow env bound) clause_body with
  | None -> Ok ()
  | Some (binder, occurrence) ->
      reject ~code:"E0817" ~meta:(diagnostic_meta env meta)
        ~next_step:"Do not capture an outer once resumption in a nested handler clause."
        (Printf.sprintf
           "once resumption `%s` escapes into a nested handler clause captured here (free use at \
            %s)"
           binder (span_text_in env occurrence))

and check_operation_captures env = function
  | [] -> Ok ()
  | (clause : Kernel.opclause) :: rest ->
      let bound =
        List.fold_left
          (fun names pat -> SSet.union names (pat_names pat))
          (SSet.singleton clause.resume) clause.params
      in
      let* () = check_clause_capture env clause.ometa bound clause.obody in
      check_operation_captures env rest

and check_transfer callable index ~binder ~transfer_meta =
  match List.nth_opt callable.params index with
  | Some _ when callable.recursive ->
      reject ~code:"E0817" ~meta:transfer_meta
        ~next_step:
          "Move the resumption only to a non-recursive local helper with a visibly affine body."
        (Printf.sprintf
           "once resumption `%s` cannot be transferred to a recursive parameter because its call \
            count is not locally bounded"
           binder)
  | Some { Kernel.it = Kernel.PWild; _ } -> Ok ()
  | Some { Kernel.it = Kernel.PVar parameter; _ } -> (
      let callables =
        List.fold_left
          (fun callables pat ->
            SSet.fold (fun name map -> SMap.remove name map) (pat_names pat) callables)
          callable.closure callable.params
      in
      let summary_key = Printf.sprintf "%s:%d" callable.key index in
      let summary =
        match Hashtbl.find_opt callable.state.summaries summary_key with
        | Some summary -> summary
        | None ->
            let summary =
              let bound =
                List.fold_left
                  (fun names pat -> SSet.union names (pat_names pat))
                  SSet.empty callable.params
              in
              let summary_env =
                shadow
                  {
                    aliases = SSet.empty;
                    callables;
                    stables = callable.stable_closure;
                    resolve_term = callable.resolver;
                    diagnostic_source = callable.diagnostic_source;
                    state = callable.state;
                  }
                  bound
              in
              analyze
                { summary_env with aliases = SSet.singleton parameter }
                ~context:Return callable.body
            in
            Hashtbl.add callable.state.summaries summary_key summary;
            summary
      in
      match summary with
      | Ok _ -> Ok ()
      | Error diagnostic when Option.is_some callable.diagnostic_source ->
          (* Stored object bytes cannot retain original source metadata. E0817 therefore stays
               anchored at this author-visible transfer, while its message may identify a durable
               logical helper occurrence. E0816 deliberately keeps its two distinct normalized
               helper witnesses. *)
          if Diag.code diagnostic = Some "E0817" then
            Error (Diag.with_span (Meta.span transfer_meta) diagnostic)
          else Error diagnostic
      | Error diagnostic -> Error diagnostic)
  | Some parameter ->
      let meta =
        match callable.diagnostic_source with Some _ -> transfer_meta | None -> parameter.meta
      in
      reject ~code:"E0817" ~meta
        ~next_step:"Bind the transferred resumption to one variable or `_`."
        (Printf.sprintf
           "once resumption `%s` cannot be transferred through a destructuring parameter" binder)
  | None ->
      if callable.state.defer_out_of_range_transfer then
        (* A known local or stored lambda has a fixed arity, so ordinary inference will report
           E0803 for this malformed call. The escape-only prepass must not let the out-of-range
           Resume argument hide that more fundamental error. Full affine checking retains the
           E0817 fallback below so [check_clause] remains safe as a standalone API. *)
        Ok ()
      else
        reject ~code:"E0817" ~meta:transfer_meta
          (Printf.sprintf "once resumption `%s` has no receiving parameter at this call" binder)

(** [analyze_clause_body env context body] starts the affine walk at an operation-clause boundary.
    The immediate-transformer context is supplied only after the checker has proved that the
    enclosing [Handle] is the direct function child of an application with syntactic-value
    arguments. Strict function-first evaluation then constructs and applies the outer lambda once.
    Only that one lambda boundary is opened; [analyze] keeps rejecting every nested capture. *)
let analyze_clause_body env context (body : Kernel.expr) =
  match (context, body.it) with
  | Immediately_applied_transformer, Kernel.Lam (params, lambda_body) ->
      let bound =
        List.fold_left (fun names pat -> SSet.union names (pat_names pat)) SSet.empty params
      in
      analyze (shadow env bound) ~context:Return lambda_body
  | Ordinary, _ | Immediately_applied_transformer, _ -> analyze env ~context:Return body

(** [check_clause ~resolve_term ~resume body] verifies the affine contract of one [once] operation
    clause. [resolve_term] may expose a stored lambda so moving the token into a top-level helper is
    checked contextually just like a local helper; absent or non-lambda terms remain escape
    boundaries. Stored declarations have identity-preserving object bytes rather than author spans.
    Their E0817 failures stay anchored at the source transfer site, while E0816 uses distinct
    durable logical locations derived from the helper name, member hash, and canonical positions.

    Successful clauses consume the bound resumption on zero or one occurrence along every possible
    execution path. Failure returns exactly one E0816 (duplication) or E0817 (escape) diagnostic;
    the duplication message identifies both consumption spans, and capture failures point at the
    closure, quote, nested-handler capture, or stored-helper transfer site. Contextual helper
    summaries are memoized per callable parameter so duplicate branch transfers remain polynomial.
    Aligned matches over the same immutable variable or resolved reference retain one bounded arm
    partition, so complementary consuming arms compose without a false duplicate while any feasible
    same-arm duplication still fails. In the immediate-transformer context, every call of the
    captured resumption must itself be the direct function child of one application. This
    immediately eliminates the returned answer, which may otherwise carry a later Once token
    produced by a successive operation clause. *)
let check ~check_duplication ~defer_out_of_range_transfer ?(resolve_term = fun _ -> None)
    ?(context = Ordinary) ~resume (body : Kernel.expr) =
  let state =
    {
      summaries = Hashtbl.create 16;
      next_callable = 0;
      next_stable = 0;
      check_duplication;
      defer_out_of_range_transfer;
      eliminate_resume_result = context = Immediately_applied_transformer;
    }
  in
  match
    analyze_clause_body
      {
        aliases = SSet.singleton resume;
        callables = SMap.empty;
        stables = SMap.empty;
        resolve_term;
        diagnostic_source = None;
        state;
      }
      context body
  with
  | Ok _ -> Ok ()
  | Error diagnostic -> Error [ diagnostic ]

let check_clause ?resolve_term ?context ~resume body =
  check ~check_duplication:true ~defer_out_of_range_transfer:false ?resolve_term ?context ~resume
    body

let check_escapes ?resolve_term ?context ~resume body =
  check ~check_duplication:false ~defer_out_of_range_transfer:true ?resolve_term ?context ~resume
    body
