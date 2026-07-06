(** Kernel -> NIR lowering for the native backend (docs/native-plan.md, task 67).

    NIR is ANF: every intermediate is named, applications and allocations take atoms only, and
    control is explicit. Lowering does closure conversion (sorted free variables, the let-rec
    self-slot per the cycle rule), renames every binder to a unique C-safe local, and marks
    self-tail-calls for loopification. Eligibility is SYNTACTIC — a discharged handler has an empty
    row, so rows cannot gate (see the plan); anything this rung cannot lower raises [Refused] with
    the construct and its declaration named, surfaced as E1101. *)

open Jacquard

(* ------------------------------------------------------------------ *)
(* NIR                                                                 *)
(* ------------------------------------------------------------------ *)

type atom =
  | AVar of string  (** a unique local (parameter, let, or pattern binding) *)
  | AMove of atom
      (** Perceus (task 68): this use is the variable's last — transfer ownership, no dup. Lowering
          never produces it; the ownership pass rewrites final uses. *)
  | AEnv of int  (** a closure-environment slot of the current function *)
  | AInt of int
  | AReal of float
  | AText of string
  | AGlobal of Hash.t  (** a member used as a value: static closure/builtin or init-once cell *)
  | ACon of Hash.t  (** a constructor used as a value: static CON (arity 0) or CONSTRUCTOR *)
  | AOp of Hash.t  (** an effect operation as a value: static OP block; applying performs *)
  | AResume of unit
      (** lowering-internal marker for a tail-resumptive clause's resume binding: its only legal
          occurrence is applied in tail position, which lowers to the clause's return. Reaching the
          emitter is an internal error. *)

type npat =
  | NPWild
  | NPVar of string  (** already renamed to the unique local it binds *)
  | NPLit of Kernel.lit
  | NPCon of Hash.t * npat list
  | NPTuple of npat list
  | NPAs of string * npat

