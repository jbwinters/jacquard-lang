(** Monomorphization by content hash (docs/native-plan.md, task 69; pillar 3).

    A call to a known member with statically-known arguments (member globals: dictionaries,
    builtins, functions) is redirected to a SPECIALIZED clone keyed [spec:<member>:<arg-hashes>] — a
    content-addressed identity, so the emitted unit caches across builds exactly like every other
    declaration. Inside the clone, folding erases the dictionary: a Match on a global whose
    construction is statically known selects its clause at compile time and binds fields to the
    construction's atoms; a specialized function that folded down to [Ret atom] inlines at its call
    sites; copy propagation carries the atoms to the applies; and an apply whose callee became a
    builtin global re-classifies as a direct intrinsic call. `list.sort xs int.ord`'s comparator
    ends as jq_i_int_compare with no ord-record consultation left in the unit.

    Runs BEFORE Perceus (substituted-away parameters become dead and the ownership pass prunes their
    counts). JACQUARD_SPEC=off keeps the generic path, in its own cache keyspace. *)

open Jacquard
open Compile
module SMap = Map.Make (String)

type st = {
  members : (Hash.t, compiled_member) Hashtbl.t;  (** originals and specs, by member hash *)
  member_arity : (Hash.t, int) Hashtbl.t;
  builtin_names : (Hash.t, string) Hashtbl.t;  (** implemented intrinsics only *)
  intrinsics : (string, int) Hashtbl.t;
  const_shape : Hash.t -> (Hash.t * atom list) option;
      (** const member -> (con, field atoms) when its value is one statically-known CON *)
}

(* ------------------------------------------------------------------ *)
(* Keys                                                                *)
(* ------------------------------------------------------------------ *)

(* an argument participates in the key when it is a member global (its content hash IS its
   identity) or a capture-free lambda literal (task 86: identified by its lifted code — the
   host member's hash covers the body content; top-level hosts key by index, which only
   affects cross-build cache sharing, never correctness). Everything else is dynamic. *)
type lam_info = { code : Hash.t * int; lam_arity : int }

let arg_key (lams : lam_info SMap.t) = function
  | AGlobal g -> Some ("g:" ^ Hash.to_hex g)
  | AVar x -> (
      match SMap.find_opt x lams with
      | Some { code = ch, co; lam_arity } ->
          Some (Printf.sprintf "lam:%s:%d:%d" (Hash.to_hex ch) co lam_arity)
      | None -> None)
  | _ -> None

let spec_hash (lams : lam_info SMap.t) (h : Hash.t) (args : atom list) : Hash.t option =
  let keys = List.map (arg_key lams) args in
  if List.for_all Option.is_none keys then None
  else
    Some
      (Hash.of_string
         (Printf.sprintf "spec:%s:%s" (Hash.to_hex h)
            (String.concat "," (List.map (function Some k -> k | None -> "_") keys))))

(* ------------------------------------------------------------------ *)
(* Folding                                                             *)
(* ------------------------------------------------------------------ *)

(* substitute atoms for locals (copy propagation and pattern-fold binds) *)
let rec sub_atom (env : atom SMap.t) (a : atom) : atom =
  match a with
  | AVar x -> ( match SMap.find_opt x env with Some a' -> a' | None -> a)
  | AMove inner -> sub_atom env inner (* moves re-derive after Perceus; drop the wrapper *)
  | _ -> a

let sub_bound env (b : bound) : bound =
  let s = List.map (sub_atom env) in
  match b with
  | BAtom a -> BAtom (sub_atom env a)
  | BCallKnown (code, args) -> BCallKnown (code, s args)
  | BCallUnknown (f, args) -> BCallUnknown (sub_atom env f, s args)
  | BAllocCon (h, args) -> BAllocCon (h, s args)
  | BAllocConReuse (h, args, t) -> BAllocConReuse (h, s args, t)
  | BAllocTuple args -> BAllocTuple (s args)
  | BAllocClosure c -> BAllocClosure { c with captured = s c.captured }
  | BIntrinsic (n, args) -> BIntrinsic (n, s args)
  | BPerform (h, args) -> BPerform (h, s args)
  | BHandle (entries, thunk, retc) ->
      BHandle
        ( List.map (fun (o, c, a) -> (o, c, sub_atom env a)) entries,
          sub_atom env thunk,
          sub_atom env retc )

(* bind pattern variables against a statically-known construction; None = no match or not
   decidable (literals under cons are left to runtime — dictionaries never carry them) *)
let rec static_bind (st : st) (env : atom SMap.t) (p : npat) (a : atom) : atom SMap.t option =
  match p with
  | NPWild -> Some env
  | NPVar x -> Some (SMap.add x a env)
  | NPAs (x, inner) -> static_bind st (SMap.add x a env) inner a
  | NPCon (want, ps) -> (
      match a with
      | AGlobal g -> (
          match st.const_shape g with
          | Some (got, fields) when Hash.equal want got && List.length ps = List.length fields ->
              List.fold_left2
                (fun acc p f -> Option.bind acc (fun env -> static_bind st env p f))
                (Some env) ps fields
          | _ -> None)
      | _ -> None)
  | NPTuple _ | NPLit _ -> None

