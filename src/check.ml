(** The type and effect checker (plan W3.2 expression inference, W3.3 declarations, W3.4 handler
    typing).

    Algorithm W with levels (see {!Types}), an ambient effect row threaded through inference, and
    [Ann] as a checking anchor (bidirectional lite):

    - Every application unifies the callee's row with the ambient row, after OPENING a closed callee
      row with a fresh tail (Leijen's open coercion) so a pure or fewer-effects function can run in
      a richer context — subsumption without subtyping.
    - [Lam] starts a fresh open ambient row that lands on its arrow.
    - Generalization at [Let] obeys the value restriction (only syntactic values), and closes
      generalizable row tails that occur exactly once in the scheme, so an unconstrained function
      displays as [(a) ->{} a] rather than a spurious [->{e}].
    - Annotations are converted with RIGID variables (skolems) for checking; the same annotation
      converts with flexible variables when used as a mutual-recursion signature (W3.3: annotations
      honored as checks).
    - [Handle] (W3.4): the body's ambient is the handled effects joined onto the outer ambient
      (removal is implicit: handled effects stop at the handler, everything else shares the outer
      row); the return binder gets the body's type; a [multi] clause's [resume] is an ordinary
      arrow, while a [once] clause receives the built-in affine [Resume] callable; {!Affine_resume}
      rejects escapes before ordinary inference, then rejects duplicate valid consumptions after the
      clause body checks at the answer type under the outer ambient. The sole affine-closure rule is
      a direct clause lambda returned by a [Handle] that is itself immediately applied once to
      syntactic-value arguments; only that outer lambda boundary is opened.

    Store terms are checked on demand and cached by hash; the store's hash DAG guarantees no
    cross-declaration cycles. Builtin markers get their signatures from
    {!Prelude.builtin_signatures}-style registration rather than their marker bodies.

    Diagnostics (first error wins, codes E08xx): E0801 type mismatch, E0802 not a function, E0803
    application arity, E0804 annotation mismatch, E0805 unknown hash/metadata, E0806 constructor
    pattern arity, E0807 surface eta-expansion guidance, E0810 type-constructor arity in an
    annotation, E0811 unbound type/row variable in a declaration or annotation. *)

open Types
module SMap = Map.Make (String)

type ctx = {
  store : Store.t;
  p_int : Hash.t;
  p_real : Hash.t;
  p_text : Hash.t;
  p_code : Hash.t;
  builtin_sigs : (Hash.t, scheme) Hashtbl.t;
  term_sigs : (Hash.t, scheme) Hashtbl.t;
  mutable level : int;
  mutable checking : Hash.t list;  (** decl hashes currently being checked (cycle guard) *)
  mutable sites : match_site list;
      (** match sites recorded for the exhaustiveness pass (W3.5), which runs after inference so
          scrutinee types are fully solved *)
  mutable origins : (Hash.t * string) list;
      (** effect hash -> a callee that introduced it (the manifest diagnostic's call-chain endpoint,
          W3.6) *)
  mutable tier_apps : (Types.row * Tier.app_kind) list;
      (** every application's callee row (PF.2 phase 1 statistics). Rows are recorded by reference
          and classified after solving, like [sites]; unlike [sites] this accumulates for the
          context's whole lifetime, so one ctx measures a whole program. *)
  mutable tier_ops : (Hash.t * Tier.discipline) list;
      (** op hash -> one handler clause's syntactic resume discipline (PF.2 phase 1) *)
}

and match_site = { scrutinee_ty : Types.ty; arms : Kernel.clause list; site_meta : Meta.t }

(** [store ctx] returns the declaration store used by the checker. *)
let store ctx = ctx.store

(** [register_builtin_signatures ctx signatures] installs trusted native-term schemes. Existing
    entries at the same hashes are replaced. *)
let register_builtin_signatures ctx signatures =
  List.iter (fun (hash, scheme) -> Hashtbl.replace ctx.builtin_sigs hash scheme) signatures

(** [tier_applications ctx] returns the application classifications recorded by strict checks. *)
let tier_applications ctx = ctx.tier_apps

(** [tier_operations ctx] returns the operation disciplines recorded by strict checks. *)
let tier_operations ctx = ctx.tier_ops

type env = { vars : scheme SMap.t; group : (string * ty) array }
(** [group]: during a defterm group check, member index -> (name, mono or annotated type). *)

let empty_env = { vars = SMap.empty; group = [||] }

(* Internal control flow only; never escapes this module. *)
exception Err of Diag.t

let err ?meta ?hint ~code fmt =
  Printf.ksprintf
    (fun msg -> raise (Err (Diag.error ?span:(Option.bind meta Meta.span) ?hint ~code msg)))
    fmt

let name_of ctx h =
  match Store.locate ctx.store h with
  | Ok { Store.decl; role; _ } -> (
      match (decl.Kernel.it, role) with
      | Kernel.DefType { tname; _ }, Store.Whole -> tname
      | Kernel.DefEffect { ename; _ }, Store.Whole -> ename
      | Kernel.DefType { cons; _ }, Store.Constructor i -> (
          match List.nth_opt cons i with Some c -> c.Kernel.con_name | None -> "?")
      | Kernel.DefEffect { ops; _ }, Store.Operation i -> (
          match List.nth_opt ops i with Some o -> o.Kernel.op_name | None -> "?")
      | Kernel.DefTerm bindings, Store.Member i -> (
          match List.nth_opt bindings i with Some b -> b.Kernel.bname | None -> "?")
      | _ -> String.sub (Hash.to_hex h) 0 8)
  | Error _ -> String.sub (Hash.to_hex h) 0 8

let show_ty ctx t = Types.show ~name_of:(name_of ctx) t

let surface_name_of ctx kind hash =
  match Store.locate ctx.store hash with
  | Ok _ -> Surface_name.render kind (name_of ctx hash)
  | Error _ -> Printf.sprintf "#%s:%s" (Hash.to_hex hash) (Surface_name.kind_tag kind)

(** [show_scheme] renders inferred checker signatures as parseable surface type/effect notation.
    Unknown hashes remain explicit kind-tagged references rather than losing identity. *)
let show_scheme ctx s =
  Types.show_scheme ~surface:true
    ~name_of:(surface_name_of ctx Surface_name.Type)
    ~effect_name_of:(surface_name_of ctx Surface_name.Effect)
    s

let surface_form_is meta forms =
  match Meta.surface_form meta with Some form -> List.mem form forms | None -> false

let eta_expansion_candidate ctx expected actual =
  match (repr expected, repr actual) with
  | TArrow ([], _, _), TArrow _ -> false
  | TArrow ([], _, _), actual ->
      Types.unifiable expected (TArrow ([], open_row ctx.level [], actual))
  | _ -> false

let unify_or ctx ?meta ?hint ~what expected actual =
  try Types.unify expected actual
  with Unify_error detail ->
    err ?meta
      ~hint:
        (Option.value hint
           ~default:"the expected side comes from the surrounding context; make both sides agree")
      ~code:"E0801" "%s: expected %s, got %s (%s)" what (show_ty ctx expected) (show_ty ctx actual)
      detail

(* Open coercion: a closed callee row gains a fresh tail before meeting the ambient row,
   so exact rows mean "at most these effects" at call sites. *)
let opened ctx (r : row) : row =
  let r = repr_row r in
  match r.tail with RClosed -> { r with tail = new_rvar ctx.level } | _ -> r

let prim h = TCon (h, [])

(* ------------------------------------------------------------------ *)
(* Declared-type metadata                                              *)
(* ------------------------------------------------------------------ *)

let type_arity ctx ?meta (h : Hash.t) : int =
  match Store.locate ctx.store h with
  | Ok { Store.decl = { Kernel.it = Kernel.DefType { tvars; _ }; _ }; role = Store.Whole; _ } ->
      List.length tvars
  | Ok _ -> err ?meta ~code:"E0805" "hash %s is not a type" (Hash.to_hex h)
  | Error ds -> err ?meta ~code:"E0805" "%s" (String.concat "; " (List.map Diag.to_string ds))

(* ------------------------------------------------------------------ *)
(* Annotation conversion                                               *)
(* ------------------------------------------------------------------ *)

type conv_mode = Rigid | Flexible

type conv_env = {
  mode : conv_mode;
  mutable tvs : (string * ty) list;
  mutable rvs : (string * rtail) list;
}

let conv_fresh_tv ctx cenv name =
  let v =
    match cenv.mode with Rigid -> TSkolem (fresh_id (), name) | Flexible -> new_tvar ctx.level
  in
  cenv.tvs <- (name, v) :: cenv.tvs;
  v

let conv_fresh_rv ctx cenv name =
  let v =
    match cenv.mode with Rigid -> RSkolem (fresh_id (), name) | Flexible -> new_rvar ctx.level
  in
  cenv.rvs <- (name, v) :: cenv.rvs;
  v

(* Convert a resolved surface type (an annotation) to an internal type. Free type/row
   variables are implicitly quantified at the annotation: first use introduces them. *)
let rec conv_ty ctx cenv (t : Kernel.ty) : ty =
  let meta = t.Kernel.meta in
  match t.Kernel.it with
  | _ when Option.is_some (Meta.surface_hole meta) -> new_tvar ctx.level
  | Kernel.TRef (Kernel.Hashed h) ->
      let arity = type_arity ctx ~meta h in
      if arity <> 0 then
        err ~meta ~code:"E0810" "type %s expects %d argument(s), got 0" (name_of ctx h) arity;
      TCon (h, [])
  | Kernel.TRef (Kernel.Named n) -> err ~meta ~code:"E0811" "unresolved type name `%s`" n
  | Kernel.TVar a -> (
      match List.assoc_opt a cenv.tvs with Some v -> v | None -> conv_fresh_tv ctx cenv a)
  | Kernel.TApp ({ Kernel.it = Kernel.TRef (Kernel.Hashed h); _ }, args) ->
      let arity = type_arity ctx ~meta h in
      if arity <> List.length args then
        err ~meta ~code:"E0810" "type %s expects %d argument(s), got %d" (name_of ctx h) arity
          (List.length args);
      TCon (h, List.map (conv_ty ctx cenv) args)
  | Kernel.TApp _ -> err ~meta ~code:"E0810" "only declared types can be applied"
  | Kernel.TArrow (params, row, result) ->
      TArrow
        ( List.map (conv_ty ctx cenv) params,
          conv_row ctx cenv ~effectself:None row,
          conv_ty ctx cenv result )
  | Kernel.TTuple items -> TTuple (List.map (conv_ty ctx cenv) items)
  | Kernel.TForall (tvs, rvs, body) ->
      (* binders introduce (or shadow) names in the conversion scope *)
      List.iter (fun a -> ignore (conv_fresh_tv ctx cenv a)) tvs;
      List.iter (fun e -> ignore (conv_fresh_rv ctx cenv e)) rvs;
      conv_ty ctx cenv body

and conv_row ctx cenv ~effectself (r : Kernel.row) : row =
  let effects =
    List.map
      (function
        | Kernel.Hashed h -> h
        | Kernel.Named n -> (
            match effectself with
            | Some (self_name, hash) when String.equal n self_name -> hash
            | _ -> err ~meta:r.Kernel.wmeta ~code:"E0811" "unresolved effect name `%s`" n))
      r.Kernel.effects
  in
  let tail =
    match r.Kernel.rvar with
    | None -> RClosed
    | Some v -> (
        match List.assoc_opt v cenv.rvs with Some t -> t | None -> conv_fresh_rv ctx cenv v)
  in
  { effects = List.sort_uniq Hash.compare effects; tail }

(* ------------------------------------------------------------------ *)
(* Declaration schemes: constructors, ops, terms                       *)
(* ------------------------------------------------------------------ *)

(* Constructor scheme: forall vars. (fields) ->{} T vars  (nullary: T vars). Field types are
   declaration types: tyvars come from the decl header, self-references are the decl. *)
let rec con_scheme ctx ?meta (h : Hash.t) : scheme =
  match Store.locate ctx.store h with
  | Ok
      {
        Store.decl = { Kernel.it = Kernel.DefType { tname; tvars; cons }; _ };
        decl_hash;
        role = Store.Constructor i;
      } ->
      let c = List.nth cons i in
      let inner = ctx.level + 1 in
      let vars = List.map (fun a -> (a, new_tvar inner)) tvars in
      let result = TCon (decl_hash, List.map snd vars) in
      let cenv = { mode = Flexible; tvs = vars; rvs = [] } in
      (* self-references — (tref tname) stayed Named — become the applied result type *)
      let conv_field (fl : Kernel.field) =
        conv_decl_ty ctx cenv ~self:(tname, result) fl.Kernel.fty
      in
      let fields = List.map conv_field c.Kernel.fields in
      let ty = match fields with [] -> result | fields -> TArrow (fields, empty_row, result) in
      { ty; gen_level = ctx.level }
  | Ok _ -> err ?meta ~code:"E0805" "hash %s is not a constructor" (Hash.to_hex h)
  | Error ds -> err ?meta ~code:"E0805" "%s" (String.concat "; " (List.map Diag.to_string ds))

(* Does a declaration type mention [name] as a (tref name)? Drives the self-in-argument
   case below without disturbing free-variable freshening elsewhere. *)
and ty_mentions name (t : Kernel.ty) : bool =
  match t.Kernel.it with
  | Kernel.TRef (Kernel.Named n) -> n = name
  | Kernel.TRef (Kernel.Hashed _) | Kernel.TVar _ -> false
  | Kernel.TApp (head, args) -> ty_mentions name head || List.exists (ty_mentions name) args
  | Kernel.TArrow (params, _, result) ->
      List.exists (ty_mentions name) params || ty_mentions name result
  | Kernel.TTuple items -> List.exists (ty_mentions name) items
  | Kernel.TForall (_, _, body) -> ty_mentions name body

(* Declaration-context conversion: like conv_ty but self-references map to [self]. Unbound
   type variables are an error here (E0811), not implicit quantification. *)
and conv_decl_ty ctx cenv ?(unbound_code = "E0811") ?(effectself = None) ~self (t : Kernel.ty) : ty
    =
  let self_name, self_ty = self in
  let meta = t.Kernel.meta in
  match t.Kernel.it with
  | Kernel.TRef (Kernel.Named n) when n = self_name -> self_ty
  | Kernel.TVar a -> (
      match List.assoc_opt a cenv.tvs with
      | Some v -> v
      | None ->
          err ~meta ~hint:"declare it in the parameter list of the enclosing declaration"
            ~code:unbound_code "unbound type variable `%s` in declaration" a)
  | Kernel.TApp ({ Kernel.it = Kernel.TRef (Kernel.Named n); _ }, args) when n = self_name -> (
      (* recursive application must match the declared parameters *)
      let args = List.map (conv_decl_ty ctx cenv ~unbound_code ~effectself ~self) args in
      match repr self_ty with
      | TCon (h, params) ->
          if List.length args <> List.length params then
            err ~meta ~code:"E0810" "recursive use of %s has wrong arity" self_name;
          List.iter2 (unify_or ctx ~meta ~what:"recursive type argument") params args;
          TCon (h, params)
      | _ -> self_ty)
  | Kernel.TApp ({ Kernel.it = Kernel.TRef (Kernel.Hashed h); _ }, args)
    when List.exists (ty_mentions self_name) args ->
      (* a non-self head whose ARGUMENTS contain the self-reference —
         (tapp (tref list) (tref test)) inside test's own declaration (W6.2). Guarded so
         self-free applications keep conv_ty's implicit freshening of free op vars. *)
      let arity = type_arity ctx ~meta h in
      if arity <> List.length args then
        err ~meta ~code:"E0810" "type %s expects %d argument(s), got %d" (name_of ctx h) arity
          (List.length args);
      TCon (h, List.map (conv_decl_ty ctx cenv ~unbound_code ~effectself ~self) args)
  | Kernel.TArrow (params, row, result) ->
      TArrow
        ( List.map (conv_decl_ty ctx cenv ~unbound_code ~effectself ~self) params,
          conv_row ctx cenv ~effectself row,
          conv_decl_ty ctx cenv ~unbound_code ~effectself ~self result )
  | Kernel.TTuple items ->
      TTuple (List.map (conv_decl_ty ctx cenv ~unbound_code ~effectself ~self) items)
  | _ -> conv_ty ctx cenv t

(* Operation scheme: forall effect-vars (+free op vars). (params) ->{E} result. The row
   carries just the effect hash (set semantics; effect type arguments do not row-match). *)
let op_scheme ctx ?meta (h : Hash.t) : scheme =
  match Store.locate ctx.store h with
  | Ok
      {
        Store.decl = { Kernel.it = Kernel.DefEffect { ename; evars; ops }; _ };
        decl_hash;
        role = Store.Operation i;
      } ->
      let o = List.nth ops i in
      let inner = ctx.level + 1 in
      let vars = List.map (fun a -> (a, new_tvar inner)) evars in
      let cenv = { mode = Flexible; tvs = vars; rvs = [] } in
      let self = (ename, TCon (decl_hash, List.map snd vars)) in
      let effectself = Some (ename, decl_hash) in
      let params = List.map (conv_decl_ty ctx cenv ~effectself ~self) o.Kernel.op_params in
      let result = conv_decl_ty ctx cenv ~effectself ~self o.Kernel.op_result in
      (* the row carries the EFFECT's hash: rows name capabilities, not operations *)
      { ty = TArrow (params, closed_row [ decl_hash ], result); gen_level = ctx.level }
  | Ok _ -> err ?meta ~code:"E0805" "hash %s is not an operation" (Hash.to_hex h)
  | Error ds -> err ?meta ~code:"E0805" "%s" (String.concat "; " (List.map Diag.to_string ds))

(** [operation_mode ctx h] returns the identity-bearing multiplicity declared for operation [h]. It
    reports E0805 if [h] does not locate an operation, so callers never silently treat malformed
    metadata as legacy [Multi]. *)
let operation_mode ctx ?meta (h : Hash.t) : Kernel.op_mode =
  match Store.locate ctx.store h with
  | Ok { Store.decl = { Kernel.it = Kernel.DefEffect { ops; _ }; _ }; role = Store.Operation i; _ }
    ->
      (List.nth ops i).Kernel.op_mode
  | Ok _ -> err ?meta ~code:"E0805" "hash %s is not an operation" (Hash.to_hex h)
  | Error ds -> err ?meta ~code:"E0805" "%s" (String.concat "; " (List.map Diag.to_string ds))

(** [is_frozen_async_spawn ctx operation] recognizes only the pinned SC.0 [async.spawn] member. In
    addition to the nominal HASH_V0 identities it checks the complete resolved declaration shape, so
    a name collision or a partially matching future interface never gains privileged typing. *)
let is_frozen_async_spawn ctx operation =
  let hash_is expected hash = String.equal expected (Hash.to_hex hash) in
  let tvar_is expected (ty : Kernel.ty) =
    match ty.it with Kernel.TVar actual -> String.equal expected actual | _ -> false
  in
  let unit_is (ty : Kernel.ty) = match ty.it with Kernel.TTuple [] -> true | _ -> false in
  let app_is expected_hash argument_is (ty : Kernel.ty) =
    match ty.it with
    | Kernel.TApp ({ it = Kernel.TRef (Kernel.Hashed hash); _ }, [ argument ]) ->
        hash_is expected_hash hash && argument_is argument
    | _ -> false
  in
  let task_is = app_is Concurrency_contract.task_type_hash (tvar_is "a") in
  let task_result_is = app_is Concurrency_contract.task_result_type_hash (tvar_is "a") in
  let self_row_is ename (row : Kernel.row) =
    match (row.effects, row.rvar) with
    | [ Kernel.Named name ], Some tail -> String.equal name ename && String.equal tail "e"
    | _ -> false
  in
  let spawn_is ename (op : Kernel.opspec) =
    String.equal op.op_name "async.spawn"
    && op.op_mode = Kernel.Once && task_is op.op_result
    &&
    match op.op_params with
    | [ { it = Kernel.TArrow ([], row, result); _ } ] -> self_row_is ename row && tvar_is "a" result
    | _ -> false
  in
  let await_is (op : Kernel.opspec) =
    String.equal op.op_name "async.await"
    && op.op_mode = Kernel.Once
    && List.length op.op_params = 1
    && task_is (List.hd op.op_params)
    && task_result_is op.op_result
  in
  let cancel_is (op : Kernel.opspec) =
    String.equal op.op_name "async.cancel"
    && op.op_mode = Kernel.Once
    && List.length op.op_params = 1
    && task_is (List.hd op.op_params)
    && unit_is op.op_result
  in
  let yield_is (op : Kernel.opspec) =
    String.equal op.op_name "async.yield"
    && op.op_mode = Kernel.Once && op.op_params = [] && unit_is op.op_result
  in
  match Store.locate ctx.store operation with
  | Ok
      {
        Store.decl = { Kernel.it = Kernel.DefEffect { ename; evars; ops }; _ };
        decl_hash;
        role = Store.Operation 0;
      } -> (
      hash_is Concurrency_contract.async_effect_hash decl_hash
      && hash_is (List.assoc "async.spawn" Concurrency_contract.async_operation_hashes) operation
      && String.equal ename "async" && evars = [ "a" ]
      &&
      match ops with
      | [ spawn; await; cancel; yield ] ->
          spawn_is ename spawn && await_is await && cancel_is cancel && yield_is yield
      | _ -> false)
  | Ok _ | Error _ -> false

(** [async_spawn_child_row ctx operation params] returns the solved child thunk row only when a
    direct call targets {!is_frozen_async_spawn}. This is the narrow SC.0 bridge; higher-order
    closure remains the SC.4 obligation. *)
let async_spawn_child_row ctx operation params =
  if is_frozen_async_spawn ctx operation then
    match params with [ TArrow ([], child_row, _) ] -> Some child_row | _ -> None
  else None

(** [contains_group_ref expression] reports whether [expression] can recur through its definition
    group. The affine-resumption checker uses it to reject transfers into helpers whose number of
    calls cannot be bounded syntactically. *)
let rec contains_group_ref (expression : Kernel.expr) =
  match expression.it with
  | Kernel.GroupRef _ -> true
  | Kernel.Lam (_, body) | Kernel.Unquote body | Kernel.Ann (body, _) -> contains_group_ref body
  | Kernel.App (fn, args) -> contains_group_ref fn || List.exists contains_group_ref args
  | Kernel.Let { value; body; _ } -> contains_group_ref value || contains_group_ref body
  | Kernel.Match (scrutinee, clauses) ->
      contains_group_ref scrutinee
      || List.exists (fun (clause : Kernel.clause) -> contains_group_ref clause.cbody) clauses
  | Kernel.Tuple items -> List.exists contains_group_ref items
  | Kernel.Handle { body; ret; ops } ->
      contains_group_ref body || contains_group_ref ret.rbody
      || List.exists (fun (clause : Kernel.opclause) -> contains_group_ref clause.obody) ops
  | Kernel.Lit _ | Kernel.Var _ | Kernel.Ref _ | Kernel.Quote _ -> false

(** [affine_callable ctx hash] exposes a stored lambda to the once-resumption checker. Only direct
    term lambdas are eligible; builtins and computed callable values remain escape boundaries. A
    recursive SCC is marked so transferring an affine token into an unbounded call cycle is rejected
    rather than guessed safe. *)
let affine_callable ctx hash =
  match Store.locate ctx.store hash with
  | Ok { Store.decl = { Kernel.it = Kernel.DefTerm bindings; _ }; role = Store.Member index; _ } ->
      let binding = List.nth bindings index in
      let rec lambda expression =
        match expression.Kernel.it with
        | Kernel.Lam (params, body) -> Some (params, body)
        | Kernel.Ann (subject, _) -> lambda subject
        | _ -> None
      in
      Option.map
        (fun (params, body) ->
          Affine_resume.
            {
              resolved_key = Hash.to_hex hash;
              resolved_source =
                Printf.sprintf "<stored:%s@%s>" (name_of ctx hash)
                  (String.sub (Hash.to_hex hash) 0 8);
              resolved_params = params;
              resolved_body = body;
              resolved_recursive = List.length bindings > 1 || contains_group_ref binding.value;
            })
        (lambda binding.value)
  | Ok _ | Error _ -> None

(* ------------------------------------------------------------------ *)
(* Generalization                                                      *)
(* ------------------------------------------------------------------ *)

let rec is_syntactic_value (e : Kernel.expr) : bool =
  match e.Kernel.it with
  | Kernel.Lit _ | Kernel.Lam _ | Kernel.Var _ | Kernel.Ref _ | Kernel.GroupRef _ | Kernel.Quote _
    ->
      true
  | Kernel.Tuple items -> List.for_all is_syntactic_value items
  | Kernel.App ({ Kernel.it = Kernel.Ref (_, Kernel.Con); _ }, args) ->
      List.for_all is_syntactic_value args
  | Kernel.Ann (inner, _) -> is_syntactic_value inner
  | _ -> false

(* Close generalizable row tails that occur exactly once in the type: an unconstrained
   single-use row var carries no sharing information, and closing it gives honest displays
   like (a) ->{} a and safe-div : (int, int) ->{abort} int. *)
let close_lonely_rows ~gen_level (t : ty) : unit =
  let counts : (int, int * rvar ref) Hashtbl.t = Hashtbl.create 8 in
  let rec walk t =
    match repr t with
    | TVar _ | TSkolem _ -> ()
    | TCon (_, args) -> List.iter walk args
    | TTuple items -> List.iter walk items
    | TArrow (params, row, result) ->
        List.iter walk params;
        (let row = repr_row row in
         match row.tail with
         | RVar ({ contents = RUnbound { id; level } } as r) when level > gen_level ->
             let n = match Hashtbl.find_opt counts id with Some (n, _) -> n | None -> 0 in
             Hashtbl.replace counts id (n + 1, r)
         | _ -> ());
        walk result
    | TResume (input, row, answer) ->
        walk input;
        (let row = repr_row row in
         match row.tail with
         | RVar ({ contents = RUnbound { id; level } } as rv) when level > gen_level -> (
             match Hashtbl.find_opt counts id with
             | None -> Hashtbl.add counts id (1, rv)
             | Some (n, _) -> Hashtbl.replace counts id (n + 1, rv))
         | _ -> ());
        walk answer
    | TVariadicArrow (param, row, result) ->
        walk param;
        (let row = repr_row row in
         match row.tail with
         | RVar ({ contents = RUnbound { id; level } } as r) when level > gen_level ->
             let n = match Hashtbl.find_opt counts id with Some (n, _) -> n | None -> 0 in
             Hashtbl.replace counts id (n + 1, r)
         | _ -> ());
        walk result
  in
  walk t;
  Hashtbl.iter (fun _ (n, r) -> if n = 1 then r := RLink { effects = []; tail = RClosed }) counts

(* ------------------------------------------------------------------ *)
(* Patterns                                                            *)
(* ------------------------------------------------------------------ *)

let concat_map2 f xs ys = List.concat (List.map2 f xs ys)

let rec infer_pat ctx (p : Kernel.pat) : ty * (string * ty) list =
  let meta = p.Kernel.meta in
  match p.Kernel.it with
  | _ when Option.is_some (Meta.surface_hole meta) -> (new_tvar ctx.level, [])
  | Kernel.PWild -> (new_tvar ctx.level, [])
  | Kernel.PVar x ->
      let t = new_tvar ctx.level in
      (t, [ (x, t) ])
  | Kernel.PLit (Kernel.LInt _) -> (prim ctx.p_int, [])
  | Kernel.PLit (Kernel.LReal _) -> (prim ctx.p_real, [])
  | Kernel.PLit (Kernel.LText _) -> (prim ctx.p_text, [])
  | Kernel.PCon (Kernel.Hashed h, ps) -> (
      let s = con_scheme ctx ~meta h in
      let con_ty = instantiate ~level:ctx.level s in
      match (repr con_ty, ps) with
      | TArrow (fields, _, result), ps ->
          if List.length fields <> List.length ps then
            err ~meta ~hint:"constructor patterns bind every declared field" ~code:"E0806"
              "constructor %s expects %d argument(s) in this pattern, got %d" (name_of ctx h)
              (List.length fields) (List.length ps);
          let bindings =
            concat_map2
              (fun field p ->
                let pt, bs = infer_pat ctx p in
                unify_or ctx ~meta ~what:"constructor pattern argument" field pt;
                bs)
              fields ps
          in
          (result, bindings)
      | result, [] -> (result, [])
      | result, _ :: _ ->
          ignore result;
          err ~meta ~code:"E0806" "constructor %s takes no arguments in this pattern"
            (name_of ctx h))
  | Kernel.PCon (Kernel.Named n, _) -> err ~meta ~code:"E0811" "unresolved constructor `%s`" n
  | Kernel.PTuple ps ->
      let tys_bs = List.map (infer_pat ctx) ps in
      (TTuple (List.map fst tys_bs), List.concat_map snd tys_bs)
  | Kernel.PAs (x, inner) ->
      let t, bs = infer_pat ctx inner in
      (t, (x, t) :: bs)

(* ------------------------------------------------------------------ *)
(* Expression inference                                                *)
(* ------------------------------------------------------------------ *)

let bind_all bindings env =
  { env with vars = List.fold_left (fun m (x, t) -> SMap.add x (mono t) m) env.vars bindings }

let rec term_scheme ctx ?meta (h : Hash.t) : scheme =
  match Hashtbl.find_opt ctx.builtin_sigs h with
  | Some s -> s
  | None -> (
      match Hashtbl.find_opt ctx.term_sigs h with
      | Some s -> s
      | None -> (
          match Store.locate ctx.store h with
          | Ok { Store.decl = { Kernel.it = Kernel.DefTerm _; _ } as decl; decl_hash; _ } ->
              if List.exists (Hash.equal decl_hash) ctx.checking then
                err ?meta ~code:"E0805" "cyclic dependency between declarations reached the checker"
              else begin
                check_group ctx decl;
                match Hashtbl.find_opt ctx.term_sigs h with
                | Some s -> s
                | None -> err ?meta ~code:"E0805" "term %s did not check" (Hash.to_hex h)
              end
          | Ok _ -> err ?meta ~code:"E0805" "hash %s is not a term" (Hash.to_hex h)
          | Error ds ->
              err ?meta ~code:"E0805" "%s" (String.concat "; " (List.map Diag.to_string ds))))

and infer ?(immediate_transformer = false) ctx env ~(ambient : row) (e : Kernel.expr) : ty =
  let meta = e.Kernel.meta in
  match e.Kernel.it with
  | _ when Option.is_some (Meta.surface_hole meta) -> new_tvar ctx.level
  | Kernel.Lit (Kernel.LInt _) -> prim ctx.p_int
  | Kernel.Lit (Kernel.LReal _) -> prim ctx.p_real
  | Kernel.Lit (Kernel.LText _) -> prim ctx.p_text
  | Kernel.Var x -> (
      match SMap.find_opt x env.vars with
      | Some s -> instantiate ~level:ctx.level s
      | None -> err ~meta ~code:"E0811" "unbound variable `%s` reached the checker" x)
  | Kernel.GroupRef i ->
      if i >= 0 && i < Array.length env.group then snd env.group.(i)
      else err ~meta ~code:"E0805" "groupref %d outside its group" i
  | Kernel.Ref (h, Kernel.Term) -> instantiate ~level:ctx.level (term_scheme ctx ~meta h)
  | Kernel.Ref (h, Kernel.Con) -> instantiate ~level:ctx.level (con_scheme ctx ~meta h)
  | Kernel.Ref (h, Kernel.Op) -> instantiate ~level:ctx.level (op_scheme ctx ~meta h)
  | Kernel.Lam (params, body) ->
      let params_tys_bs = List.map (infer_pat ctx) params in
      let param_tys = List.map fst params_tys_bs in
      let env' = bind_all (List.concat_map snd params_tys_bs) env in
      let lam_ambient = { effects = []; tail = new_rvar ctx.level } in
      let body_ty = infer ctx env' ~ambient:lam_ambient body in
      TArrow (param_tys, lam_ambient, body_ty)
  | Kernel.App (fn, args) -> (
      let fn_ty =
        match fn.it with
        | Kernel.Handle _ when List.for_all Affine_resume.is_immediate_transformer_argument args ->
            (* This context is decided before inference and is not propagated through aliases or
               wrappers: only the literal function child of this one application receives it. *)
            infer ~immediate_transformer:true ctx env ~ambient fn
        | _ -> infer ctx env ~ambient fn
      in
      let arg_tys = List.map (infer ctx env ~ambient) args in
      match repr fn_ty with
      | TArrow (params, frow, result) ->
          if List.length params <> List.length args then
            err ~meta ~hint:"Jacquard calls are uncurried: pass exactly the declared arguments"
              ~code:"E0803" "this function expects %d argument(s), got %d" (List.length params)
              (List.length args);
          (let kind =
             match fn.Kernel.it with
             | Kernel.Ref (_, Kernel.Con) -> Tier.KCon
             | Kernel.Ref (_, Kernel.Op) -> Tier.KOp
             | _ -> Tier.KFn
           in
           ctx.tier_apps <- (frow, kind) :: ctx.tier_apps);
          List.iteri
            (fun index ((arg : Kernel.expr), (expected, actual)) ->
              let what =
                if surface_form_is meta [ "list"; "list-tail" ] then "list elements"
                else if surface_form_is meta [ "pipe" ] && index = 0 then "pipe input"
                else "argument"
              in
              let diagnostic_meta =
                if surface_form_is meta [ "call"; "list"; "list-tail"; "pipe" ] then arg.meta
                else meta
              in
              let eta =
                Meta.is_surface_reference arg.meta
                && (match arg.it with Kernel.Ref (_, Kernel.Term) -> true | _ -> false)
                && eta_expansion_candidate ctx expected actual
              in
              try Types.unify expected actual
              with Unify_error detail ->
                if eta then
                  err ~meta:arg.meta ~code:"E0807"
                    ~hint:"wrap the reference in `fn () -> ...` so the computation is delayed"
                    "this position expects a thunk, but `%s` is a bare reference; wrap it in `fn \
                     () -> ...`"
                    (Option.value ~default:"this value" (Meta.name arg.meta))
                else
                  err ~meta:diagnostic_meta
                    ~hint:
                      "the expected side comes from the surrounding context; make both sides agree"
                    ~code:"E0801" "%s: expected %s, got %s (%s)" what (show_ty ctx expected)
                    (show_ty ctx actual) detail)
            (List.combine args (List.combine params arg_tys));
          (match fn.Kernel.it with
          | Kernel.Ref (operation, Kernel.Op) -> (
              match async_spawn_child_row ctx operation params with
              | Some child_row -> (
                  try Types.unify_rows (opened ctx child_row) ambient
                  with Unify_error detail ->
                    err ~meta ~code:"E0801"
                      "spawned child effect row does not fit the parent computation (%s)" detail)
              | None -> ())
          | _ -> ());
          (* record who introduced each effect, for the manifest diagnostic (W3.6) *)
          (let callee =
             match fn.Kernel.it with
             | Kernel.Ref _ | Kernel.GroupRef _ -> Meta.name fn.Kernel.meta
             | _ -> None
           in
           match callee with
           | Some name ->
               List.iter
                 (fun h ->
                   if not (List.mem_assoc h ctx.origins) then
                     ctx.origins <- (h, name) :: ctx.origins)
                 (repr_row frow).effects
           | None -> ());
          (try Types.unify_rows (opened ctx frow) ambient
           with Unify_error detail ->
             err ~meta ~code:"E0801" "effect row mismatch at this application (%s)" detail);
          result
      | TResume (param, frow, result) ->
          if List.length args <> 1 then
            err ~meta ~hint:"a resumption accepts exactly the operation's result value"
              ~code:"E0803" "this resumption expects 1 argument, got %d" (List.length args);
          ctx.tier_apps <- (frow, Tier.KFn) :: ctx.tier_apps;
          let arg = List.hd args and actual = List.hd arg_tys in
          unify_or ctx ~meta:arg.meta ~what:"resumption argument" param actual;
          (try Types.unify_rows (opened ctx frow) ambient
           with Unify_error detail ->
             err ~meta ~code:"E0801" "effect row mismatch at this resumption (%s)" detail);
          result
      | TVariadicArrow (param, frow, result) ->
          ctx.tier_apps <- (frow, Tier.KFn) :: ctx.tier_apps;
          List.iter
            (fun ((arg : Kernel.expr), actual) ->
              unify_or ctx ~meta:arg.meta ~what:"variadic argument" param actual)
            (List.combine args arg_tys);
          (try Types.unify_rows (opened ctx frow) ambient
           with Unify_error detail ->
             err ~meta ~code:"E0801" "effect row mismatch at this application (%s)" detail);
          result
      | TVar _ ->
          let result = new_tvar ctx.level in
          unify_or ctx ~meta ~what:"function position" fn_ty (TArrow (arg_tys, ambient, result));
          (* unknown callee: the call runs with ambient effects; record what ambient resolves to *)
          ctx.tier_apps <- (ambient, Tier.KFn) :: ctx.tier_apps;
          result
      | t ->
          if surface_form_is meta [ "pipe" ] then
            let rhs_meta = Meta.surface_container "pipe-rhs" meta in
            err ~meta:rhs_meta ~hint:"the right-hand side of `|>` must be callable" ~code:"E0802"
              "the `|>` right-hand side has type %s, which is not a function" (show_ty ctx t)
          else
            err ~meta ~hint:"only functions, constructors, effect operations, and resumptions apply"
              ~code:"E0802" "%s is not a function" (show_ty ctx t))
  | Kernel.Let { isrec = false; binder; value; body } -> (
      match binder.Kernel.it with
      | Kernel.PVar x when is_syntactic_value value ->
          (* generalize: infer the value one level in, then quantify what stayed there. The
             binding is attached directly (no unification with an outer-level variable,
             which would demote the levels and kill generalization). *)
          ctx.level <- ctx.level + 1;
          let vty = infer ctx env ~ambient value in
          ctx.level <- ctx.level - 1;
          close_lonely_rows ~gen_level:ctx.level vty;
          let env' = { env with vars = SMap.add x { ty = vty; gen_level = ctx.level } env.vars } in
          infer ctx env' ~ambient body
      | _ ->
          (* monomorphic: destructuring binders and non-value bindings *)
          let vty = infer ctx env ~ambient value in
          let pat_ty, bindings = infer_pat ctx binder in
          unify_or ctx ~meta ~what:"let binder" pat_ty vty;
          infer ctx (bind_all bindings env) ~ambient body)
  | Kernel.Let { isrec = true; binder; value; body } -> (
      match binder.Kernel.it with
      | Kernel.PVar x ->
          ctx.level <- ctx.level + 1;
          let fty = new_tvar ctx.level in
          let env_rec = bind_all [ (x, fty) ] env in
          let vty = infer ctx env_rec ~ambient value in
          unify_or ctx ~meta ~what:"recursive binding" fty vty;
          ctx.level <- ctx.level - 1;
          close_lonely_rows ~gen_level:ctx.level fty;
          let env' = { env with vars = SMap.add x { ty = fty; gen_level = ctx.level } env.vars } in
          infer ctx env' ~ambient body
      | _ -> err ~meta ~code:"E0805" "malformed let rec survived validation")
  | Kernel.Match (scrutinee, clauses) ->
      let sty = infer ctx env ~ambient scrutinee in
      let result = new_tvar ctx.level in
      let surface_if = surface_form_is meta [ "if" ] in
      List.iteri
        (fun index { Kernel.cpat; cbody; cmeta } ->
          let pty, bindings = infer_pat ctx cpat in
          unify_or ctx
            ~meta:(if surface_if then scrutinee.meta else cmeta)
            ~what:(if surface_if then "if condition" else "match pattern")
            sty pty;
          let bty = infer ctx (bind_all bindings env) ~ambient cbody in
          let what =
            if surface_if then if index = 0 then "if `then` branch" else "if `else` branch"
            else "match clause result"
          in
          unify_or ctx ~meta:(if surface_if then cbody.meta else cmeta) ~what result bty)
        clauses;
      ctx.sites <-
        { scrutinee_ty = sty; arms = clauses; site_meta = scrutinee.Kernel.meta } :: ctx.sites;
      result
  | Kernel.Tuple items -> TTuple (List.map (infer ctx env ~ambient) items)
  | Kernel.Handle { body; ret = { rbinder; rbody; rmeta }; ops } ->
      (* body ambient = handled effects joined onto the outer ambient *)
      let handled =
        List.filter_map
          (fun (oc : Kernel.opclause) ->
            match oc.Kernel.op with
            | Kernel.Hashed h -> (
                match Store.locate ctx.store h with
                | Ok { Store.decl_hash; role = Store.Operation _; _ } -> Some decl_hash
                | _ -> err ~meta:oc.Kernel.ometa ~code:"E0805" "op clause is not an operation")
            | Kernel.Named n -> err ~meta:oc.Kernel.ometa ~code:"E0811" "unresolved op `%s`" n)
          ops
      in
      let outer = repr_row ambient in
      let body_ambient =
        { effects = List.sort_uniq Hash.compare (handled @ outer.effects); tail = outer.tail }
      in
      let body_ty = infer ctx env ~ambient:body_ambient body in
      let answer = new_tvar ctx.level in
      (* return clause: binder gets the body's type; result is the answer type *)
      let rpt, rbindings = infer_pat ctx rbinder in
      unify_or ctx ~meta:rmeta ~what:"return clause binder" body_ty rpt;
      let rty = infer ctx (bind_all rbindings env) ~ambient rbody in
      unify_or ctx ~meta:rmeta ~what:"return clause result" answer rty;
      (* op clauses *)
      List.iter
        (fun (oc : Kernel.opclause) ->
          let oh = match oc.Kernel.op with Kernel.Hashed h -> h | _ -> assert false in
          let os = instantiate ~level:ctx.level (op_scheme ctx ~meta:oc.Kernel.ometa oh) in
          let op_params, op_result =
            match repr os with TArrow (ps, _, r) -> (ps, r) | t -> ([], t)
            (* nullary op values do not occur: ops always have arrow types *)
          in
          if List.length op_params <> List.length oc.Kernel.params then
            err ~meta:oc.Kernel.ometa ~code:"E0803"
              "op clause for %s expects %d parameter(s), got %d" (name_of ctx oh)
              (List.length op_params) (List.length oc.Kernel.params);
          let bindings =
            concat_map2
              (fun opt p ->
                let pt, bs = infer_pat ctx p in
                unify_or ctx ~meta:oc.Kernel.ometa ~what:"op clause parameter" opt pt;
                bs)
              op_params oc.Kernel.params
          in
          (* Multi resumptions remain ordinary functions. Once resumptions are callable but affine;
             their local usage pass runs first so escape errors are reported at the capture site. *)
          let mode = operation_mode ctx ~meta:oc.Kernel.ometa oh in
          let resume_ty =
            match mode with
            | Kernel.Multi -> TArrow ([ op_result ], ambient, answer)
            | Kernel.Once -> TResume (op_result, ambient, answer)
          in
          let env' = bind_all ((oc.Kernel.resume, resume_ty) :: bindings) env in
          let affine_context =
            if immediate_transformer then Affine_resume.Immediately_applied_transformer
            else Affine_resume.Ordinary
          in
          ctx.tier_ops <-
            (oh, Tier.discipline ~resume:oc.Kernel.resume oc.Kernel.obody) :: ctx.tier_ops;
          (match mode with
          | Kernel.Multi -> ()
          | Kernel.Once -> (
              (* Escape checking runs before inference so laundering a Resume retains E0817.
                 In the immediate-transformer context it also proves each Resume-produced answer
                 is the direct function child of one application, preventing a later Once token
                 carried by that answer from being bound or duplicated.
                 Duplicate-consumption checking waits until after inference and answer-type
                 unification, ensuring malformed calls retain their ordinary E0801/E0803 error. *)
              match
                Affine_resume.check_escapes ~resolve_term:(affine_callable ctx)
                  ~context:affine_context ~resume:oc.Kernel.resume oc.Kernel.obody
              with
              | Ok () -> ()
              | Error (diagnostic :: _) -> raise (Err diagnostic)
              | Error [] -> assert false));
          let cty = infer ctx env' ~ambient oc.Kernel.obody in
          unify_or ctx ~meta:oc.Kernel.ometa ~what:"op clause result" answer cty;
          match mode with
          | Kernel.Multi -> ()
          | Kernel.Once -> (
              match
                Affine_resume.check_clause ~resolve_term:(affine_callable ctx)
                  ~context:affine_context ~resume:oc.Kernel.resume oc.Kernel.obody
              with
              | Ok () -> ()
              | Error (diagnostic :: _) -> raise (Err diagnostic)
              | Error [] -> assert false))
        ops;
      answer
  | Kernel.Quote payload ->
      (* the payload is data; live splices evaluate at quote time, so they must produce
         code and their effects flow into the ambient row *)
      let rec splices ?(level = 0) (f : Form.t) =
        if f.Form.head = "unquote" && level = 0 then
          match f.Form.args with
          | [ Form.F sp ] -> (
              match Kernel.expr_of_form sp with
              | Ok se ->
                  let st = infer ctx env ~ambient se in
                  unify_or ctx ~meta:f.Form.meta ~what:"unquote splice" (prim ctx.p_code) st
              | Error ds -> raise (Err (List.hd ds)))
          | _ -> err ~meta:f.Form.meta ~code:"E0805" "malformed unquote"
        else
          let level =
            match f.Form.head with "quote" -> level + 1 | "unquote" -> level - 1 | _ -> level
          in
          List.iter (function Form.F g -> splices ~level g | _ -> ()) f.Form.args
      in
      splices payload;
      prim ctx.p_code
  | Kernel.Unquote _ -> err ~meta ~code:"E0805" "unquote outside quote reached the checker"
  | Kernel.Ann (subject, ann) ->
      let cenv = { mode = Rigid; tvs = []; rvs = [] } in
      let expected = conv_ty ctx cenv ann in
      let actual = infer ctx env ~ambient subject in
      (try Types.unify expected actual
       with Unify_error detail ->
         err ~meta ~hint:"the annotation is the contract: change the body or the annotation"
           ~code:"E0804" "annotation mismatch: expected %s, got %s (%s)" (show_ty ctx expected)
           (show_ty ctx actual) detail);
      expected

(* ------------------------------------------------------------------ *)
(* Declarations (W3.3)                                                 *)
(* ------------------------------------------------------------------ *)

(* Kind/arity discipline for deftype and defeffect: parameters are distinct, every type
   reference is applied at its declared arity, every variable is bound. *)
and check_type_decl ctx (d : Kernel.decl) : unit =
  let meta = d.Kernel.meta in
  match d.Kernel.it with
  | Kernel.DefType { tname; tvars; cons } ->
      let dup = List.find_opt (fun v -> List.length (List.filter (( = ) v) tvars) > 1) tvars in
      (match dup with
      | Some v -> err ~meta ~code:"E0810" "duplicate type parameter `%s` in %s" v tname
      | None -> ());
      let inner = ctx.level + 1 in
      let vars = List.map (fun a -> (a, new_tvar inner)) tvars in
      let cenv = { mode = Flexible; tvs = vars; rvs = [] } in
      let self = (tname, TCon (Hash.of_string "self-placeholder", List.map snd vars)) in
      List.iter
        (fun (c : Kernel.conspec) ->
          List.iter
            (fun (fl : Kernel.field) -> ignore (conv_decl_ty ctx cenv ~self fl.Kernel.fty))
            c.Kernel.fields)
        cons
  | Kernel.DefEffect { ename; evars; ops } ->
      let dup = List.find_opt (fun v -> List.length (List.filter (( = ) v) evars) > 1) evars in
      (match dup with
      | Some v -> err ~meta ~code:"E0810" "duplicate effect parameter `%s` in %s" v ename
      | None -> ());
      let inner = ctx.level + 1 in
      let vars = List.map (fun a -> (a, new_tvar inner)) evars in
      let placeholder = Hash.of_string "self-placeholder" in
      let self = (ename, TCon (placeholder, List.map snd vars)) in
      let effectself = Some (ename, placeholder) in
      List.iter
        (fun (o : Kernel.opspec) ->
          let cenv = { mode = Flexible; tvs = vars; rvs = [] } in
          List.iter
            (fun p -> ignore (conv_decl_ty ctx cenv ~unbound_code:"E0812" ~effectself ~self p))
            o.Kernel.op_params;
          ignore (conv_decl_ty ctx cenv ~unbound_code:"E0812" ~effectself ~self o.Kernel.op_result))
        ops
  | Kernel.DefTerm _ -> ()

(* Check a defterm group mutually: annotated members are visible at their annotation
   (flexible conversion) and their bodies are checked against the rigid version; unannotated
   members are mono during the pass and generalized after. Fills [ctx.term_sigs]. *)
and check_group ?recovery_group ctx (decl : Kernel.decl) : unit =
  match decl.Kernel.it with
  | Kernel.DefTerm bindings ->
      let hashes =
        match recovery_group with
        | Some hashes -> hashes
        | None -> (
            match Canon.hash_decl decl with
            | Ok { Canon.decl_hash; named } -> (decl_hash, List.map snd named)
            | Error ds -> err ~code:"E0805" "%s" (String.concat "; " (List.map Diag.to_string ds)))
      in
      let decl_hash, member_hashes = hashes in
      ctx.checking <- decl_hash :: ctx.checking;
      let saved_level = ctx.level in
      Fun.protect
        ~finally:(fun () ->
          ctx.checking <- List.tl ctx.checking;
          ctx.level <- saved_level)
        (fun () ->
          ctx.level <- ctx.level + 1;
          let member_tys =
            List.map
              (fun (b : Kernel.binding) ->
                match b.Kernel.annot with
                | Some ann ->
                    let cenv = { mode = Flexible; tvs = []; rvs = [] } in
                    (b.Kernel.bname, conv_ty ctx cenv ann)
                | None -> (b.Kernel.bname, new_tvar ctx.level))
              bindings
          in
          let group = Array.of_list member_tys in
          let env = { empty_env with group } in
          List.iteri
            (fun i (b : Kernel.binding) ->
              let ambient = { effects = []; tail = new_rvar ctx.level } in
              let vty = infer ctx env ~ambient b.Kernel.value in
              (* the binding BODY itself must be effect-free (its value's effects live on
                 arrows): a non-lambda effectful body would otherwise type as pure and give
                 `check --manifest` a false pass (review finding) *)
              (match (repr_row ambient).effects with
              | [] -> ()
              | h :: _ ->
                  err ~meta:b.Kernel.bmeta ~code:"E0815"
                    ~hint:"wrap the body in a lambda and perform the effect when called"
                    "top-level definition `%s` performs the `%s` effect while being defined"
                    b.Kernel.bname (name_of ctx h));
              match b.Kernel.annot with
              | Some ann -> (
                  (* the body must check against the RIGID annotation *)
                  let cenv = { mode = Rigid; tvs = []; rvs = [] } in
                  let rigid = conv_ty ctx cenv ann in
                  try Types.unify rigid vty
                  with Unify_error detail ->
                    if surface_form_is b.Kernel.bmeta [ "equation-definition" ] then
                      err ~meta:b.Kernel.value.meta ~code:"E0804"
                        "equation definition `%s` does not match its signature: expected %s, got \
                         %s (%s)"
                        b.Kernel.bname (show_ty ctx rigid) (show_ty ctx vty) detail
                    else
                      err ~meta:b.Kernel.bmeta ~code:"E0804"
                        "binding %s does not match its annotation: expected %s, got %s (%s)"
                        b.Kernel.bname (show_ty ctx rigid) (show_ty ctx vty) detail)
              | None ->
                  unify_or ctx ~meta:b.Kernel.bmeta
                    ~what:
                      (if surface_form_is b.Kernel.bmeta [ "equation-definition" ] then
                         "equation definition"
                       else "group member")
                    (snd group.(i))
                    vty)
            bindings;
          ctx.level <- ctx.level - 1;
          List.iteri
            (fun i (_, t) ->
              close_lonely_rows ~gen_level:ctx.level t;
              Hashtbl.replace ctx.term_sigs (List.nth member_hashes i)
                { ty = t; gen_level = ctx.level })
            member_tys)
  | _ -> ()

(* ------------------------------------------------------------------ *)
(* Exhaustiveness and redundancy (W3.5): Maranget's usefulness         *)
(* ------------------------------------------------------------------ *)

(** A missing-pattern witness, rendered for the non-exhaustiveness diagnostic. *)
type witness = WWild | WLit of Kernel.lit | WCon of string * witness list | WTuple of witness list
[@@warning "-37"]

let rec show_witness = function
  | WWild -> "_"
  | WLit (Kernel.LInt i) -> string_of_int i
  | WLit (Kernel.LReal r) -> Printer.real_repr r
  | WLit (Kernel.LText s) -> "\"" ^ Printer.escape_text s ^ "\""
  | WCon (name, []) -> name
  | WCon (name, args) -> name ^ "(" ^ String.concat ", " (List.map show_witness args) ^ ")"
  | WTuple items -> "(" ^ String.concat ", " (List.map show_witness items) ^ ")"

(* Strip as-patterns: they do not affect matching shape. *)
let rec strip (p : Kernel.pat) : Kernel.pat =
  match p.Kernel.it with Kernel.PAs (_, inner) -> strip inner | _ -> p

let is_wild p = match (strip p).Kernel.it with Kernel.PWild | Kernel.PVar _ -> true | _ -> false
let wild_pat = { Kernel.it = Kernel.PWild; meta = Meta.empty }

(* Constructors of a declared type, with field types instantiated at the given arguments:
   (con hash, name, field types). *)
let constructors_of ctx ?meta (h : Hash.t) (args : ty list) :
    (Hash.t * string * ty list) list option =
  if
    (* the primitive marker types are opaque: their token constructors exist only to give
       the declarations distinct identities and must not drive exhaustiveness *)
    List.exists (Hash.equal h) [ ctx.p_int; ctx.p_real; ctx.p_text; ctx.p_code ]
  then None
  else
    match Store.locate ctx.store h with
    | Ok { Store.decl = { Kernel.it = Kernel.DefType { tname; tvars; cons }; _ }; decl_hash; _ }
      when List.length tvars = List.length args ->
        let cenv = { mode = Flexible; tvs = List.combine tvars args; rvs = [] } in
        let self = (tname, TCon (decl_hash, args)) in
        Some
          (List.mapi
             (fun i (c : Kernel.conspec) ->
               ( Canon.con_hash decl_hash i,
                 c.Kernel.con_name,
                 List.map
                   (fun (fl : Kernel.field) -> conv_decl_ty ctx cenv ~self fl.Kernel.fty)
                   c.Kernel.fields ))
             cons)
    | _ ->
        ignore meta;
        None

(* [useful ctx tys matrix] = witness for a value vector matched by NO row, or None if the
   rows cover everything (Maranget, JFP 2007, specialized to wildcard queries). *)
let rec useful ctx (tys : ty list) (matrix : Kernel.pat list list) : witness list option =
  if matrix = [] then
    (* nothing covers anything: witnessed immediately (also the recursion base that keeps
       recursive types like list from diverging) *)
    Some (List.map (fun _ -> WWild) tys)
  else
    match tys with
    | [] -> None
    | t0 :: trest -> (
        let t0 = repr t0 in
        let col0 = List.map (fun row -> strip (List.hd row)) matrix in
        let default_matrix () =
          List.filter_map
            (fun row -> if is_wild (List.hd row) then Some (List.tl row) else None)
            matrix
        in
        let specialize_con con arity =
          List.filter_map
            (fun row ->
              let p0 = strip (List.hd row) in
              match p0.Kernel.it with
              | Kernel.PCon (Kernel.Hashed h, ps) when Hash.equal h con -> Some (ps @ List.tl row)
              | Kernel.PWild | Kernel.PVar _ ->
                  Some (List.init arity (fun _ -> wild_pat) @ List.tl row)
              | _ -> None)
            matrix
        in
        match t0 with
        | TCon (h, args) -> (
            match constructors_of ctx h args with
            | Some cons -> (
                (* Maranget's signature split: only constructors PRESENT in the column force
                 per-constructor specialization; if the signature is incomplete, the default
                 matrix decides and any missing constructor is the witness head. Without
                 this split, all-wildcard columns over recursive types diverge. *)
                let present ch =
                  List.exists
                    (fun p ->
                      match p.Kernel.it with
                      | Kernel.PCon (Kernel.Hashed h', _) -> Hash.equal h' ch
                      | _ -> false)
                    col0
                in
                let missing = List.filter (fun (ch, _, _) -> not (present ch)) cons in
                if missing = [] then
                  (* complete signature: try each constructor *)
                  let rec try_cons = function
                    | [] -> None
                    | (ch, cname, fields) :: rest -> (
                        match
                          useful ctx (fields @ trest) (specialize_con ch (List.length fields))
                        with
                        | Some ws ->
                            let n = List.length fields in
                            let wargs = List.filteri (fun i _ -> i < n) ws in
                            let wrest = List.filteri (fun i _ -> i >= n) ws in
                            Some (WCon (cname, wargs) :: wrest)
                        | None -> try_cons rest)
                  in
                  try_cons cons
                else
                  match useful ctx trest (default_matrix ()) with
                  | Some ws ->
                      let _, cname, fields = List.hd missing in
                      Some (WCon (cname, List.map (fun _ -> WWild) fields) :: ws)
                  | None -> None)
            | None ->
                (* not a declared type at all: only wildcards can cover *)
                Option.map (fun ws -> WWild :: ws) (useful ctx trest (default_matrix ())))
        | TTuple items ->
            let arity = List.length items in
            let spec =
              List.filter_map
                (fun row ->
                  let p0 = strip (List.hd row) in
                  match p0.Kernel.it with
                  | Kernel.PTuple ps when List.length ps = arity -> Some (ps @ List.tl row)
                  | Kernel.PWild | Kernel.PVar _ ->
                      Some (List.init arity (fun _ -> wild_pat) @ List.tl row)
                  | _ -> None)
                matrix
            in
            Option.map
              (fun ws ->
                let wargs = List.filteri (fun i _ -> i < arity) ws in
                let wrest = List.filteri (fun i _ -> i >= arity) ws in
                WTuple wargs :: wrest)
              (useful ctx (items @ trest) spec)
        | _ ->
            (* variables, arrows, skolems: nothing structural can head them *)
            Option.map (fun ws -> WWild :: ws) (useful ctx trest (default_matrix ())))

(** Run the exhaustiveness/redundancy pass over the sites collected during inference. Non-exhaustive
    matches are errors (E0813) with a missing-pattern witness; redundant clauses are warnings
    (W0801), returned rather than raised. *)
let rec check_matches ctx : Diag.t list =
  let warnings = ref [] in
  List.iter
    (fun { scrutinee_ty; arms; site_meta } ->
      let matrix = List.map (fun (c : Kernel.clause) -> [ c.Kernel.cpat ]) arms in
      (match useful ctx [ scrutinee_ty ] matrix with
      | Some [ w ] ->
          err ~meta:site_meta ~hint:"add a clause matching the witness, or a (pwild) default"
            ~code:"E0813" "this match is not exhaustive: it misses %s" (show_witness w)
      | Some _ ->
          err ~meta:site_meta ~hint:"add a (pwild) default clause" ~code:"E0813"
            "this match is not exhaustive"
      | None -> ());
      (* redundancy: clause i is useless if rows 0..i-1 already cover its pattern *)
      List.iteri
        (fun i (c : Kernel.clause) ->
          if i > 0 then
            let prior = List.filteri (fun j _ -> j < i) matrix in
            (* clause i is useful iff adding it changes coverage: test usefulness of its
               pattern against the prior rows via instance check *)
            let covers =
              (* [prior] covers clause i's pattern if specializing prior by that pattern's
                 shape leaves nothing missing; approximate with the standard trick: the
                 clause is redundant iff its row is not useful, i.e. every value it matches
                 is matched by prior rows. Test: useful(prior + [row_i]) where we ask
                 whether row_i adds coverage — equivalently, is there a value matching
                 row_i but no prior row? Build a matrix of prior rows and query with
                 row_i's pattern as the type-driven query; approximated by checking
                 usefulness of row_i against prior. *)
              useful_row ctx [ scrutinee_ty ] prior [ c.Kernel.cpat ] = None
            in
            if covers then
              warnings :=
                Diag.warning ?span:(Meta.span c.Kernel.cmeta) ~code:"W0801"
                  "this clause is redundant: earlier clauses match everything it does"
                :: !warnings)
        arms)
    (List.rev ctx.sites);
  List.rev !warnings

(* Usefulness of a specific row [q] against [matrix] (Maranget's U(P, q)): None = not
   useful (redundant), Some () = useful. *)
and useful_row ctx (tys : ty list) (matrix : Kernel.pat list list) (q : Kernel.pat list) :
    unit option =
  match (tys, q) with
  | [], [] -> if matrix = [] then Some () else None
  | t0 :: trest, q0 :: qrest -> (
      let t0 = repr t0 in
      let q0s = strip q0 in
      let specialize_con con arity =
        List.filter_map
          (fun row ->
            let p0 = strip (List.hd row) in
            match p0.Kernel.it with
            | Kernel.PCon (Kernel.Hashed h, ps) when Hash.equal h con -> Some (ps @ List.tl row)
            | Kernel.PWild | Kernel.PVar _ ->
                Some (List.init arity (fun _ -> wild_pat) @ List.tl row)
            | _ -> None)
          matrix
      in
      match q0s.Kernel.it with
      | Kernel.PCon (Kernel.Hashed h, ps) ->
          useful_row ctx
            ((match t0 with
               | TCon (th, targs) -> (
                   match constructors_of ctx th targs with
                   | Some cons -> (
                       match List.find_opt (fun (ch, _, _) -> Hash.equal ch h) cons with
                       | Some (_, _, fields) -> fields
                       | None -> List.map (fun _ -> new_tvar ctx.level) ps)
                   | None -> List.map (fun _ -> new_tvar ctx.level) ps)
               | _ -> List.map (fun _ -> new_tvar ctx.level) ps)
            @ trest)
            (specialize_con h (List.length ps))
            (ps @ qrest)
      | Kernel.PTuple ps ->
          let arity = List.length ps in
          let spec =
            List.filter_map
              (fun row ->
                let p0 = strip (List.hd row) in
                match p0.Kernel.it with
                | Kernel.PTuple ps' when List.length ps' = arity -> Some (ps' @ List.tl row)
                | Kernel.PWild | Kernel.PVar _ ->
                    Some (List.init arity (fun _ -> wild_pat) @ List.tl row)
                | _ -> None)
              matrix
          in
          let item_tys =
            match t0 with TTuple ts -> ts | _ -> List.map (fun _ -> new_tvar ctx.level) ps
          in
          useful_row ctx (item_tys @ trest) spec (ps @ qrest)
      | Kernel.PLit l ->
          let spec =
            List.filter_map
              (fun row ->
                let p0 = strip (List.hd row) in
                match p0.Kernel.it with
                | Kernel.PLit l' when l = l' -> Some (List.tl row)
                | Kernel.PWild | Kernel.PVar _ -> Some (List.tl row)
                | _ -> None)
              matrix
          in
          useful_row ctx trest spec qrest
      | Kernel.PWild | Kernel.PVar _ -> (
          (* Maranget's wildcard case, threading the query columns (the review found the
             previous approximation missed redundancy when it hinged on later columns): if
             the column's present constructors form a complete signature, the wildcard is
             useful iff it is useful under SOME constructor specialization; otherwise the
             default matrix decides. *)
          let default_matrix () =
            List.filter_map
              (fun row -> if is_wild (List.hd row) then Some (List.tl row) else None)
              matrix
          in
          let col0 = List.map (fun row -> strip (List.hd row)) matrix in
          match t0 with
          | TCon (th, targs) -> (
              match constructors_of ctx th targs with
              | Some cons ->
                  let present ch =
                    List.exists
                      (fun p ->
                        match p.Kernel.it with
                        | Kernel.PCon (Kernel.Hashed h', _) -> Hash.equal h' ch
                        | _ -> false)
                      col0
                  in
                  if List.for_all (fun (ch, _, _) -> present ch) cons then
                    (* complete signature: useful under some constructor *)
                    if
                      List.exists
                        (fun (ch, _, fields) ->
                          let k = List.length fields in
                          useful_row ctx (fields @ trest) (specialize_con ch k)
                            (List.init k (fun _ -> wild_pat) @ qrest)
                          <> None)
                        cons
                    then Some ()
                    else None
                  else useful_row ctx trest (default_matrix ()) qrest
              | None -> useful_row ctx trest (default_matrix ()) qrest)
          | TTuple items ->
              let arity = List.length items in
              let spec =
                List.filter_map
                  (fun row ->
                    let p0 = strip (List.hd row) in
                    match p0.Kernel.it with
                    | Kernel.PTuple ps' when List.length ps' = arity -> Some (ps' @ List.tl row)
                    | Kernel.PWild | Kernel.PVar _ ->
                        Some (List.init arity (fun _ -> wild_pat) @ List.tl row)
                    | _ -> None)
                  matrix
              in
              useful_row ctx (items @ trest) spec (List.init arity (fun _ -> wild_pat) @ qrest)
          | _ -> useful_row ctx trest (default_matrix ()) qrest)
      | Kernel.PCon (Kernel.Named n, _) ->
          err ~meta:q0s.Kernel.meta ~code:"E0811" "unresolved constructor `%s`" n
      | Kernel.PAs _ -> assert false (* stripped *))
  | _ -> None

(* ------------------------------------------------------------------ *)
(* Public API                                                          *)
(* ------------------------------------------------------------------ *)

(** Build a checker context over a prelude-loaded store; resolves the primitive type hashes. *)
let make_ctx (store : Store.t) : (ctx, Diag.t list) result =
  let lookup name =
    match Store.lookup_kind store name Resolve.KType with
    | Some { Resolve.hash; _ } -> Ok hash
    | None -> Error [ Diag.error ~code:"E0805" (Printf.sprintf "primitive type `%s` missing" name) ]
  in
  match (lookup "int", lookup "real", lookup "text", lookup "code") with
  | Ok p_int, Ok p_real, Ok p_text, Ok p_code ->
      Ok
        {
          store;
          p_int;
          p_real;
          p_text;
          p_code;
          builtin_sigs = Hashtbl.create 32;
          term_sigs = Hashtbl.create 64;
          level = 0;
          checking = [];
          sites = [];
          origins = [];
          tier_apps = [];
          tier_ops = [];
        }
  | Error ds, _, _, _ | _, Error ds, _, _ | _, _, Error ds, _ | _, _, _, Error ds -> Error ds

type top_sig = {
  names : (string * scheme) list;  (** defterm members, or [("_", scheme)] for an expr *)
  row : row option;  (** an expression's inferred requirements (its manifest) *)
  warnings : Diag.t list;  (** redundant-clause warnings (W0801) from this form *)
}

let recovery_hashes identity bindings =
  List.mapi
    (fun index binding ->
      Hash.of_string
        (Printf.sprintf "surface-recovery-member:%s:%d:%s" identity index binding.Kernel.bname))
    bindings

let check_top_with ?recovery_identity ~recovery ctx (top : Kernel.top) :
    (top_sig, Diag.t list) result =
  ctx.sites <- [];
  match
    let partial =
      match top with
      | Kernel.Expr e ->
          let ambient = { effects = []; tail = new_rvar ctx.level } in
          let saved = ctx.level in
          let ty =
            Fun.protect
              ~finally:(fun () -> ctx.level <- saved)
              (fun () ->
                ctx.level <- ctx.level + 1;
                infer ctx empty_env ~ambient e)
          in
          close_lonely_rows ~gen_level:ctx.level ty;
          {
            names = [ ("_", { ty; gen_level = ctx.level }) ];
            row = Some (repr_row ambient);
            warnings = [];
          }
      | Kernel.Decl d -> (
          check_type_decl ctx d;
          match d.Kernel.it with
          | Kernel.DefTerm bindings ->
              let member_hashes =
                if recovery then recovery_hashes (Option.get recovery_identity) bindings else []
              in
              let recovery_group =
                Option.map
                  (fun identity ->
                    (Hash.of_string ("surface-recovery-group:" ^ identity), member_hashes))
                  recovery_identity
              in
              check_group ?recovery_group ctx d;
              let named =
                if recovery then
                  List.map2
                    (fun binding hash -> (binding.Kernel.bname, hash))
                    bindings member_hashes
                else
                  match Canon.hash_decl d with
                  | Ok { Canon.named; _ } -> named
                  | Error ds -> raise (Err (List.hd ds))
              in
              {
                names =
                  List.map2
                    (fun (b : Kernel.binding) (_, h) ->
                      match Hashtbl.find_opt ctx.term_sigs h with
                      | Some s -> (b.Kernel.bname, s)
                      | None -> (b.Kernel.bname, mono (new_tvar 0)))
                    bindings named;
                row = None;
                warnings = [];
              }
          | _ -> { names = []; row = None; warnings = [] })
    in
    (* exhaustiveness runs after inference so scrutinee types are solved (W3.5) *)
    let warnings =
      if recovery && Recovery_marker.top top then (
        ctx.sites <- [];
        [])
      else check_matches ctx
    in
    { partial with warnings }
  with
  | s -> Ok s
  | exception Err d -> Error [ d ]

(** [check_top ctx top] is the strict semantic checker. It rejects analysis sentinels (E1202), and
    declarations may be canonically hashed as part of scheme caching. Recovered surface trees must
    use {!Surface_check.analyze}; they are never valid compile/run input. *)
let check_top ctx top =
  if Recovery_marker.top top then Error [ Recovery_marker.diagnostic "the strict type checker" ]
  else check_top_with ~recovery:false ctx top

module Recovery = struct
  let clone_table_pairs builtin_sigs term_sigs =
    let builtins =
      Hashtbl.fold (fun hash scheme entries -> (hash, scheme) :: entries) builtin_sigs []
    in
    let terms = Hashtbl.fold (fun hash scheme entries -> (hash, scheme) :: entries) term_sigs [] in
    let schemes = Types.clone_schemes (List.map snd (builtins @ terms)) in
    let builtin_count = List.length builtins in
    let rec split count left = function
      | rest when count = 0 -> (List.rev left, rest)
      | item :: rest -> split (count - 1) (item :: left) rest
      | [] -> (List.rev left, [])
    in
    let cloned_builtins, cloned_terms = split builtin_count [] schemes in
    let copy entries clones =
      let table = Hashtbl.create (max 16 (List.length entries * 2)) in
      List.iter2 (fun (hash, _) scheme -> Hashtbl.add table hash scheme) entries clones;
      table
    in
    (copy builtins cloned_builtins, copy terms cloned_terms)

  (** [isolated_ctx base] copies store configuration and registered schemes into fresh mutable
      checker state. Neither checking nor type unification can mutate [base] or its cached schemes.
  *)
  let isolated_ctx base =
    let builtin_sigs, term_sigs = clone_table_pairs base.builtin_sigs base.term_sigs in
    {
      store = base.store;
      p_int = base.p_int;
      p_real = base.p_real;
      p_text = base.p_text;
      p_code = base.p_code;
      builtin_sigs;
      term_sigs;
      level = 0;
      checking = [];
      sites = [];
      origins = [];
      tier_apps = [];
      tier_ops = [];
    }

  (** Recovery checking is an internal service for [Surface_check]. [identity] need only be unique
      within one isolated context; it is never persisted or returned. *)
  let check_top ~identity ctx top =
    check_top_with ~recovery:true ~recovery_identity:identity ctx top
end

type recovery_session = Recovery_session of ctx

(** [start_recovery base] creates an isolated checker session for editor recovery. Mutable checker
    state and all type schemes are cloned, so recovery unification cannot affect [base]. *)
let start_recovery base = Recovery_session (Recovery.isolated_ctx base)

(** [check_recovery_top ~identity session top] checks one recovery-marked analysis island inside an
    isolated session. Results may feed later islands in the same session, but no recovered term is
    installed in a store or admitted to the strict checker. *)
let check_recovery_top ~identity (Recovery_session ctx) top = Recovery.check_top ~identity ctx top

(** [force_term ctx h] computes [h]'s scheme, checking its declaration on demand — the whole-store
    sweep the tier statistics need (PF.2 phase 1). *)
let force_term ctx (h : Hash.t) : (scheme, Diag.t list) result =
  match term_scheme ctx h with s -> Ok s | exception Err d -> Error [ d ]

(** Render an effect row for manifests and signatures. *)
let show_row ctx (r : row) : string =
  let r = repr_row r in
  String.concat ", " (List.map (name_of ctx) (List.sort Hash.compare r.effects))

(* ------------------------------------------------------------------ *)
(* Capability manifest (W3.6)                                          *)
(* ------------------------------------------------------------------ *)

(** [manifest_errors ctx ~granted row] checks a top-level expression's inferred row against the
    granted effect set: every fixed effect must be granted. The diagnostic names the effect and,
    when known, the call-chain endpoint that introduced it (E0814). *)
let manifest_errors ctx ?(grantable = []) ~(granted : Hash.t list) (row : row) : Diag.t list =
  let row = repr_row row in
  List.filter_map
    (fun h ->
      if List.exists (Hash.equal h) granted then None
      else
        let via =
          match List.assoc_opt h ctx.origins with
          | Some name -> Printf.sprintf " (performed via `%s`)" name
          | None -> ""
        in
        let name = name_of ctx h in
        (* pure effects (abort, state, ...) are never grantable; don't send the user to a
           --allow flag that will bounce with E0703. Callers pass Prelude.grantable_names;
           an empty list keeps the generic hint. *)
        let hint =
          if grantable = [] || List.mem name grantable then
            Printf.sprintf "grant it with --allow %s, or handle the effect in the program" name
          else "handle the effect in the program (this effect is pure and cannot be granted)"
        in
        Some
          (Diag.error ~code:"E0814" ~hint
             (Printf.sprintf "this program requires the `%s` effect, which is not granted%s" name
                via)))
    row.effects

(** Registry of every diagnostic code the checker can emit (W3.7's coverage check keys on this list;
    codes are never reused or renumbered). *)
let checker_codes : (string * string) list =
  [
    ("E0801", "type mismatch (expected vs actual, fully elaborated)");
    ("E0802", "application of a non-function");
    ("E0803", "arity mismatch (application, op clause, or resumption)");
    ("E0804", "annotation mismatch (the annotation is the contract)");
    ("E0805", "reference kind mismatch or unknown hash");
    ("E0806", "constructor pattern arity mismatch");
    ("E0807", "bare surface term reference where a compatible thunk is expected");
    ("E0810", "type constructor arity (kind) error");
    ("E0811", "unbound type or row variable");
    ("E0812", "unbound variable in an effect operation signature");
    ("E0813", "non-exhaustive match (with a missing-pattern witness)");
    ("E0814", "ungranted effect in the program manifest");
    ("E0815", "effectful top-level definition body (effects belong on arrows)");
    ("E0816", "once resumption consumed twice on one possible execution path");
    ("E0817", "once resumption escapes its affine handler-clause scope");
    ("W0801", "redundant match clause");
    ("E1202", "recovery marker rejected by the strict checker");
  ]
