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

   What a run establishes is stated in the design document; the limits are the generator's size
   bound and sample count. *)

type label = string

type ty =
  | TInt
  | TBool
  | TUnit
  | TText
  | TList of ty
  | TArr of ty * eff list * ty
  | TCap of label * ty

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
  | TCap (l, t) -> l = label || mentions label t

and eff_mentions label = function Label l -> l = label | Carrying (_, t) -> mentions label t

(* [sub a b]: a value of type [a] may be used where [b] is expected (rows are covariant sets). *)
let rec sub a b =
  match (a, b) with
  | TInt, TInt | TBool, TBool | TUnit, TUnit | TText, TText -> true
  | TList a, TList b -> sub a b
  | TArr (a1, r1, b1), TArr (a2, r2, b2) -> sub a2 a1 && subset r1 r2 && sub b1 b2
  | TCap (l1, t1), TCap (l2, t2) -> l1 = l2 && t1 = t2
  | _ -> false

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
  | TCap (l, t) -> Printf.sprintf "Cap<%s> %s" l (show_ty t)

and show_eff = function Label l -> l | Carrying (n, t) -> n ^ "<" ^ show_ty t ^ ">"

type env = {
  vars : (string * ty) list;
  instances : (string * label) list;  (** capability binder -> its label, for annotations *)
  fresh : int ref;
}

let mono_state = "state"

(* Annotations name an instance by the capability binder that introduced it. Under Mono every
   capability has the one label [state]; its row entry carries the payload. *)
let rec resolve mode env = function
  | (TInt | TBool | TUnit | TText) as t -> t
  | TList t -> TList (resolve mode env t)
  | TArr (a, row, b) ->
      TArr (resolve mode env a, norm (List.map (resolve_eff mode env) row), resolve mode env b)
  | TCap (l, t) -> TCap (resolve_label env l, resolve mode env t)

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