let rec fold_expr (st : st) (env : atom SMap.t) (lams : lam_info SMap.t) (e : expr) : expr =
  match e with
  | Ret a -> Ret (sub_atom env a)
  | Drop (xs, body) -> Drop (xs, fold_expr st env lams body)
  | LetReuse (t, x, n, body) -> LetReuse (t, x, n, fold_expr st env lams body)
  | Let (x, b, body) -> (
      let b = sub_bound env b in
      match b with
      | BAtom (AGlobal _ as a) | BAtom (ACon _ as a) | BAtom (AInt _ as a) ->
          (* copy-propagate statics through the binding *)
          fold_expr st (SMap.add x a env) lams body
      | BAllocClosure { code; captured = []; self_slot = None; arity } ->
          (* a capture-free lambda literal: its code IS its identity (task 86) *)
          Let (x, b, fold_expr st env (SMap.add x { code; lam_arity = arity } lams) body)
      | BCallUnknown (AVar f, args) when SMap.mem f lams ->
          (* the callee is a known lambda literal: call its code directly (the closure
             argument itself still flows for ownership; the direct call ignores clo) *)
          let { code; lam_arity } = SMap.find f lams in
          if lam_arity = List.length args then
            Let (x, BCallKnown (code, args), fold_expr st env lams body)
          else Let (x, b, fold_expr st env lams body)
      | BCallUnknown (AGlobal g, args) -> (
          (* the callee became known: re-classify like the lowerer would have, asserting
             the same arity invariant the lowerer refuses on (the checker makes a mismatch
             unreachable; the guard keeps this pass honest on its own) *)
          match Hashtbl.find_opt st.builtin_names g with
          | Some name when Hashtbl.find_opt st.intrinsics name = Some (List.length args) ->
              Let (x, BIntrinsic (name, args), fold_expr st env lams body)
          | _ -> (
              match Hashtbl.find_opt st.member_arity g with
              | Some arity when arity = List.length args ->
                  fold_expr st env lams (Let (x, BCallKnown ((g, 0), args), body))
              | _ -> Let (x, b, fold_expr st env lams body)))
      | BCallKnown ((h, 0), args) -> (
          match specialize st lams h args with
          | Some (_, `Inline atom) -> fold_expr st (SMap.add x atom env) lams body
          | Some (spec, `Call) -> Let (x, BCallKnown ((spec, 0), args), fold_expr st env lams body)
          | None -> Let (x, b, fold_expr st env lams body))
      | _ -> Let (x, b, fold_expr st env lams body))
  | Match (a, clauses) -> (
      let a = sub_atom env a in
      (* fold a match on a statically-known construction: first clause that binds wins *)
      let rec try_static = function
        | [] -> None
        | (p, body) :: rest -> (
            match static_bind st env p a with
            | Some env' -> Some (fold_expr st env' lams body)
            | None -> (
                (* only safe to skip this clause if it PROVABLY cannot match; for a known
                   con, a different-con pattern cannot match *)
                match (p, a) with
                | NPCon (want, _), AGlobal g -> (
                    match st.const_shape g with
                    | Some (got, _) when not (Hash.equal want got) -> try_static rest
                    | _ -> None)
                | _ -> None))
      in
      match try_static clauses with
      | Some folded -> folded
      | None -> Match (a, List.map (fun (p, body) -> (p, fold_expr st env lams body)) clauses))
  | TailSelf (args, post) -> TailSelf (List.map (sub_atom env) args, post)
  | TailKnown ((h, 0), args, post) -> (
      let args = List.map (sub_atom env) args in
      match specialize st lams h args with
      | Some (spec, `Call) -> TailKnown ((spec, 0), args, post)
      | Some (_, `Inline atom) -> Ret atom (* tail position: the value IS the result *)
      | None -> TailKnown ((h, 0), args, post))
  | TailKnown (code, args, post) -> TailKnown (code, List.map (sub_atom env) args, post)
  | TailUnknown (f, args, post) -> (
      let f = sub_atom env f in
      let args = List.map (sub_atom env) args in
      match f with
      | AVar v when SMap.mem v lams ->
          let { code; lam_arity } = SMap.find v lams in
          if lam_arity = List.length args then TailKnown (code, args, post)
          else TailUnknown (f, args, post)
      | AGlobal g -> (
          match Hashtbl.find_opt st.builtin_names g with
          | Some name when Hashtbl.find_opt st.intrinsics name = Some (List.length args) ->
              (* a tail intrinsic call has no Tail form; bind and return *)
              Let ("_spec_r", BIntrinsic (name, args), Ret (AVar "_spec_r"))
          | _ -> (
              match Hashtbl.find_opt st.member_arity g with
              | Some arity when arity = List.length args ->
                  fold_expr st env lams (TailKnown ((g, 0), args, post))
              | _ -> TailUnknown (f, args, post)))
      | _ -> TailUnknown (f, args, post))

