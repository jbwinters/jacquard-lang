(* TS.1 executable model: lexically scoped State instances with multi-shot nondeterminism.

   A deliberately small calculus, independent of the Jacquard implementation, used to check the
   typing and dispatch rules of docs/designs/scoped-effect-instances.md. It has one parameterized
   effect (State, whose payload is the stored value) and one multi-shot effect (Amb, whose [flip]
   resumes its continuation twice). [scoped x init body] introduces a fresh State instance, binds
   the capability [x] to it, and handles only operations on that instance.

   It also has one payload-carrying effect, [emit], whose values are gathered by [collect]; it is
   how a capability could leave its scope through an outer handler instead of a result.

   Two typing modes and two dispatch modes are modelled:
   - [Instances] typing: each [scoped] introduces a rigid instance label (a skolem); a capability
     type [Cap (i, t)] carries the label and payload; rows are label sets; a body whose result type
     or remaining row mentions its own label is rejected (non-escape).
   - [Mono] typing: TS.0's shipped rule. All instances of the effect share one effect, and the
     payload travels with it in rows as a structured entry; a handled region handles every State
     operation of its body, so all of them must agree with its payload.
   - [By_instance] dispatch: an operation on capability [n] is handled by the frame of instance
     [n] (no frame is a stale capability).
   - [Nearest] dispatch: an operation is handled by the nearest State frame, as Jacquard dispatches
     by operation identity today.

   Slice 2b (§11 A3) adds two more instance kinds, each without an initializer:
   - [ThrowScoped (c, body)] has type [Result e a]; [ThrowAt (c, v, t)] has the annotated answer
     type [t], fresh at every use. A served throw yields [err v] and drops its continuation.
   - [EmitScoped (c, body)] has type [(a, List w)]; [EmitAt (c, v)] records [v] in chronological
     order.
   Their payload is a metavariable fixed by unification with the scope's own operations. Every
   scope, of any kind, checks non-escape on its transformed result, its outward row and the
   environment. Dispatch for every kind follows the same two modes: [By_instance] serves an
   operation at the frame holding its token (a non-matching frame forwards it outward), [Nearest]
   at the nearest frame of its kind.

   What a run establishes is stated in the design document; the limits are the generator's size
   bound and sample count. *)

type label = string
type cap_kind = State_cap | Throw_cap | Emit_cap