let state_eff mode label payload =
  match mode with Instances -> Label label | Mono -> Carrying (mono_state, payload)

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
      match tf with
      | TArr (p, latent, r) when sub ta p -> (r, union rf (union ra latent))
      | _ -> ill "bad application of %s to %s" (show_ty tf) (show_ty ta))
  | Let (x, e1, e2) ->
      let t1, r1 = infer mode env e1 in
      let t2, r2 = infer mode { env with vars = (x, t1) :: env.vars } e2 in
      (t2, union r1 r2)
  | Add (a, b) -> (
      match (infer mode env a, infer mode env b) with
      | (TInt, ra), (TInt, rb) -> (TInt, union ra rb)
      | _ -> ill "add expects Int")
  | If (c, a, b) -> (
      let tc, rc = infer mode env c in
      let ta, ra = infer mode env a in
      let tb, rb = infer mode env b in
      match tc with
      | TBool when ta = tb -> (ta, union rc (union ra rb))
      | _ -> ill "if: condition or branch mismatch")
  | Get c -> (
      match infer mode env c with
      | TCap (l, t), rc -> (t, union rc [ state_eff mode l t ])
      | t, _ -> ill "get expects a capability, got %s" (show_ty t))
  | Put (c, v) -> (
      let tc, rc = infer mode env c in
      let tv, rv = infer mode env v in
      match tc with
      | TCap (l, t) when tv = t -> (TUnit, union rc (union rv [ state_eff mode l t ]))
      | _ -> ill "put: payload mismatch")
  | Scoped (x, init, body) -> (
      let ti, ri = infer mode env init in
      match mode with
      | Instances ->
          incr env.fresh;
          let label = Printf.sprintf "i%d" !(env.fresh) in
          let body_env =
            {
              env with
              vars = (x, TCap (label, ti)) :: env.vars;
              instances = (x, label) :: env.instances;
            }
          in
          let tb, rb = infer mode body_env body in
          let outward = List.filter (fun e -> e <> Label label) rb in
          (* non-escape: neither the result nor the payload of any effect leaving the scope may
             mention the instance *)
          if mentions label tb then ill "instance escapes through the result type %s" (show_ty tb);
          (match List.find_opt (eff_mentions label) outward with
          | Some e -> ill "instance escapes through the effect %s" (show_eff e)
          | None -> ());
          (tb, union ri outward)
      | Mono ->
          let body_env =
            {
              env with
              vars = (x, TCap (mono_state, ti)) :: env.vars;
              instances = (x, mono_state) :: env.instances;
            }
          in
          let tb, rb = infer mode body_env body in
          (* the region handles every State operation of its body, so they must all carry its
             payload (TS.0's one payload constraint per handled region); none remains outside *)
          List.iter
            (function
              | Carrying (n, t) when n = mono_state && t <> ti ->
                  ill "payload %s disagrees with the region's %s" (show_ty t) (show_ty ti)
              | _ -> ())
            rb;
          (tb, union ri (List.filter (function Carrying (n, _) -> n <> mono_state | _ -> true) rb)))
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
      match List.sort_uniq compare emitted with
      | [] -> (TList TUnit, rest)
      | [ t ] -> (TList t, rest)
      | _ -> ill "collect: emitted values disagree")
  | Head (l, default) -> (
      let tl, rl = infer mode env l in
      let td, rd = infer mode env default in
      match tl with
      | TList t when t = td -> (t, union rl rd)
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

let check mode e =
  match infer mode { vars = []; instances = []; fresh = ref 0 } e with
  | t, [] -> Ok t
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

let state_frame dispatch cap = function
  | FScoped (n, _) -> ( match dispatch with By_instance -> n = cap | Nearest -> true)
  | _ -> false

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
  let literal = function
    | TInt -> map (fun n -> Int n) (int_range 0 9)
    | TBool -> map (fun b -> Bool b) bool
    | TText -> map (fun s -> Text s) (oneof_list [ "a"; "b" ])
    | TUnit -> return Unit
    | TList t ->
        return
          (Amb (match t with TInt -> Int 0 | TBool -> Bool true | TText -> Text "a" | _ -> Unit))
    | TArr (a, _, _) -> return (Lam ("_", a, Unit))
    | TCap _ -> return Unit
  in
  (* vars: (name, ty, is_cap_with_binder) *)
  let rec gen ty (vars : (string * ty) list) (caps : (string * ty) list) size =
    let vars_of_type = List.filter (fun (_, t) -> t = ty) vars in
    let leaves =
      [ (3, literal ty) ]
      @ (if vars_of_type = [] then []
         else [ (4, map (fun (x, _) -> Var x) (oneof_list vars_of_type)) ])
      @ (match List.filter (fun (_, payload) -> payload = ty) caps with
        | [] -> []
        | matching -> [ (4, map (fun (c, _) -> Get (Var c)) (oneof_list matching)) ])
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
            gen ty vars ((c, payload) :: caps) (size - 1) >|= fun body -> Scoped (c, init, body) );
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
        ]
        @ (if ty = TInt then
             [
               ( 2,
                 gen TInt vars caps smaller >>= fun a ->
                 gen TInt vars caps smaller >|= fun b -> Add (a, b) );
             ]
           else [])
        @ (match caps with
          | [] -> []
          | _ when ty = TUnit ->
              [
                ( 3,
                  oneof_list caps >>= fun (c, payload) ->
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
        @ (match caps with
          | (other, _) :: _ when ty = TUnit ->
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
        @ (match caps with
          | [] -> []
          | _ ->
              [
                (* a payload mismatch: put a value of another type (rejected) *)
                ( 1,
                  oneof_list caps >>= fun (c, payload) ->
                  oneof_list (List.filter (fun t -> t <> payload) base_types) >>= fun wrong ->
                  gen wrong vars caps smaller >>= fun v ->
                  gen ty vars caps smaller >|= fun rest -> Let (name "m", Put (Var c, v), rest) );
                (* a function taking the capability as a parameter, applied to it *)
                ( 2,
                  oneof_list caps >>= fun (c, payload) ->
                  let p = name "p" in
                  gen ty vars ((p, payload) :: caps) smaller >|= fun body ->
                  App (Lam (p, TCap (c, payload), body), Var c) );
                (* a function taking a thunk over the capability, applied to one *)
                ( 1,
                  oneof_list caps >>= fun (c, payload) ->
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
        match caps with
        | [] -> []
        | _ ->
            [
              ( 3,
                oneof_list caps >>= fun (c, payload) ->
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