(* [specialize st lams h args]: when some args are member globals or known lambda literals
   and [h] is a lowered function member, ensure the spec clone exists and say how to use it.
   `Inline means the clone folded to a bare atom. None when there is nothing to gain. *)
and specialize (st : st) (lams : lam_info SMap.t) (h : Hash.t) (args : atom list) :
    (Hash.t * [ `Call | `Inline of atom ]) option =
  match spec_hash lams h args with
  | None -> None
  | Some sh -> (
      (match Hashtbl.find_opt st.members sh with
      | Some _ -> ()
      | None -> (
          match Hashtbl.find_opt st.members h with
          | Some { main_fn = Some f; mname; _ } ->
              (* clone: bind NPVar params at known-arg positions (globals into the atom
                 env, lambda literals into the clone's lambda env), fold the body.
                 Register the clone BEFORE folding so recursive dictionary passing
                 terminates. *)
              let env, clone_lams =
                List.fold_left2
                  (fun (env, cl) p a ->
                    match p with
                    | NPVar x -> (
                        match a with
                        | AGlobal g -> (SMap.add x (AGlobal g) env, cl)
                        | AVar v -> (
                            match SMap.find_opt v lams with
                            | Some info -> (env, SMap.add x info cl)
                            | None -> (env, cl))
                        | _ -> (env, cl))
                    | _ -> (env, cl))
                  (SMap.empty, SMap.empty) f.params args
              in
              let placeholder =
                {
                  member = sh;
                  mname = Printf.sprintf "%s@spec" mname;
                  main_fn = Some { f with fname = (sh, 0) };
                  const_body = None;
                  lifted = [];
                  deps = [ h ];
                  cons_used = [];
                  ops_used = [];
                }
              in
              Hashtbl.replace st.members sh placeholder;
              Hashtbl.replace st.member_arity sh f.n_params;
              let body = fold_expr st env clone_lams f.body in
              (* the recursion above may have rewritten self-calls to this very key *)
              Hashtbl.replace st.members sh
                {
                  placeholder with
                  main_fn =
                    Some { f with fname = (sh, 0); body; self_entry = contains_tail_self body };
                };
              ()
          | _ -> ()));
      match Hashtbl.find_opt st.members sh with
      | Some { main_fn = Some { body = Ret a; _ }; _ }
        when match a with AVar _ | AEnv _ -> false | _ -> true ->
          Some (sh, `Inline a)
      | Some _ -> Some (sh, `Call)
      | None -> None)

(* ------------------------------------------------------------------ *)
(* Entry                                                               *)
(* ------------------------------------------------------------------ *)

let all_static = List.for_all (function AVar _ | AEnv _ | AMove _ -> false | _ -> true)

(* a const member whose value is one statically-known CON: Let(x, con-alloc, Ret x) modulo
   interleaved bindings (static fields cannot reference them, so skipping is sound) *)
let shape_of_const (body : expr) : (Hash.t * atom list) option =
  let rec find = function
    | Let (x, BAllocCon (c, fields), Ret (AVar y)) when x = y && all_static fields ->
        Some (c, fields)
    | Let (_, _, rest) | Drop (_, rest) -> find rest
    | _ -> None
  in
  find body

(** Rewrite every member body and top expression: call sites with statically-known arguments
    redirect to specialized clones; the clones fold their dictionaries away. Returns the member
    table extended with the specializations. *)
let run ~(members : (Hash.t, compiled_member) Hashtbl.t) ~(member_arity : (Hash.t, int) Hashtbl.t)
    ~(builtin_names : (Hash.t, string) Hashtbl.t) ~(intrinsics : (string, int) Hashtbl.t)
    ~(tops : (expr * fn list * string list) list) : (expr * fn list * string list) list =
  let shapes : (Hash.t, (Hash.t * atom list) option) Hashtbl.t = Hashtbl.create 32 in
  let st =
    {
      members;
      member_arity;
      builtin_names;
      intrinsics;
      const_shape =
        (fun g ->
          match Hashtbl.find_opt shapes g with
          | Some s -> s
          | None ->
              let s =
                match Hashtbl.find_opt members g with
                | Some { const_body = Some b; _ } -> shape_of_const b
                | _ -> None
              in
              Hashtbl.replace shapes g s;
              s);
    }
  in
  (* rewrite the originals' call sites (specialization happens on demand inside) *)
  let keys = Hashtbl.fold (fun k _ acc -> k :: acc) members [] in
  List.iter
    (fun k ->
      match Hashtbl.find_opt members k with
      | Some ({ main_fn = Some f; _ } as cm) ->
          Hashtbl.replace members k
            { cm with main_fn = Some { f with body = fold_expr st SMap.empty SMap.empty f.body } }
      | Some ({ const_body = Some b; _ } as cm) ->
          Hashtbl.replace members k
            { cm with const_body = Some (fold_expr st SMap.empty SMap.empty b) }
      | _ -> ())
    keys;
  List.map (fun (body, lifted, w) -> (fold_expr st SMap.empty SMap.empty body, lifted, w)) tops