type ty =
  | TInt
  | TBool
  | TUnit
  | TText
  | TList of ty
  | TArr of ty * eff list * ty
  | TCap of cap_kind * label * ty
  | TResult of ty * ty  (** [Result e a]: error payload, then the body's answer *)
  | TPair of ty * ty
  | TMeta of int  (** a Throw or Emit scope's payload, fixed by unification *)

(* Row entries are structured: an instance label (or amb), or an effect carrying a payload type
   ("state" under Mono, "emit" in both modes). No string encoding stands for a type. *)
and eff = Label of label | Carrying of string * ty

type expr =
  | Int of int
  | Bool of bool
  | Unit
  | Text of string
  | Var of string
  | Lam of string * ty * expr  (** row labels in parameter types name instances by binder *)
  | App of expr * expr
  | Let of string * expr * expr
  | Add of expr * expr
  | If of expr * expr * expr
  | Get of expr
  | Put of expr * expr
  | Scoped of string * expr * expr
  | Flip
  | Amb of expr
  | Emit of expr
  | Collect of expr  (** the values its body emits, in order *)
  | Head of expr * expr  (** first element of a list, or the default *)
  | Detach of expr
      (** spawned work: runs after the whole program, outside every handler, as [async.spawn]'s
          child runs under the scheduler *)
  | ThrowScoped of string * expr
  | ThrowAt of expr * expr * ty  (** capability, error value, this use's answer type *)
  | EmitScoped of string * expr
  | EmitAt of expr * expr
  | MatchResult of expr * string * expr * string * expr  (** [ok x -> a | err y -> b] *)
  | Fst of expr
  | Snd of expr

(* --- typing --- *)

type mode = Instances | Mono

exception Ill_typed of string

let ill fmt = Printf.ksprintf (fun message -> raise (Ill_typed message)) fmt
let amb = Label "amb"
let norm row = List.sort_uniq compare row
let union a b = norm (a @ b)
let subset a b = List.for_all (fun l -> List.mem l b) a

let rec mentions label = function
  | TInt | TBool | TUnit | TText -> false
  | TList t -> mentions label t
  | TArr (a, row, b) -> mentions label a || List.exists (eff_mentions label) row || mentions label b
  | TCap (_, l, t) -> l = label || mentions label t
  | TResult (a, b) | TPair (a, b) -> mentions label a || mentions label b
  | TMeta _ -> false (* callers zonk first *)

and eff_mentions label = function Label l -> l = label | Carrying (_, t) -> mentions label t

type metas = (int, ty) Hashtbl.t

let rec zonk metas = function
  | (TInt | TBool | TUnit | TText) as t -> t
  | TList t -> TList (zonk metas t)
  | TArr (a, row, b) -> TArr (zonk metas a, zonk_row metas row, zonk metas b)
  | TCap (k, l, t) -> TCap (k, l, zonk metas t)
  | TResult (a, b) -> TResult (zonk metas a, zonk metas b)
  | TPair (a, b) -> TPair (zonk metas a, zonk metas b)
  | TMeta i as t -> ( match Hashtbl.find_opt metas i with Some t -> zonk metas t | None -> t)

and zonk_row metas row =
  norm (List.map (function Label _ as e -> e | Carrying (n, t) -> Carrying (n, zonk metas t)) row)

let rec occurs i = function
  | TInt | TBool | TUnit | TText -> false
  | TList t | TCap (_, _, t) -> occurs i t
  | TArr (a, row, b) ->
      occurs i a || occurs i b
      || List.exists (function Carrying (_, t) -> occurs i t | Label _ -> false) row
  | TResult (a, b) | TPair (a, b) -> occurs i a || occurs i b
  | TMeta j -> i = j

(* [unify metas a b]: [a] and [b] are equal once unsolved payloads are fixed; solves them. *)
let rec unify metas a b =
  match (zonk metas a, zonk metas b) with
  | TMeta i, TMeta j when i = j -> true
  | TMeta i, t | t, TMeta i ->
      if occurs i t then false
      else (
        Hashtbl.replace metas i t;
        true)
  | TInt, TInt | TBool, TBool | TUnit, TUnit | TText, TText -> true
  | TList a, TList b -> unify metas a b
  | TArr (a1, r1, b1), TArr (a2, r2, b2) ->
      unify metas a1 a2 && unify metas b1 b2 && zonk_row metas r1 = zonk_row metas r2
  | TCap (k1, l1, t1), TCap (k2, l2, t2) -> k1 = k2 && l1 = l2 && unify metas t1 t2
  | TResult (a1, b1), TResult (a2, b2) | TPair (a1, b1), TPair (a2, b2) ->
      unify metas a1 a2 && unify metas b1 b2
  | _ -> false

(* [sub metas a b]: a value of type [a] may be used where [b] is expected (rows are covariant
   sets; capability payloads are invariant). *)
let rec sub metas a b =
  match (zonk metas a, zonk metas b) with
  | TList a, TList b -> sub metas a b
  | TArr (a1, r1, b1), TArr (a2, r2, b2) ->
      sub metas a2 a1 && sub metas b1 b2 && subset (zonk_row metas r1) (zonk_row metas r2)
  | TResult (a1, b1), TResult (a2, b2) | TPair (a1, b1), TPair (a2, b2) ->
      sub metas a1 a2 && sub metas b1 b2
  | a, b -> unify metas a b

let rec show_ty = function
  | TInt -> "Int"
  | TBool -> "Bool"
  | TUnit -> "Unit"
  | TText -> "Text"
  | TList t -> "List " ^ show_ty t
  | TArr (a, r, b) ->
      Printf.sprintf "(%s ->{%s} %s)" (show_ty a)
        (String.concat "," (List.map show_eff r))
        (show_ty b)
  | TCap (k, l, t) ->
      Printf.sprintf "%s<%s> %s"
        (match k with State_cap -> "Cap" | Throw_cap -> "ThrowRef" | Emit_cap -> "EmitRef")
        l (show_ty t)
  | TResult (e, a) -> Printf.sprintf "Result (%s) (%s)" (show_ty e) (show_ty a)
  | TPair (a, b) -> Printf.sprintf "(%s, %s)" (show_ty a) (show_ty b)
  | TMeta i -> Printf.sprintf "?%d" i

and show_eff = function Label l -> l | Carrying (n, t) -> n ^ "<" ^ show_ty t ^ ">"

type env = {
  vars : (string * ty) list;
  instances : (string * label) list;  (** capability binder -> its label, for annotations *)
  fresh : int ref;  (** instance labels and payload metavariables *)
  metas : metas;
}

let mono_state = "state"

(* Under Mono each kind is one effect; its row entry carries the payload. *)
let mono_name = function
  | State_cap -> mono_state
  | Throw_cap -> "throw-instance"
  | Emit_cap -> "emit-instance"

(* Annotations name an instance by the capability binder that introduced it. Under Mono every
   capability has the one label [state]; its row entry carries the payload. *)
let rec resolve mode env = function
  | (TInt | TBool | TUnit | TText) as t -> t
  | TList t -> TList (resolve mode env t)
  | TArr (a, row, b) ->
      TArr (resolve mode env a, norm (List.map (resolve_eff mode env) row), resolve mode env b)
  | TCap (k, l, t) -> TCap (k, resolve_label env l, resolve mode env t)
  | TResult (a, b) -> TResult (resolve mode env a, resolve mode env b)
  | TPair (a, b) -> TPair (resolve mode env a, resolve mode env b)
  | TMeta _ as t -> t

and resolve_label env l =
  match List.assoc_opt l env.instances with
  | Some label -> label
  | None -> ill "unknown instance %s" l

and resolve_eff mode env = function
  | Label "amb" -> amb
  | Label l -> (
      match mode with
      | Instances -> Label (resolve_label env l)
      | Mono -> ill "under mono a state row entry is written with its payload, not %s" l)
  | Carrying (n, t) -> Carrying (n, resolve mode env t)

let instance_eff mode kind label payload =
  match mode with Instances -> Label label | Mono -> Carrying (mono_name kind, payload)

(* Instances: the scope's label may not appear in its transformed result, in its outward row, or in
   the type of anything in the enclosing environment (a payload variable solved inside the scope
   to a type that names a nested scope reaches the environment that way). *)
let close_instance env label result row =
  let result = zonk env.metas result in
  let outward = zonk_row env.metas (List.filter (fun e -> e <> Label label) row) in
  if mentions label result then ill "instance escapes through the result type %s" (show_ty result);
  (match List.find_opt (eff_mentions label) outward with
  | Some e -> ill "instance escapes through the effect %s" (show_eff e)
  | None -> ());
  (match List.find_opt (fun (_, t) -> mentions label (zonk env.metas t)) env.vars with
  | Some (x, t) ->
      ill "instance escapes through the environment: %s : %s" x (show_ty (zonk env.metas t))
  | None -> ());
  (result, outward)

(* Mono: the region handles every operation of its kind in its body, so they must all carry its
   payload (TS.0's one payload constraint per handled region); none remains outside. *)
let close_mono env kind payload result row =
  let name = mono_name kind in
  List.iter
    (function
      | Carrying (n, t) when n = name && not (unify env.metas t payload) ->
          ill "payload %s disagrees with the region's %s"
            (show_ty (zonk env.metas t))
            (show_ty (zonk env.metas payload))
      | _ -> ())
    row;
  ( zonk env.metas result,
    zonk_row env.metas (List.filter (function Carrying (n, _) -> n <> name | _ -> true) row) )

let new_meta env =
  incr env.fresh;
  TMeta !(env.fresh)

let rec infer mode env e : ty * eff list =
  match e with
  | Int _ -> (TInt, [])
  | Bool _ -> (TBool, [])
  | Unit -> (TUnit, [])
  | Text _ -> (TText, [])
  | Var x -> (
      match List.assoc_opt x env.vars with Some t -> (t, []) | None -> ill "unbound %s" x)
  | Lam (x, annot, body) ->
      let a = resolve mode env annot in
      let b, row = infer mode { env with vars = (x, a) :: env.vars } body in
      (TArr (a, row, b), [])
  | App (f, arg) -> (
      let tf, rf = infer mode env f in
      let ta, ra = infer mode env arg in
      match zonk env.metas tf with
      | TArr (p, latent, r) when sub env.metas ta p -> (r, union rf (union ra latent))
      | _ -> ill "bad application of %s to %s" (show_ty tf) (show_ty ta))
  | Let (x, e1, e2) ->
      let t1, r1 = infer mode env e1 in
      let t2, r2 = infer mode { env with vars = (x, t1) :: env.vars } e2 in
      (t2, union r1 r2)
  | Add (a, b) -> (
      let ta, ra = infer mode env a in
      let tb, rb = infer mode env b in
      match (unify env.metas ta TInt, unify env.metas tb TInt) with
      | true, true -> (TInt, union ra rb)
      | _ -> ill "add expects Int")
  | If (c, a, b) -> (
      let tc, rc = infer mode env c in
      let ta, ra = infer mode env a in
      let tb, rb = infer mode env b in
      match zonk env.metas tc with
      | TBool when unify env.metas ta tb -> (ta, union rc (union ra rb))
      | _ -> ill "if: condition or branch mismatch")
  | Get c -> (
      let tc, rc = infer mode env c in
      match zonk env.metas tc with
      | TCap (State_cap, l, t) -> (t, union rc [ instance_eff mode State_cap l t ])
      | t -> ill "get expects a capability, got %s" (show_ty t))
  | Put (c, v) -> (
      let tc, rc = infer mode env c in
      let tv, rv = infer mode env v in
      match zonk env.metas tc with
      | TCap (State_cap, l, t) when unify env.metas tv t ->
          (TUnit, union rc (union rv [ instance_eff mode State_cap l t ]))
      | _ -> ill "put: payload mismatch")
  | Scoped (x, init, body) ->
      let ti, ri = infer mode env init in
      let t, row = scope mode env State_cap x ti body (fun tb -> tb) in
      (t, union ri row)
  | ThrowScoped (x, body) ->
      let payload = new_meta env in
      scope mode env Throw_cap x payload body (fun tb -> TResult (payload, tb))
  | EmitScoped (x, body) ->
      let payload = new_meta env in
      scope mode env Emit_cap x payload body (fun tb -> TPair (tb, TList payload))
  | ThrowAt (c, v, answer) -> (
      let tc, rc = infer mode env c in
      let tv, rv = infer mode env v in
      match zonk env.metas tc with
      | TCap (Throw_cap, l, p) when unify env.metas tv p ->
          (* the answer is fresh at every use: a served throw never resumes *)
          (resolve mode env answer, union rc (union rv [ instance_eff mode Throw_cap l p ]))
      | _ -> ill "throw-at: capability or payload mismatch")
  | EmitAt (c, v) -> (
      let tc, rc = infer mode env c in
      let tv, rv = infer mode env v in
      match zonk env.metas tc with
      | TCap (Emit_cap, l, p) when unify env.metas tv p ->
          (TUnit, union rc (union rv [ instance_eff mode Emit_cap l p ]))
      | _ -> ill "emit-at: capability or payload mismatch")
  | MatchResult (scrutinee, x, on_ok, y, on_err) -> (
      let ts, rs = infer mode env scrutinee in
      match zonk env.metas ts with
      | TResult (te, ta) ->
          let t1, r1 = infer mode { env with vars = (x, ta) :: env.vars } on_ok in
          let t2, r2 = infer mode { env with vars = (y, te) :: env.vars } on_err in
          if unify env.metas t1 t2 then (t1, union rs (union r1 r2))
          else ill "match: branches disagree"
      | t -> ill "match expects a Result, got %s" (show_ty t))
  | Fst p -> (
      let tp, rp = infer mode env p in
      match zonk env.metas tp with TPair (a, _) -> (a, rp) | _ -> ill "fst expects a pair")
  | Snd p -> (
      let tp, rp = infer mode env p in
      match zonk env.metas tp with TPair (_, b) -> (b, rp) | _ -> ill "snd expects a pair")
  | Flip -> (TBool, [ amb ])
  | Amb body ->
      let tb, rb = infer mode env body in
      (TList tb, List.filter (fun e -> e <> amb) rb)
  | Emit v ->
      let tv, rv = infer mode env v in
      (TUnit, union rv [ Carrying ("emit", tv) ])
  | Collect body -> (
      let _, rb = infer mode env body in
      let emitted = List.filter_map (function Carrying ("emit", t) -> Some t | _ -> None) rb in
      let rest = List.filter (function Carrying ("emit", _) -> false | _ -> true) rb in
      match emitted with
      | [] -> (TList TUnit, rest)
      | t :: more when List.for_all (unify env.metas t) more -> (TList t, rest)
      | _ -> ill "collect: emitted values disagree")
  | Head (l, default) -> (
      let tl, rl = infer mode env l in
      let td, rd = infer mode env default in
      match zonk env.metas tl with
      | TList t when unify env.metas t td -> (t, union rl rd)
      | _ -> ill "head: list and default disagree")
  | Detach body -> (
      (* SC.4 extended: detached work runs outside every scoped handler, so its row must be empty;
         an instance in it would be served after its scope has ended *)
      let _, rb = infer mode env body in
      match rb with
      | [] -> (TUnit, [])
      | row ->
          ill "detached work performs scoped effects %s" (String.concat "," (List.map show_eff row))
      )

(* A scope of [kind] binding [x] to a capability over [payload]; [transform] gives the scope's
   result type from its body's. *)
and scope mode env kind x payload body transform =
  let label =
    match mode with
    | Instances ->
        incr env.fresh;
        Printf.sprintf "i%d" !(env.fresh)
    | Mono -> mono_name kind
  in
  let body_env =
    {
      env with
      vars = (x, TCap (kind, label, payload)) :: env.vars;
      instances = (x, label) :: env.instances;
    }
  in
  let tb, rb = infer mode body_env body in
  match mode with
  | Instances -> close_instance env label (transform tb) rb
  | Mono -> close_mono env kind payload (transform tb) rb

let check mode e =
  let env = { vars = []; instances = []; fresh = ref 0; metas = Hashtbl.create 8 } in
  match infer mode env e with
  | t, [] -> Ok (zonk env.metas t)
  | _, row -> Error ("unhandled effects: " ^ String.concat "," (List.map show_eff row))
  | exception Ill_typed message -> Error message

(* --- dynamic semantics --- *)

type value =
  | VInt of int
  | VBool of bool
  | VUnit
  | VText of string
  | VList of value list
  | VClo of string * expr * (string * value) list
  | VCap of int
  | VOk of value
  | VErr of value
  | VPair of value * value

type frame =
  | FAppFun of expr * (string * value) list
  | FAppArg of value
  | FLet of string * expr * (string * value) list
  | FAdd1 of expr * (string * value) list
  | FAdd2 of value
  | FIf of expr * expr * (string * value) list
  | FPutCap of expr * (string * value) list
  | FPutArg of value
  | FGet
  | FScopedInit of string * expr * (string * value) list
  | FScoped of int * value  (** handler frame of instance [n] holding its state *)
  | FAmb of { pending : (frame list * value) list; acc : value list }
  | FEmit
  | FCollect of value list  (** emitted so far, most recent first *)
  | FHead1 of expr * (string * value) list
  | FHead2 of value
  | FDetached
  | FThrowScope of int  (** handler frame of Throw instance [n] *)
  | FThrowCap of expr * (string * value) list
  | FThrowArg of value
  | FEmitScope of int * value list  (** Emit instance [n], recorded so far, most recent first *)
  | FEmitCap of expr * (string * value) list
  | FEmitArg of value
  | FMatch of string * expr * string * expr * (string * value) list
  | FFst
  | FSnd

type dispatch = By_instance | Nearest
type outcome = Value of value | Stuck of string | Out_of_fuel

exception Stuck_at of string

let stuck fmt = Printf.ksprintf (fun message -> raise (Stuck_at message)) fmt

(* [split target frames] is [(inner, frame, outer)] for the first frame satisfying [target]. *)
let split target frames =
  let rec go inner = function
    | [] -> None
    | f :: rest when target f -> Some (List.rev inner, f, rest)
    | f :: rest -> go (f :: inner) rest
  in
  go [] frames

(* The frame that serves an operation of [kind] on capability [cap]: under [By_instance] the frame
   holding that token (every other frame forwards it outward), under [Nearest] the nearest frame of
   that kind. *)
let instance_frame kind dispatch cap frame =
  let serves n = match dispatch with By_instance -> n = cap | Nearest -> true in
  match (kind, frame) with
  | State_cap, FScoped (n, _) | Throw_cap, FThrowScope n | Emit_cap, FEmitScope (n, _) -> serves n
  | _ -> false

let state_frame = instance_frame State_cap

let run ?(fuel = 2000) dispatch e =
  let fresh = ref 0 in
  let fuel = ref fuel in
  let detached = ref [] in
  let rec eval e env frames =
    decr fuel;
    if !fuel <= 0 then raise Exit;
    match e with
    | Int n -> return (VInt n) frames
    | Bool b -> return (VBool b) frames
    | Unit -> return VUnit frames
    | Text s -> return (VText s) frames
    | Var x -> (
        match List.assoc_opt x env with Some v -> return v frames | None -> stuck "unbound %s" x)
    | Lam (x, _, body) -> return (VClo (x, body, env)) frames
    | App (f, a) -> eval f env (FAppFun (a, env) :: frames)
    | Let (x, e1, e2) -> eval e1 env (FLet (x, e2, env) :: frames)
    | Add (a, b) -> eval a env (FAdd1 (b, env) :: frames)
    | If (c, a, b) -> eval c env (FIf (a, b, env) :: frames)
    | Get c -> eval c env (FGet :: frames)
    | Put (c, v) -> eval c env (FPutCap (v, env) :: frames)
    | Scoped (x, init, body) -> eval init env (FScopedInit (x, body, env) :: frames)
    | Flip -> (
        match split (function FAmb _ -> true | _ -> false) frames with
        | Some (inner, FAmb { pending; acc }, outer) ->
            return (VBool true)
              (inner @ (FAmb { pending = (inner, VBool false) :: pending; acc } :: outer))
        | _ -> stuck "flip is unhandled")
    | Amb body -> eval body env (FAmb { pending = []; acc = [] } :: frames)
    | Emit v -> eval v env (FEmit :: frames)
    | Collect body -> eval body env (FCollect [] :: frames)
    | Head (l, d) -> eval l env (FHead1 (d, env) :: frames)
    | Detach body ->
        detached := (body, env) :: !detached;
        return VUnit frames
    | ThrowScoped (x, body) ->
        incr fresh;
        let n = !fresh in
        eval body ((x, VCap n) :: env) (FThrowScope n :: frames)
    | ThrowAt (c, v, _) -> eval c env (FThrowCap (v, env) :: frames)
    | EmitScoped (x, body) ->
        incr fresh;
        let n = !fresh in
        eval body ((x, VCap n) :: env) (FEmitScope (n, []) :: frames)
    | EmitAt (c, v) -> eval c env (FEmitCap (v, env) :: frames)
    | MatchResult (s, x, a, y, b) -> eval s env (FMatch (x, a, y, b, env) :: frames)
    | Fst p -> eval p env (FFst :: frames)
    | Snd p -> eval p env (FSnd :: frames)
  and return v frames =
    decr fuel;
    if !fuel <= 0 then raise Exit;
    match frames with
    | [] -> v
    | FAppFun (a, env) :: rest -> eval a env (FAppArg v :: rest)
    | FAppArg (VClo (x, body, cenv)) :: rest -> eval body ((x, v) :: cenv) rest
    | FAppArg _ :: _ -> stuck "application of a non-function"
    | FLet (x, e2, env) :: rest -> eval e2 ((x, v) :: env) rest
    | FAdd1 (b, env) :: rest -> eval b env (FAdd2 v :: rest)
    | FAdd2 (VInt a) :: rest -> (
        match v with VInt b -> return (VInt (a + b)) rest | _ -> stuck "add of a non-Int")
    | FAdd2 _ :: _ -> stuck "add of a non-Int"
    | FIf (a, b, env) :: rest -> (
        match v with
        | VBool true -> eval a env rest
        | VBool false -> eval b env rest
        | _ -> stuck "if on a non-Bool")
    | FGet :: rest -> (
        match v with
        | VCap cap -> (
            match split (state_frame dispatch cap) rest with
            | Some (_, FScoped (_, state), _) -> return state rest
            | _ -> stuck "get on a stale capability")
        | _ -> stuck "get on a non-capability")
    | FPutCap (arg, env) :: rest -> eval arg env (FPutArg v :: rest)
    | FPutArg (VCap cap) :: rest -> (
        match split (state_frame dispatch cap) rest with
        | Some (inner, FScoped (n, _), outer) -> return VUnit (inner @ (FScoped (n, v) :: outer))
        | _ -> stuck "put on a stale capability")
    | FPutArg _ :: _ -> stuck "put on a non-capability"
    | FScopedInit (x, body, env) :: rest ->
        incr fresh;
        let n = !fresh in
        eval body ((x, VCap n) :: env) (FScoped (n, v) :: rest)
    | FScoped _ :: rest -> return v rest
    | FEmit :: rest -> (
        match split (function FCollect _ -> true | _ -> false) rest with
        | Some (inner, FCollect items, outer) ->
            return VUnit (inner @ (FCollect (v :: items) :: outer))
        | _ -> stuck "emit is unhandled")
    | FCollect items :: rest -> return (VList (List.rev items)) rest
    | FHead1 (d, env) :: rest -> eval d env (FHead2 v :: rest)
    | FHead2 (VList (x :: _)) :: rest -> return x rest
    | FHead2 (VList []) :: rest -> return v rest
    | FHead2 _ :: _ -> stuck "head of a non-list"
    | FDetached :: _ -> v
    | FThrowCap (arg, env) :: rest -> eval arg env (FThrowArg v :: rest)
    | FThrowArg (VCap cap) :: rest -> (
        (* served: err, dropping the continuation up to and including the frame *)
        match split (instance_frame Throw_cap dispatch cap) rest with
        | Some (_, FThrowScope _, outer) -> return (VErr v) outer
        | _ -> stuck "throw on a stale capability")
    | FThrowArg _ :: _ -> stuck "throw on a non-capability"
    | FThrowScope _ :: rest -> return (VOk v) rest
    | FEmitCap (arg, env) :: rest -> eval arg env (FEmitArg v :: rest)
    | FEmitArg (VCap cap) :: rest -> (
        match split (instance_frame Emit_cap dispatch cap) rest with
        | Some (inner, FEmitScope (n, items), outer) ->
            return VUnit (inner @ (FEmitScope (n, v :: items) :: outer))
        | _ -> stuck "emit on a stale capability")
    | FEmitArg _ :: _ -> stuck "emit on a non-capability"
    | FEmitScope (_, items) :: rest -> return (VPair (v, VList (List.rev items))) rest
    | FMatch (x, a, y, b, env) :: rest -> (
        match v with
        | VOk r -> eval a ((x, r) :: env) rest
        | VErr e -> eval b ((y, e) :: env) rest
        | _ -> stuck "match on a non-Result")
    | FFst :: rest -> (
        match v with VPair (a, _) -> return a rest | _ -> stuck "fst of a non-pair")
    | FSnd :: rest -> (
        match v with VPair (_, b) -> return b rest | _ -> stuck "snd of a non-pair")
    | FAmb { pending; acc } :: rest -> (
        let acc = v :: acc in
        match pending with
        | (inner, b) :: more -> return b (inner @ (FAmb { pending = more; acc } :: rest))
        | [] -> return (VList (List.rev acc)) rest)
  in
  (* the program's value, then every detached body in spawn order with no handler in scope *)
  let run_all () =
    let v = eval e [] [] in
    let rec drain () =
      match List.rev !detached with
      | [] -> ()
      | (body, env) :: later ->
          detached := List.rev later;
          ignore (eval body env [ FDetached ]);
          drain ()
    in
    drain ();
    v
  in
  match run_all () with
  | v -> Value v
  | exception Stuck_at message -> Stuck message
  | exception Exit -> Out_of_fuel
  | exception Stack_overflow -> Out_of_fuel

let rec value_has_type v t =
  match (v, t) with
  | VInt _, TInt | VBool _, TBool | VUnit, TUnit | VText _, TText -> true
  | VList vs, TList t -> List.for_all (fun v -> value_has_type v t) vs
  | VClo _, TArr _ -> true
  | VCap _, TCap _ -> true
  | VOk v, TResult (_, a) -> value_has_type v a
  | VErr v, TResult (e, _) -> value_has_type v e
  | VPair (a, b), TPair (ta, tb) -> value_has_type a ta && value_has_type b tb
  | _, TMeta _ -> true (* an unsolved payload: nothing constrains it *)
  | _ -> false
(* closures and capabilities are checked by constructor only; generated result types are base types
   and lists of them, where the check is exact *)

(* --- type-directed generation --- *)

let base_types = [ TInt; TBool; TText; TUnit ]

let gen_expr : expr QCheck.Gen.t =
  let open QCheck.Gen in
  let fresh_name = ref 0 in
  let name prefix =
    incr fresh_name;
    Printf.sprintf "%s%d" prefix !fresh_name
  in
  let rec literal = function
    | TInt -> map (fun n -> Int n) (int_range 0 9)
    | TBool -> map (fun b -> Bool b) bool
    | TText -> map (fun s -> Text s) (oneof_list [ "a"; "b" ])
    | TUnit -> return Unit
    | TList t ->
        return
          (Amb (match t with TInt -> Int 0 | TBool -> Bool true | TText -> Text "a" | _ -> Unit))
    | TArr (a, _, _) -> return (Lam ("_", a, Unit))
    | TResult (_, a) -> literal a >|= fun e -> ThrowScoped (name "t", e)
    | TPair (a, _) -> literal a >|= fun e -> EmitScoped (name "e", e)
    | TCap _ | TMeta _ -> return Unit
  in
  (* caps: (binder, kind, payload) for every capability in scope *)
  let rec gen ty (vars : (string * ty) list) (caps : (string * cap_kind * ty) list) size =
    let of_kind kind = List.filter (fun (_, k, _) -> k = kind) caps in
    let scaps = of_kind State_cap and tcaps = of_kind Throw_cap and ecaps = of_kind Emit_cap in
    let vars_of_type = List.filter (fun (_, t) -> t = ty) vars in
    let leaves =
      [ (3, literal ty) ]
      @ (if vars_of_type = [] then []
         else [ (4, map (fun (x, _) -> Var x) (oneof_list vars_of_type)) ])
      @ (match List.filter (fun (_, _, payload) -> payload = ty) scaps with
        | [] -> []
        | matching -> [ (4, map (fun (c, _, _) -> Get (Var c)) (oneof_list matching)) ])
      @ if ty = TBool then [ (2, return Flip) ] else []
    in
    if size <= 0 then oneof_weighted leaves
    else
      let smaller = size / 2 in
      let composite =
        [
          ( 2,
            oneof_list base_types >>= fun t1 ->
            let x = name "x" in
            gen t1 vars caps smaller >>= fun e1 ->
            gen ty ((x, t1) :: vars) caps smaller >|= fun e2 -> Let (x, e1, e2) );
          ( 2,
            oneof_list base_types >>= fun payload ->
            let c = name "c" in
            gen payload vars caps smaller >>= fun init ->
            gen ty vars ((c, State_cap, payload) :: caps) (size - 1) >|= fun body ->
            Scoped (c, init, body) );
          ( 2,
            (* an escape attempt: a closure over the capability leaves its scope and is then
               called; under a permissive checker this reaches a stale capability *)
            oneof_list base_types >>= fun payload ->
            let c = name "c" and k = name "k" in
            gen payload vars caps smaller >>= fun init ->
            gen ty vars caps smaller >|= fun rest ->
            Let
              ( k,
                Scoped (c, init, Lam ("_", TUnit, Get (Var c))),
                Let (name "e", App (Var k, Unit), rest) ) );
          ( 2,
            gen TBool vars caps smaller >>= fun c ->
            gen ty vars caps smaller >>= fun a ->
            gen ty vars caps smaller >|= fun b -> If (c, a, b) );
          ( 1,
            oneof_list base_types >>= fun t1 ->
            let x = name "y" in
            gen ty ((x, t1) :: vars) caps smaller >>= fun body ->
            gen t1 vars caps smaller >|= fun arg -> App (Lam (x, t1, body), arg) );
          ( 1,
            (* a Throw scope whose result is matched: ok returns the body's value, err handles the
               error payload *)
            oneof_list base_types >>= fun payload ->
            let t = name "t" and x = name "x" and y = name "y" in
            gen ty vars ((t, Throw_cap, payload) :: caps) (size - 1) >>= fun body ->
            gen ty ((y, payload) :: vars) caps smaller >|= fun handler ->
            MatchResult (ThrowScoped (t, body), x, Var x, y, handler) );
        ]
        @ (if ty <> TUnit then []
           else
             [
               ( 1,
                 (* an escape attempt through the result: a closure over the Throw capability leaves
               in ok and is then called *)
                 oneof_list base_types >>= fun payload ->
                 let t = name "t" and r = name "r" and f = name "f" in
                 gen payload vars caps smaller >>= fun v ->
                 gen TUnit vars caps smaller >|= fun rest ->
                 Let
                   ( r,
                     ThrowScoped (t, Lam ("_", TUnit, ThrowAt (Var t, v, TUnit))),
                     Let (name "u", MatchResult (Var r, f, App (Var f, Unit), name "z", Unit), rest)
                   ) );
               ( 1,
                 (* an escape attempt through the error payload: throw a nested State scope's
               capability, then use it outside that scope *)
                 oneof_list base_types >>= fun payload ->
                 let t = name "t" and d = name "d" and r = name "r" and k = name "k" in
                 gen payload vars caps smaller >>= fun init ->
                 gen TUnit vars caps smaller >|= fun rest ->
                 Let
                   ( r,
                     ThrowScoped (t, Scoped (d, init, ThrowAt (Var t, Var d, TUnit))),
                     Let
                       ( name "u",
                         MatchResult (Var r, name "o", Unit, k, Let (name "g", Get (Var k), Unit)),
                         rest ) ) );
             ])
        @ (if ty = TInt then
             [
               ( 2,
                 gen TInt vars caps smaller >>= fun a ->
                 gen TInt vars caps smaller >|= fun b -> Add (a, b) );
             ]
           else [])
        @ (match ty with
          | TList w ->
              (* an Emit scope's record of emitted values *)
              [
                ( 1,
                  oneof_list base_types >>= fun t1 ->
                  let e = name "e" in
                  gen t1 vars ((e, Emit_cap, w) :: caps) (size - 1) >|= fun body ->
                  Snd (EmitScoped (e, body)) );
              ]
          | _ ->
              (* an Emit scope's answer *)
              [
                ( 1,
                  oneof_list base_types >>= fun payload ->
                  let e = name "e" in
                  gen ty vars ((e, Emit_cap, payload) :: caps) (size - 1) >|= fun body ->
                  Fst (EmitScoped (e, body)) );
              ])
        @ (match tcaps with
          | [] -> []
          | _ ->
              [
                (* a throw at any answer type; outer capabilities forward through inner scopes *)
                ( 1,
                  oneof_list tcaps >>= fun (t, _, payload) ->
                  gen payload vars caps smaller >|= fun v -> ThrowAt (Var t, v, ty) );
              ])
        @ (match ecaps with
          | [] -> []
          | _ when ty = TUnit ->
              [
                ( 3,
                  oneof_list ecaps >>= fun (e, _, payload) ->
                  gen payload vars caps smaller >|= fun v -> EmitAt (Var e, v) );
              ]
          | _ -> [])
        @ (match scaps with
          | [] -> []
          | _ when ty = TUnit ->
              [
                ( 3,
                  oneof_list scaps >>= fun (c, _, payload) ->
                  gen payload vars caps smaller >|= fun v -> Put (Var c, v) );
              ]
          | _ -> [])
        @ (match ty with
          | TList t -> [ (4, gen t vars caps (size - 1) >|= fun body -> Amb body) ]
          | _ -> [])
        @ (match ty with
          | TList t ->
              (* gather emitted values of the element type *)
              [
                ( 1,
                  gen t vars caps smaller >>= fun v ->
                  gen TUnit vars caps smaller >|= fun rest -> Collect (Let (name "q", Emit v, rest))
                );
              ]
          | _ -> [])
        @ (if List.mem ty base_types then
             [
               (* read the first emitted value, with a default *)
               ( 1,
                 gen ty vars caps smaller >>= fun v ->
                 gen ty vars caps smaller >|= fun d -> Head (Collect (Emit v), d) );
             ]
           else [])
        @ (match scaps with
          | (other, _, _) :: _ when ty = TUnit ->
              [
                (* an escape attempt through an outer handler: emit the capability out of its scope,
                   then use it (rejected by the payload non-escape rule; stale if run anyway) *)
                ( 2,
                  oneof_list base_types >>= fun payload ->
                  let c = name "c" in
                  gen payload vars caps smaller >|= fun init ->
                  Let
                    ( name "g",
                      Get (Head (Collect (Scoped (c, init, Emit (Var c))), Var other)),
                      Unit ) );
              ]
          | _ -> [])
        @ (if ty = TUnit then
             (* spawned work: capability-free bodies are accepted, bodies over a capability are
                rejected by the detach rule *)
             [ (2, gen TUnit vars caps smaller >|= fun body -> Detach body) ]
           else [])
        @ (match scaps with
          | [] -> []
          | _ ->
              [
                (* a payload mismatch: put a value of another type (rejected) *)
                ( 1,
                  oneof_list scaps >>= fun (c, _, payload) ->
                  oneof_list (List.filter (fun t -> t <> payload) base_types) >>= fun wrong ->
                  gen wrong vars caps smaller >>= fun v ->
                  gen ty vars caps smaller >|= fun rest -> Let (name "m", Put (Var c, v), rest) );
                (* a function taking the capability as a parameter, applied to it *)
                ( 2,
                  oneof_list scaps >>= fun (c, _, payload) ->
                  let p = name "p" in
                  gen ty vars ((p, State_cap, payload) :: caps) smaller >|= fun body ->
                  App (Lam (p, TCap (State_cap, c, payload), body), Var c) );
                (* a function taking a thunk over the capability, applied to one *)
                ( 1,
                  oneof_list scaps >>= fun (c, _, payload) ->
                  let k = name "k" in
                  gen payload vars caps smaller >>= fun v ->
                  gen ty vars caps smaller >|= fun rest ->
                  App
                    ( Lam
                        ( k,
                          TArr (TUnit, [ Label c ], TUnit),
                          Let (name "u", App (Var k, Unit), rest) ),
                      Lam ("_", TUnit, Put (Var c, v)) ) );
              ])
        @
        (* a thunk that writes a capability, bound and applied later: higher-order transport *)
        match scaps with
        | [] -> []
        | _ ->
            [
              ( 3,
                oneof_list scaps >>= fun (c, _, payload) ->
                let f = name "f" in
                gen payload vars caps smaller >>= fun v ->
                gen ty vars caps smaller >|= fun rest ->
                Let (f, Lam ("_", TUnit, Let (name "w", Put (Var c, v), rest)), App (Var f, Unit))
              );
            ]
      in
      oneof_weighted (leaves @ composite)
  in
  QCheck.Gen.(
    oneof_list (base_types @ [ TList TInt; TList TBool ]) >>= fun ty ->
    sized_size (int_range 2 12) (gen ty [] []))