type expr =
  | Ret of atom
  | LetReuse of string * string * int * expr
      (** Perceus reuse (task 68): take the dying CON scrutinee's shell (token, scrutinee var,
          constructor arity, body). Matching-arity BAllocConReuse sites in the body consume the
          token; the emitter frees a leftover shell at every exit. Lowering never produces it. *)
  | Drop of string list * expr
      (** Perceus (task 68): these owned locals die here. Lowering never produces it. *)
  | Let of string * bound * expr
  | Match of atom * (npat * expr) list
      (** sequential first-match tests over the scrutinee atom; exhaustion reproduces the
          interpreter's Match_failure (scrutinee rendered by jq_show) *)
  | TailSelf of atom list * string list
      (** loopified self recursion: rebind params, goto entry. The string list is Perceus's
          post-drops — owned locals read THROUGH during argument materialization (clo, via AEnv)
          that must drop after the reads, not before (lowering leaves it empty). *)
  | TailKnown of Hash.t * atom list * string list
  | TailUnknown of atom * atom list * string list

and bound =
  | BAtom of atom
  | BCallKnown of Hash.t * atom list
  | BCallUnknown of atom * atom list
  | BAllocCon of Hash.t * atom list  (** exact arity, checked at lowering *)
  | BAllocConReuse of Hash.t * atom list * string  (** Perceus: fill the token's shell if live *)
  | BAllocTuple of atom list
  | BAllocClosure of closure_alloc
  | BIntrinsic of string * atom list
  | BPerform of Hash.t * atom list  (** effect op perform: nearest handler, else grant table *)
  | BHandle of (Hash.t * bool * atom) list * atom * atom
      (** jq_handle2: (op, capturing?, clause closure) entries, the 0-arity body thunk, and the
          1-parameter ret-clause closure. A tail-resumptive clause closure takes the op params (its
          return is the resume); a capturing clause takes them PLUS the resumption appended as its
          last parameter (task 71). The handle expression's value is the driver's return. *)

and closure_alloc = {
  code : Hash.t * int;
  captured : atom list;
      (** one per env slot, sorted-fv order; the self slot's entry is AVar of the binder and is
          stored WITHOUT dup by the emitter *)
  self_slot : int option;
  arity : int;
}

type fn = {
  fname : Hash.t * int;  (** (member, ordinal); 0 is the member's own lambda *)
  params : npat list;  (** irrefutable; the prologue destructures them *)
  n_params : int;
  n_env : int;
  body : expr;
  self_entry : bool;  (** body contains TailSelf: emit the entry label *)
}

type compiled_member = {
  member : Hash.t;
  mname : string;  (** display name, for diagnostics and C comments *)
  main_fn : fn option;  (** Some when the body is a Lam *)
  const_body : expr option;  (** otherwise: computed once at start, dependency order *)
  lifted : fn list;
  deps : Hash.t list;
  cons_used : Hash.t list;
  ops_used : Hash.t list;
}

type refusal = { where : string; what : string }

exception Refused of refusal

(* ------------------------------------------------------------------ *)
(* Free variables                                                      *)
(* ------------------------------------------------------------------ *)

module SSet = Set.Make (String)
module SMap = Map.Make (String)

let rec pat_binds (p : Kernel.pat) : SSet.t =
  match p.Kernel.it with
  | Kernel.PWild | Kernel.PLit _ -> SSet.empty
  | Kernel.PVar x -> SSet.singleton x
  | Kernel.PAs (x, inner) -> SSet.add x (pat_binds inner)
  | Kernel.PCon (_, ps) | Kernel.PTuple ps ->
      List.fold_left (fun acc p -> SSet.union acc (pat_binds p)) SSet.empty ps

let rec free_vars (e : Kernel.expr) : SSet.t =
  match e.Kernel.it with
  | Kernel.Lit _ | Kernel.Ref _ | Kernel.GroupRef _ | Kernel.Quote _ -> SSet.empty
  | Kernel.Var x -> SSet.singleton x
  | Kernel.Lam (params, body) ->
      let bound = List.fold_left (fun a p -> SSet.union a (pat_binds p)) SSet.empty params in
      SSet.diff (free_vars body) bound
  | Kernel.App (fn, args) ->
      List.fold_left (fun a e -> SSet.union a (free_vars e)) (free_vars fn) args
  | Kernel.Let { isrec; binder; value; body } ->
      let bound = pat_binds binder in
      let value_fv = free_vars value in
      let value_fv = if isrec then SSet.diff value_fv bound else value_fv in
      SSet.union value_fv (SSet.diff (free_vars body) bound)
  | Kernel.Match (scrutinee, clauses) ->
      List.fold_left
        (fun acc { Kernel.cpat; cbody; _ } ->
          SSet.union acc (SSet.diff (free_vars cbody) (pat_binds cpat)))
        (free_vars scrutinee) clauses
  | Kernel.Tuple items -> List.fold_left (fun a e -> SSet.union a (free_vars e)) SSet.empty items
  | Kernel.Handle { body; ret = { rbinder; rbody; _ }; ops } ->
      let ret_fv = SSet.diff (free_vars rbody) (pat_binds rbinder) in
      List.fold_left
        (fun acc (oc : Kernel.opclause) ->
          let bound =
            List.fold_left
              (fun a p -> SSet.union a (pat_binds p))
              (SSet.singleton oc.Kernel.resume) oc.Kernel.params
          in
          SSet.union acc (SSet.diff (free_vars oc.Kernel.obody) bound))
        (SSet.union (free_vars body) ret_fv)
        ops
  | Kernel.Unquote inner -> free_vars inner
  | Kernel.Ann (subject, _) -> free_vars subject

(* ------------------------------------------------------------------ *)
(* Lowering context                                                    *)
(* ------------------------------------------------------------------ *)

type ctx = {
  store : Store.t;
  intrinsics : (string, int) Hashtbl.t;  (** implemented builtin -> arity *)
  builtin_names : (Hash.t, string) Hashtbl.t;  (** every builtin marker member *)
  member_arity : (Hash.t, int) Hashtbl.t;  (** members whose body is a Lam *)
  where : string;
  mutable self : Hash.t option;
      (** the member whose MAIN body is being lowered: only it may loopify. Nested lambdas
          save/restore this to None — a tail call to the member from inside a lifted lambda is an
          ordinary call, and misclassifying it as TailSelf loops the lambda (review find). *)
  member : Hash.t;  (** the member being lowered; lifted lambda ordinals key off it *)
  mutable fresh : int;
  mutable lift_ordinal : int;
  mutable lifted : fn list;
  mutable deps : Hash.t list;
  mutable cons_used : Hash.t list;
  mutable ops_used : Hash.t list;  (** for link-time ordinal assignment and op metadata *)
}

let refuse ctx what = raise (Refused { where = ctx.where; what })

let fresh ctx prefix =
  ctx.fresh <- ctx.fresh + 1;
  Printf.sprintf "%s_%d" prefix ctx.fresh

let note_dep ctx h = if not (List.mem h ctx.deps) then ctx.deps <- h :: ctx.deps
let note_con ctx h = if not (List.mem h ctx.cons_used) then ctx.cons_used <- h :: ctx.cons_used
let note_op ctx h = if not (List.mem h ctx.ops_used) then ctx.ops_used <- h :: ctx.ops_used

let con_arity ctx (h : Hash.t) : int =
  match Store.locate ctx.store h with
  | Ok { Store.decl = { Kernel.it = Kernel.DefType { cons; _ }; _ }; role = Store.Constructor i; _ }
    -> (
      match List.nth_opt cons i with
      | Some { Kernel.fields; _ } -> List.length fields
      | None -> refuse ctx "constructor ordinal out of range (corrupt store)")
  | _ -> refuse ctx "constructor reference does not resolve (corrupt store)"

(* The op's owning effect declaration (for eval refusal and error metadata). *)
let op_effect ctx (h : Hash.t) : string * string =
  match Store.locate ctx.store h with
  | Ok
      {
        Store.decl = { Kernel.it = Kernel.DefEffect { ename; ops; _ }; _ };
        role = Store.Operation i;
        _;
      } -> (
      match List.nth_opt ops i with
      | Some { Kernel.op_name; _ } -> (ename, op_name)
      | None -> refuse ctx "operation ordinal out of range (corrupt store)")
  | _ -> refuse ctx "operation reference does not resolve (corrupt store)"

(* eval runs at root authority through the interpreter; a standalone binary has no
   interpreter tier, so the whole effect stays refused (E1102 per the plan) *)
let refuse_eval_op ctx (h : Hash.t) : unit =
  let ename, _ = op_effect ctx h in
  if ename = "eval" then refuse ctx "uses eval, which requires the interpreter tier"

(* env: source name -> atom for the current function *)
type env = atom SMap.t

(* ------------------------------------------------------------------ *)
(* Pattern renaming                                                    *)
(* ------------------------------------------------------------------ *)

(* Rename a pattern's binders to fresh locals, extending [env] for the body. *)
let rec rename_pat ctx (env : env) (p : Kernel.pat) : npat * env =
  match p.Kernel.it with
  | Kernel.PWild -> (NPWild, env)
  | Kernel.PLit l -> (NPLit l, env)
  | Kernel.PVar x ->
      let local = fresh ctx "v" in
      (NPVar local, SMap.add x (AVar local) env)
  | Kernel.PAs (x, inner) ->
      let local = fresh ctx "v" in
      let inner', env' = rename_pat ctx (SMap.add x (AVar local) env) inner in
      (NPAs (local, inner'), env')
  | Kernel.PCon (Kernel.Hashed h, ps) ->
      note_con ctx h;
      let ps', env' =
        List.fold_left
          (fun (acc, env) p ->
            let p', env' = rename_pat ctx env p in
            (p' :: acc, env'))
          ([], env) ps
      in
      (NPCon (h, List.rev ps'), env')
  | Kernel.PCon (Kernel.Named n, _) ->
      refuse ctx (Printf.sprintf "unresolved constructor pattern `%s`" n)
  | Kernel.PTuple ps ->
      let ps', env' =
        List.fold_left
          (fun (acc, env) p ->
            let p', env' = rename_pat ctx env p in
            (p' :: acc, env'))
          ([], env) ps
      in
      (NPTuple (List.rev ps'), env')

(* ------------------------------------------------------------------ *)
(* Expression lowering (ANF with a continuation for the non-tail case) *)
(* ------------------------------------------------------------------ *)

let member_value_atom ctx (h : Hash.t) : atom =
  note_dep ctx h;
  AGlobal h

(* Classify an application head that names a store member. *)
type head =
  | HIntrinsic of string * int
  | HKnown of Hash.t * int  (** member function of known arity *)
  | HValue of atom  (** anything else: generic apply on the member's value *)

let classify_member_head ctx (h : Hash.t) : head =
  match Hashtbl.find_opt ctx.builtin_names h with
  | Some name -> (
      match Hashtbl.find_opt ctx.intrinsics name with
      | Some arity -> HIntrinsic (name, arity)
      | None -> refuse ctx (Printf.sprintf "builtin `%s` is not yet implemented natively" name))
  | None -> (
      match Hashtbl.find_opt ctx.member_arity h with
      | Some arity ->
          note_dep ctx h;
          (* direct-call targets are deps too: reachability walks these *)
          HKnown (h, arity)
      | None -> HValue (member_value_atom ctx h))

let rec lower_tail ctx (env : env) (e : Kernel.expr) : expr =
  match e.Kernel.it with
  | Kernel.App (f, args) -> lower_app ctx env ~tail:true f args (fun a -> Ret a)
  | Kernel.Let _ | Kernel.Match _ | Kernel.Lit _ | Kernel.Var _ | Kernel.Ref _ | Kernel.GroupRef _
  | Kernel.Lam _ | Kernel.Tuple _ | Kernel.Ann _ | Kernel.Handle _ | Kernel.Quote _
  | Kernel.Unquote _ ->
      lower_general ctx env ~tail:true e (fun a -> Ret a)

(* [lower ctx env e k] evaluates [e] to an atom and continues; [k] receives an atom the
   continuation may use exactly like any local (ownership handled uniformly by the emitter). *)
and lower ctx (env : env) (e : Kernel.expr) (k : atom -> expr) : expr =
  lower_general ctx env ~tail:false e k

and lower_general ctx env ~tail (e : Kernel.expr) (k : atom -> expr) : expr =
  match e.Kernel.it with
  | Kernel.Lit (Kernel.LInt i) -> k (AInt i)
  | Kernel.Lit (Kernel.LReal r) -> k (AReal r)
  | Kernel.Lit (Kernel.LText s) -> k (AText s)
  | Kernel.Var x -> (
      match SMap.find_opt x env with
      | Some a -> k a
      | None -> refuse ctx (Printf.sprintf "unbound variable `%s` reached lowering" x))
  | Kernel.Ref (h, Kernel.Term) -> (
      match Hashtbl.find_opt ctx.builtin_names h with
      | Some name ->
          if Hashtbl.mem ctx.intrinsics name then k (member_value_atom ctx h)
          else refuse ctx (Printf.sprintf "builtin `%s` is not yet implemented natively" name)
      | None -> k (member_value_atom ctx h))
  | Kernel.Ref (h, Kernel.Con) ->
      note_con ctx h;
      k (ACon h)
  | Kernel.Ref (h, Kernel.Op) ->
      refuse_eval_op ctx h;
      note_op ctx h;
      k (AOp h)
  | Kernel.GroupRef i -> (
      match Store.locate ctx.store ctx.member with
      | Ok { Store.decl; _ } -> (
          match Canon.hash_decl decl with
          | Ok { Canon.named; _ } -> (
              match List.nth_opt named i with
              | Some (_, h) -> k (member_value_atom ctx h)
              | None -> refuse ctx "groupref outside its group")
          | Error _ -> refuse ctx "group hashing failed (corrupt store)")
      | Error _ -> refuse ctx "group member does not resolve (corrupt store)")
  | Kernel.Lam (params, body) -> lower_lambda ctx env ~recname:None params body k
  | Kernel.App (f, args) -> lower_app ctx env ~tail f args k
  | Kernel.Let { isrec = false; binder; value; body } ->
      lower ctx env value (fun v ->
          let np, env' = rename_pat ctx env binder in
          let body' =
            if tail then lower_tail ctx env' body else lower_general ctx env' ~tail:false body k
          in
          Match (v, [ (np, body') ]))
  | Kernel.Let { isrec = true; binder; value; body } -> (
      match (binder.Kernel.it, value.Kernel.it) with
      | Kernel.PVar x, Kernel.Lam (params, lam_body) ->
          let local = fresh ctx "rec" in
          let env' = SMap.add x (AVar local) env in
          lower_lambda ctx env'
            ~recname:(Some (x, local))
            params lam_body
            (fun clo ->
              let body' =
                if tail then lower_tail ctx env' body else lower_general ctx env' ~tail:false body k
              in
              match clo with
              | AVar tmp ->
                  (* rebind under the stable local the closure's env refers to *)
                  Let (local, BAtom (AVar tmp), body')
              | _ -> refuse ctx "let rec lowering produced a non-local closure")
      | _ -> refuse ctx "malformed let rec survived validation")
  | Kernel.Match (scrutinee, clauses) ->
      lower ctx env scrutinee (fun s ->
          let clauses' =
            List.map
              (fun { Kernel.cpat; cbody; _ } ->
                let np, env' = rename_pat ctx env cpat in
                let body' =
                  if tail then lower_tail ctx env' cbody
                  else lower_general ctx env' ~tail:false cbody k
                in
                (np, body'))
              clauses
          in
          Match (s, clauses'))
  | Kernel.Tuple items ->
      if List.length items > 65535 then
        refuse ctx "builds a tuple of more than 65535 elements (representation limit)";
      lower_list ctx env items (fun atoms ->
          let t = fresh ctx "t" in
          Let (t, BAllocTuple atoms, k (AVar t)))
  | Kernel.Handle { body; ret = { rbinder; rbody; _ }; ops } ->
      (* every discipline compiles since task 71: a tail-resumptive clause is a plain
         lambda whose return is the resume (task 70's protocol at the perform site);
         anything else — aborting, one-shot, multi-shot — is a capturing clause, an
         ordinary lambda taking the resumption appended as its last parameter. The
         handle runs through the jq_handle2 driver with a materialized ret closure. *)
      let entries_rev =
        List.fold_left
          (fun acc (oc : Kernel.opclause) ->
            let oh =
              match oc.Kernel.op with
              | Kernel.Hashed h -> h
              | Kernel.Named n -> refuse ctx (Printf.sprintf "unresolved op clause `%s`" n)
            in
            refuse_eval_op ctx oh;
            note_op ctx oh;
            let capturing =
              match Tier.discipline ~resume:oc.Kernel.resume oc.Kernel.obody with
              | Tier.TailResumptive -> false
              | _ -> true
            in
            (oh, capturing, oc) :: acc)
          [] ops
      in
      let rec alloc_clauses acc = function
        | [] ->
            let thunk_expr = { e with Kernel.it = Kernel.Lam ([], body) } in
            let ret_expr = { e with Kernel.it = Kernel.Lam ([ rbinder ], rbody) } in
            lower ctx env thunk_expr (fun thunk ->
                lower ctx env ret_expr (fun retc ->
                    let hv = fresh ctx "hv" in
                    Let (hv, BHandle (List.rev acc, thunk, retc), k (AVar hv))))
        | (oh, capturing, (oc : Kernel.opclause)) :: rest ->
            if capturing then
              (* the resumption is a first-class value: the clause is a plain lambda
                 over params @ [resume] — no marker, no rewrite *)
              let rpat = { rbinder with Kernel.it = Kernel.PVar oc.Kernel.resume } in
              let clause_expr =
                { e with Kernel.it = Kernel.Lam (oc.Kernel.params @ [ rpat ], oc.Kernel.obody) }
              in
              lower ctx env clause_expr (fun clause_atom ->
                  alloc_clauses ((oh, true, clause_atom) :: acc) rest)
            else
              lower_clause ctx env oc (fun clause_atom ->
                  alloc_clauses ((oh, false, clause_atom) :: acc) rest)
      in
      alloc_clauses [] (List.rev entries_rev)
  | Kernel.Quote _ -> refuse ctx "contains a quote (code values land with task 73)"
  | Kernel.Unquote _ -> refuse ctx "unquote outside quote reached lowering"
  | Kernel.Ann (subject, _) -> lower_general ctx env ~tail subject k

and lower_list ctx env (es : Kernel.expr list) (k : atom list -> expr) : expr =
  match es with
  | [] -> k []
  | e :: rest -> lower ctx env e (fun a -> lower_list ctx env rest (fun atoms -> k (a :: atoms)))

and lower_clause ctx env (oc : Kernel.opclause) (k : atom -> expr) : expr =
  (* identical to lower_lambda over the op parameters, with the resume name bound to the
     lowering marker inside the clause body *)
  let params = oc.Kernel.params in
  let body = oc.Kernel.obody in
  if List.length params > 8 then
    refuse ctx "defines an op clause of more than 8 parameters (native v1 arity cap)";
  let bound = List.fold_left (fun a p -> SSet.union a (pat_binds p)) SSet.empty params in
  let fv = SSet.elements (SSet.diff (SSet.remove oc.Kernel.resume (free_vars body)) bound) in
  ctx.lift_ordinal <- ctx.lift_ordinal + 1;
  let ordinal = ctx.lift_ordinal in
  let inner_env =
    List.fold_left (fun (i, m) x -> (i + 1, SMap.add x (AEnv i) m)) (0, SMap.empty) fv |> snd
  in
  let inner_env = SMap.add oc.Kernel.resume (AResume ()) inner_env in
  let nparams, inner_env =
    List.fold_left
      (fun (acc, env) p ->
        let np, env' = rename_pat ctx env p in
        (np :: acc, env'))
      ([], inner_env) params
  in
  let saved_self = ctx.self in
  ctx.self <- None;
  let fbody =
    Fun.protect
      ~finally:(fun () -> ctx.self <- saved_self)
      (fun () -> lower_tail ctx inner_env body)
  in
  let f =
    {
      fname = (ctx.member, ordinal);
      params = List.rev nparams;
      n_params = List.length params;
      n_env = List.length fv;
      body = fbody;
      self_entry = contains_tail_self fbody;
    }
  in
  ctx.lifted <- f :: ctx.lifted;
  let captured =
    List.map
      (fun x ->
        match SMap.find_opt x env with
        | Some a -> a
        | None -> refuse ctx (Printf.sprintf "free variable `%s` not in scope" x))
      fv
  in
  let c = fresh ctx "clo" in
  Let
    ( c,
      BAllocClosure
        { code = (ctx.member, ordinal); captured; self_slot = None; arity = List.length params },
      k (AVar c) )

and lower_lambda ctx env ~recname params body (k : atom -> expr) : expr =
  if List.length params > 8 then
    refuse ctx "defines a function of more than 8 parameters (native v1 arity cap)";
  let bound = List.fold_left (fun a p -> SSet.union a (pat_binds p)) SSet.empty params in
  let fv = SSet.elements (SSet.diff (free_vars body) bound) in
  (* the let-rec binder occupies an env slot but is stored without dup (the cycle rule) *)
  let self_source = Option.map fst recname in
  let self_slot =
    Option.bind self_source (fun x ->
        let rec idx i = function
          | [] -> None
          | y :: _ when String.equal x y -> Some i
          | _ :: rest -> idx (i + 1) rest
        in
        idx 0 fv)
  in
  ctx.lift_ordinal <- ctx.lift_ordinal + 1;
  let ordinal = ctx.lift_ordinal in
  (* the lifted function's env: fv.(i) -> AEnv i; params renamed fresh *)
  let inner_env =
    List.fold_left (fun (i, m) x -> (i + 1, SMap.add x (AEnv i) m)) (0, SMap.empty) fv |> snd
  in
  let nparams, inner_env =
    List.fold_left
      (fun (acc, env) p ->
        let np, env' = rename_pat ctx env p in
        (np :: acc, env'))
      ([], inner_env) params
  in
  let saved_self = ctx.self in
  ctx.self <- None;
  let fbody =
    Fun.protect
      ~finally:(fun () -> ctx.self <- saved_self)
      (fun () -> lower_tail ctx inner_env body)
  in
  let f =
    {
      fname = (ctx.member, ordinal);
      params = List.rev nparams;
      n_params = List.length params;
      n_env = List.length fv;
      body = fbody;
      self_entry = contains_tail_self fbody;
    }
  in
  ctx.lifted <- f :: ctx.lifted;
  let captured =
    List.map
      (fun x ->
        match SMap.find_opt x env with
        | Some a -> a
        | None -> refuse ctx (Printf.sprintf "free variable `%s` not in scope" x))
      fv
  in
  let c = fresh ctx "clo" in
  Let
    ( c,
      BAllocClosure
        { code = (ctx.member, ordinal); captured; self_slot; arity = List.length params },
      k (AVar c) )

and contains_tail_self (e : expr) : bool =
  match e with
  | TailSelf _ -> true
  | Ret _ | TailKnown _ | TailUnknown _ -> false
  | Drop (_, body) | LetReuse (_, _, _, body) -> contains_tail_self body
  | Let (_, _, body) -> contains_tail_self body
  | Match (_, clauses) -> List.exists (fun (_, b) -> contains_tail_self b) clauses

and lower_app ctx env ~tail (f : Kernel.expr) (args : Kernel.expr list) (k : atom -> expr) : expr =
  if List.length args > 8 then refuse ctx "applies more than 8 arguments (native v1 arity cap)";
  let with_args k' = lower_list ctx env args k' in
  let bind_call bound =
    let r = fresh ctx "r" in
    Let (r, bound, k (AVar r))
  in
  match f.Kernel.it with
  | Kernel.Ref (h, Kernel.Term) -> (
      match classify_member_head ctx h with
      | HIntrinsic (name, arity) ->
          if List.length args <> arity then
            refuse ctx (Printf.sprintf "builtin `%s` applied with the wrong arity" name)
          else with_args (fun atoms -> bind_call (BIntrinsic (name, atoms)))
      | HKnown (h, arity) when List.length args = arity ->
          if tail then
            if ctx.self = Some h then with_args (fun atoms -> TailSelf (atoms, []))
            else with_args (fun atoms -> TailKnown (h, atoms, []))
          else with_args (fun atoms -> bind_call (BCallKnown (h, atoms)))
      | HKnown (h, _) | HValue (AGlobal h) ->
          let a = member_value_atom ctx h in
          if tail then with_args (fun atoms -> TailUnknown (a, atoms, []))
          else with_args (fun atoms -> bind_call (BCallUnknown (a, atoms)))
      | HValue a ->
          if tail then with_args (fun atoms -> TailUnknown (a, atoms, []))
          else with_args (fun atoms -> bind_call (BCallUnknown (a, atoms))))
  | Kernel.Ref (h, Kernel.Con) ->
      note_con ctx h;
      let arity = con_arity ctx h in
      if List.length args <> arity then
        refuse ctx "constructor applied with the wrong arity (unreachable for checked code)"
      else with_args (fun atoms -> bind_call (BAllocCon (h, atoms)))
  | Kernel.Ref (h, Kernel.Op) ->
      refuse_eval_op ctx h;
      note_op ctx h;
      with_args (fun atoms -> bind_call (BPerform (h, atoms)))
  | Kernel.GroupRef i -> (
      match Store.locate ctx.store ctx.member with
      | Ok { Store.decl; _ } -> (
          match Canon.hash_decl decl with
          | Ok { Canon.named; _ } -> (
              match List.nth_opt named i with
              | Some (_, h) ->
                  lower_app ctx env ~tail { f with Kernel.it = Kernel.Ref (h, Kernel.Term) } args k
              | None -> refuse ctx "groupref outside its group")
          | Error _ -> refuse ctx "group hashing failed (corrupt store)")
      | Error _ -> refuse ctx "group member does not resolve (corrupt store)")
  | Kernel.Var x when SMap.find_opt x env = Some (AResume ()) -> (
      if
        (* a tail-resumptive clause's resume: the clause's return IS the resumption, so in
         tail position the argument is simply the result. The discipline classifier
         guarantees tail-only single use; anything else here is an internal error. *)
        not tail
      then refuse ctx "internal: tail-resumptive clause used resume off tail (classifier bug)"
      else
        match args with
        | [ arg ] -> lower ctx env arg (fun a -> Ret a)
        | _ -> refuse ctx "a resumption takes exactly one argument")
  | _ ->
      lower ctx env f (fun fa ->
          if tail then with_args (fun atoms -> TailUnknown (fa, atoms, []))
          else with_args (fun atoms -> bind_call (BCallUnknown (fa, atoms))))

(* ------------------------------------------------------------------ *)
(* Member lowering                                                     *)
(* ------------------------------------------------------------------ *)

let make_ctx ~store ~intrinsics ~builtin_names ~member_arity ~where ~self ~member =
  {
    store;
    intrinsics;
    builtin_names;
    member_arity;
    where;
    self;
    member;
    fresh = 0;
    lift_ordinal = 0;
    lifted = [];
    deps = [];
    cons_used = [];
    ops_used = [];
  }

(** Lower one member binding. The member's own Lam becomes function ordinal 1 renumbered as the MAIN
    function (ordinal 0 by convention in [fn.fname] consumers); any other body becomes a
    once-initialized constant. *)
let lower_member ~store ~intrinsics ~builtin_names ~member_arity ~name (member : Hash.t)
    (value : Kernel.expr) : compiled_member =
  let ctx =
    make_ctx ~store ~intrinsics ~builtin_names ~member_arity ~where:name ~self:(Some member) ~member
  in
  match value.Kernel.it with
  | Kernel.Lam (params, body) ->
      if List.length params > 8 then
        raise
          (Refused
             {
               where = name;
               what = "defines a function of more than 8 parameters (native v1 arity cap)";
             });
      (* lower as the member's main function, not a heap closure: env is empty (top level) *)
      let nparams, env =
        List.fold_left
          (fun (acc, env) p ->
            let np, env' = rename_pat ctx env p in
            (np :: acc, env'))
          ([], SMap.empty) params
      in
      let fbody = lower_tail ctx env body in
      let main =
        {
          fname = (member, 0);
          params = List.rev nparams;
          n_params = List.length params;
          n_env = 0;
          body = fbody;
          self_entry = contains_tail_self fbody;
        }
      in
      {
        member;
        mname = name;
        main_fn = Some main;
        const_body = None;
        lifted = List.rev ctx.lifted;
        deps = ctx.deps;
        cons_used = ctx.cons_used;
        ops_used = ctx.ops_used;
      }
  | _ ->
      let ctx = { ctx with self = None } in
      let body = lower_tail ctx SMap.empty value in
      {
        member;
        mname = name;
        main_fn = None;
        const_body = Some body;
        lifted = List.rev ctx.lifted;
        deps = ctx.deps;
        cons_used = ctx.cons_used;
        ops_used = ctx.ops_used;
      }

(** Lower a top-level expression (evaluated and printed by the generated main). Lambdas inside it
    lift against a synthetic per-expression identity. *)
let lower_top ~store ~intrinsics ~builtin_names ~member_arity ~index (e : Kernel.expr) :
    expr * fn list * Hash.t list * Hash.t list * Hash.t list =
  let ctx =
    make_ctx ~store ~intrinsics ~builtin_names ~member_arity
      ~where:(Printf.sprintf "top-level expression %d" index)
      ~self:None
      ~member:(Hash.of_string (Printf.sprintf "native-top-%d" index))
  in
  let body = lower_tail ctx SMap.empty e in
  (body, List.rev ctx.lifted, ctx.deps, ctx.cons_used, ctx.ops_used)
