(** The CPS interpreter (plan W2.2-W2.5).

    Small-step machine over explicit continuation frames ([Value.frame]): [SEval] walks an
    expression, [SApply] delivers a value to the top frame. Because frames are data, W2.4's handlers
    slice the continuation into resumptions that are ordinary immutable lists — invoking one twice
    just reuses the list, which is what makes resumptions multi-shot (the stated reason this
    interpreter is CPS rather than host-recursive).

    Effects: applying a [VOp] performs the operation — the machine walks the continuation outward
    for the nearest [FHandle] whose handler covers the op's hash (deep handlers, spec §5.1/§7). The
    captured resumption is [inner frames ++ [that FHandle]], so a second perform inside the
    resumption is handled by the same handler. With no matching handler the op falls to the
    context's root handlers — the grants installed by the CLI's [--allow] flags — and otherwise the
    program dies with [Unhandled], which is the capability story at runtime.

    Store-backed terms ([Ref] of kind [Term]) load from the store on first use and memoize ({!ctx});
    constructors and ops resolve their metadata (name, arity, owning effect) from the store. Quote
    evaluation collects the payload's live splices (quasiquote level 0), evaluates them
    left-to-right, and substitutes each resulting [VCode] payload in place of its [(unquote e)]
    node. *)

open Value

type ctx = {
  store : Store.t;
  builtins : (Hash.t, Value.t) Hashtbl.t;
      (** term hash -> native value; consulted before the store so prelude markers get their native
          implementations (W2.6) *)
  memo : (Hash.t, Value.t) Hashtbl.t;  (** evaluated top-level terms, by member hash *)
  root_handlers : (Hash.t, Value.t list -> (Value.t, Runtime_err.t) result) Hashtbl.t;
      (** op hash -> granted native handler; shallow (the op resumes exactly once with the native
          result), installed only by explicit grants *)
}

(** [make_ctx store] builds a fresh evaluation context over [store]: empty builtin, memo, and
    root-handler tables. *)
let make_ctx store =
  {
    store;
    builtins = Hashtbl.create 64;
    memo = Hashtbl.create 64;
    root_handlers = Hashtbl.create 8;
  }

(* Internal control flow only; never escapes this module. *)
exception Rt of Runtime_err.t

(* Internal invariant violation: the store's role index disagrees with the declaration it
   points at. Never raised on well-formed stores. *)
exception Bug_inconsistent_store of string

let nth_or_bug what l i =
  match List.nth_opt l i with
  | Some x -> x
  | None -> raise (Bug_inconsistent_store (Printf.sprintf "%s ordinal %d out of range" what i))

let rt e = raise (Rt e)
let rt_type fmt = Printf.ksprintf (fun m -> rt (Runtime_err.Type_error m)) fmt
let rt_arity fmt = Printf.ksprintf (fun m -> rt (Runtime_err.Arity m)) fmt

(* ------------------------------------------------------------------ *)
(* Pattern matching (plan W2.3)                                        *)
(* ------------------------------------------------------------------ *)

let lit_matches (l : Kernel.lit) (v : Value.t) =
  match (l, v) with
  | Kernel.LInt a, VInt b -> a = b
  | Kernel.LReal a, VReal b ->
      (* align with canon: nan matches nan, and -0.0 matches +0.0 *)
      Float.compare a b = 0 || (a = 0.0 && b = 0.0)
  | Kernel.LText a, VText b -> String.equal a b
  | _ -> false

(** [match_pat v p env] extends [env] with [p]'s bindings if [v] matches, or returns [None].
    Patterns are resolved: a [PCon] with a [Named] constructor is an internal error. *)
let rec match_pat (v : Value.t) (p : Kernel.pat) (env : env) : env option =
  match (p.Kernel.it, v) with
  | Kernel.PWild, _ -> Some env
  | Kernel.PVar x, _ -> Some (Env.add x (ref v) env)
  | Kernel.PLit l, _ -> if lit_matches l v then Some env else None
  | Kernel.PCon (Kernel.Hashed con, ps), VCon { con = vcon; args; _ } ->
      if Hash.equal con vcon && List.length ps = List.length args then match_pats args ps env
      else None
  | Kernel.PCon (Kernel.Named n, _), _ ->
      rt (Runtime_err.Unresolved (Printf.sprintf "constructor pattern `%s`" n))
  | Kernel.PCon _, _ -> None
  | Kernel.PTuple ps, VTuple items ->
      if List.length ps = List.length items then match_pats items ps env else None
  | Kernel.PTuple _, _ -> None
  | Kernel.PAs (x, inner), _ ->
      Option.map (fun env -> Env.add x (ref v) env) (match_pat v inner env)

and match_pats vs ps env =
  List.fold_left2 (fun acc v p -> Option.bind acc (match_pat v p)) (Some env) vs ps

(* ------------------------------------------------------------------ *)
(* Store-backed references                                             *)
(* ------------------------------------------------------------------ *)

let locate ctx h =
  match Store.locate ctx.store h with
  | Ok l -> l
  | Error ds -> rt (Runtime_err.Unresolved (String.concat "; " (List.map Diag.to_string ds)))

(* Source-order member hashes of a defterm decl, for GroupRef. *)
let group_hashes (decl : Kernel.decl) : Hash.t array =
  match Canon.hash_decl decl with
  | Ok { Canon.named; _ } -> Array.of_list (List.map snd named)
  | Error ds -> rt (Runtime_err.Unresolved (String.concat "; " (List.map Diag.to_string ds)))

let con_value ctx h =
  match locate ctx h with
  | { Store.decl = { Kernel.it = Kernel.DefType { cons; _ }; _ }; role = Store.Constructor i; _ } ->
      let { Kernel.con_name; fields; _ } = nth_or_bug "constructor" cons i in
      let arity = List.length fields in
      if arity = 0 then VCon { con = h; name = con_name; args = [] }
      else VConstructor { con = h; name = con_name; arity }
  | _ -> rt_type "hash %s is not a constructor" (Hash.to_hex h)

let op_value ctx h =
  match locate ctx h with
  | {
   Store.decl = { Kernel.it = Kernel.DefEffect { ename; ops; _ }; _ };
   role = Store.Operation i;
   _;
  } ->
      let { Kernel.op_name; _ } = nth_or_bug "operation" ops i in
      VOp { op = h; name = op_name; effect_ = ename }
  | _ -> rt_type "hash %s is not an effect operation" (Hash.to_hex h)

(* ------------------------------------------------------------------ *)
(* Quote payloads (W2.5)                                               *)
(* ------------------------------------------------------------------ *)

(* Live splice expressions of a quote payload, depth-first left-to-right (quasiquote levels
   as in Kernel/Canon: nested quotes raise, unquotes lower, level-0 unquotes are live). *)
let rec live_splices ?(level = 0) (f : Form.t) : Kernel.expr list =
  if f.Form.head = "unquote" && level = 0 then
    match f.Form.args with
    | [ Form.F splice ] -> (
        match Kernel.expr_of_form splice with
        | Ok e -> [ e ]
        | Error ds -> rt (Runtime_err.Unresolved (String.concat "; " (List.map Diag.to_string ds))))
    | _ -> rt_type "malformed unquote in quote payload"
  else
    let level =
      match f.Form.head with "quote" -> level + 1 | "unquote" -> level - 1 | _ -> level
    in
    List.concat_map (function Form.F g -> live_splices ~level g | _ -> []) f.Form.args

(* Replace live unquote nodes with the next spliced payload, in the same traversal order as
   [live_splices]. Splice values must be VCode. *)
let substitute_splices (payload : Form.t) (values : Value.t list) : Form.t =
  let queue = ref values in
  let next () =
    match !queue with
    | v :: rest -> (
        queue := rest;
        match v with
        | VCode f -> f
        | v -> rt_type "unquote splice evaluated to %s, not code" (Value.show v))
    | [] -> rt_type "splice value queue exhausted (internal)"
  in
  let rec go ?(level = 0) (f : Form.t) : Form.t =
    if f.Form.head = "unquote" && level = 0 then next ()
    else
      let level =
        match f.Form.head with "quote" -> level + 1 | "unquote" -> level - 1 | _ -> level
      in
      {
        f with
        Form.args = List.map (function Form.F g -> Form.F (go ~level g) | a -> a) f.Form.args;
      }
  in
  go payload

(* Fresh scope marks (Racket-style sets of scopes, stubbed per plan W2.5): each quote
   evaluation stamps one fresh mark onto every node of the produced payload under the
   reserved [scopes] meta key. No resolution logic reads them yet; they just travel. *)
let scope_counter = ref 0

let stamp_scope_mark (payload : Form.t) : Form.t =
  incr scope_counter;
  let mark = Meta.Sym (Printf.sprintf "q%d" !scope_counter) in
  let rec go (f : Form.t) =
    let existing =
      match Meta.find Meta.key_scopes f.Form.meta with Some (Meta.List l) -> l | _ -> []
    in
    {
      f with
      Form.meta = Meta.add Meta.key_scopes (Meta.List (mark :: existing)) f.Form.meta;
      args = List.map (function Form.F g -> Form.F (go g) | a -> a) f.Form.args;
    }
  in
  go payload

(* ------------------------------------------------------------------ *)
(* The machine                                                         *)
(* ------------------------------------------------------------------ *)

type state = SEval of scope * Kernel.expr * kont | SApply of Value.t * kont

let handler_covers (h : handler) op = List.exists (fun (o, _) -> Hash.equal o op) h.hops

(** Perform an operation: walk the continuation outward for the nearest matching handler (deep
    semantics; the captured resumption is inner frames + that handler frame); fall back to root
    handlers (grants); otherwise raise [Unhandled]. *)
let perform ctx (op : Hash.t) ~name ~effect_ (args : Value.t list) (k : kont) : state =
  let rec split inner_rev = function
    | FHandle h :: outer when handler_covers h op ->
        let captured = List.rev (FHandle h :: inner_rev) in
        let { Kernel.params; resume; obody; _ } =
          match List.find_opt (fun (o, _) -> Hash.equal o op) h.hops with
          | Some (_, c) -> c
          | None -> assert false
        in
        if List.length params <> List.length args then
          rt_arity "op `%s` handled with %d parameter(s) but performed with %d argument(s)" name
            (List.length params) (List.length args);
        let env =
          match match_pats args params h.hscope.env with
          | Some env -> env
          | None -> rt (Runtime_err.Match_failure (Value.show (VTuple args)))
        in
        let env = Env.add resume (ref (VResume captured)) env in
        SEval ({ h.hscope with env }, obody, outer)
    | f :: outer -> split (f :: inner_rev) outer
    | [] -> (
        match Hashtbl.find_opt ctx.root_handlers op with
        | Some native -> ( match native args with Ok v -> SApply (v, k) | Error e -> rt e)
        | None -> rt (Runtime_err.Unhandled { effect_; op = name }))
  in
  split [] k

(** Apply a function-position value to fully evaluated arguments (uncurried, decision D5): closures,
    builtins, constructors, ops (perform), and resumptions. *)
let apply ctx (fn : Value.t) (args : Value.t list) (k : kont) : state =
  match fn with
  | VClosure { scope; params; body } ->
      if List.length params <> List.length args then
        rt_arity "closure of %d parameter(s) applied to %d argument(s)" (List.length params)
          (List.length args)
      else
        let env =
          match match_pats args params scope.env with
          | Some env -> env
          | None -> rt (Runtime_err.Match_failure (Value.show (VTuple args)))
        in
        SEval ({ scope with env }, body, k)
  | VBuiltin (_, native) -> ( match native args with Ok v -> SApply (v, k) | Error e -> rt e)
  | VConstructor { con; name; arity } ->
      if List.length args <> arity then
        rt_arity "constructor %s expects %d argument(s), got %d" name arity (List.length args)
      else SApply (VCon { con; name; args }, k)
  | VOp { op; name; effect_ } -> perform ctx op ~name ~effect_ args k
  | VResume frames -> (
      match args with
      | [ v ] -> SApply (v, frames @ k)
      | _ -> rt_arity "a resumption takes exactly one argument, got %d" (List.length args))
  | v -> rt_type "%s is not applicable" (Value.show v)

(** Resolve a store reference to a runtime value: builtins and memoized terms short-circuit; other
    terms load from the store and evaluate in an ISOLATED sub-run. Isolation is a soundness
    requirement (review finding): a top-level body's effects must not be captured by handlers around
    the referencing expression, or a handled branch's value could be memoized and leak past the
    handler's dynamic extent. A top-level body therefore either handles its own effects, uses
    granted root handlers, or dies with [Unhandled] at the referencing point. *)
let rec eval_ref ctx (h : Hash.t) (kind : Kernel.refkind) (k : kont) : state =
  match kind with
  | Kernel.Con -> SApply (con_value ctx h, k)
  | Kernel.Op -> SApply (op_value ctx h, k)
  | Kernel.Term -> (
      match Hashtbl.find_opt ctx.builtins h with
      | Some v -> SApply (v, k)
      | None -> (
          match Hashtbl.find_opt ctx.memo h with
          | Some v -> SApply (v, k)
          | None -> (
              match locate ctx h with
              | {
               Store.decl = { Kernel.it = Kernel.DefTerm bindings; _ } as decl;
               role = Store.Member i;
               _;
              } ->
                  let binding = nth_or_bug "member" bindings i in
                  let scope = { env = Env.empty; group = group_hashes decl } in
                  let v = run_state ctx (SEval (scope, binding.Kernel.value, [])) in
                  Hashtbl.replace ctx.memo h v;
                  SApply (v, k)
              | _ -> rt_type "hash %s is not a term" (Hash.to_hex h))))

(** One small step of the machine; [None] means the state is terminal ([SApply] with an empty
    continuation). Raises internal [Rt] on runtime errors ([run_expr] catches). *)
and step ctx (state : state) : state option =
  match state with
  | SEval (scope, e, k) -> (
      match e.Kernel.it with
      | Kernel.Lit (Kernel.LInt i) -> Some (SApply (VInt i, k))
      | Kernel.Lit (Kernel.LReal r) -> Some (SApply (VReal r, k))
      | Kernel.Lit (Kernel.LText s) -> Some (SApply (VText s, k))
      | Kernel.Var x -> (
          match Env.find_opt x scope.env with
          | Some cell -> Some (SApply (!cell, k))
          | None -> rt (Runtime_err.Unresolved (Printf.sprintf "variable `%s`" x)))
      | Kernel.Ref (h, kind) -> Some (eval_ref ctx h kind k)
      | Kernel.GroupRef i ->
          if i >= 0 && i < Array.length scope.group then
            Some (eval_ref ctx scope.group.(i) Kernel.Term k)
          else rt_type "groupref %d outside its group at runtime" i
      | Kernel.Lam (params, body) -> Some (SApply (VClosure { scope; params; body }, k))
      | Kernel.App (fn, args) -> Some (SEval (scope, fn, FAppFn { args; scope } :: k))
      | Kernel.Let { isrec = false; binder; value; body } ->
          Some (SEval (scope, value, FLet { binder; body; scope } :: k))
      | Kernel.Let { isrec = true; binder; value; body } -> (
          (* validation pinned the shape: binder is PVar, value is Lam; tie the knot with a
             mutable cell (plan W2.2) *)
          match (binder.Kernel.it, value.Kernel.it) with
          | Kernel.PVar x, Kernel.Lam (params, lam_body) ->
              let cell = ref Value.unit_v in
              let env = Env.add x cell scope.env in
              let scope' = { scope with env } in
              cell := VClosure { scope = scope'; params; body = lam_body };
              Some (SEval (scope', body, k))
          | _ -> rt_type "malformed let rec survived validation")
      | Kernel.Match (scrutinee, clauses) ->
          Some
            (SEval
               ( scope,
                 scrutinee,
                 FMatch { scrutinee_meta = scrutinee.Kernel.meta; clauses; scope } :: k ))
      | Kernel.Tuple [] -> Some (SApply (VTuple [], k))
      | Kernel.Tuple (e0 :: rest) ->
          Some (SEval (scope, e0, FTuple { done_rev = []; pending = rest; scope } :: k))
      | Kernel.Handle { body; ret = { rbinder; rbody; _ }; ops } ->
          let hops =
            List.map
              (fun (oc : Kernel.opclause) ->
                match oc.Kernel.op with
                | Kernel.Hashed h -> (h, oc)
                | Kernel.Named n -> rt (Runtime_err.Unresolved (Printf.sprintf "op clause `%s`" n)))
              ops
          in
          let handler = { hret = (rbinder, rbody); hops; hscope = scope } in
          Some (SEval (scope, body, FHandle handler :: k))
      | Kernel.Quote payload -> (
          match live_splices payload with
          | [] -> Some (SApply (VCode (stamp_scope_mark payload), k))
          | e0 :: rest ->
              Some
                (SEval (scope, e0, FQuote { payload; done_rev = []; pending = rest; scope } :: k)))
      | Kernel.Unquote _ -> rt_type "unquote outside quote reached runtime"
      | Kernel.Ann (subject, _) -> Some (SEval (scope, subject, k)))
  | SApply (v, []) ->
      ignore v;
      None (* terminal; run handles it *)
  | SApply (v, frame :: k) -> (
      match frame with
      | FAppFn { args = []; scope = _ } -> Some (apply ctx v [] k)
      | FAppFn { args = a0 :: rest; scope } ->
          Some (SEval (scope, a0, FAppArgs { fn = v; done_rev = []; pending = rest; scope } :: k))
      | FAppArgs { fn; done_rev; pending = []; scope = _ } ->
          Some (apply ctx fn (List.rev (v :: done_rev)) k)
      | FAppArgs { fn; done_rev; pending = e :: rest; scope } ->
          Some
            (SEval (scope, e, FAppArgs { fn; done_rev = v :: done_rev; pending = rest; scope } :: k))
      | FLet { binder; body; scope } -> (
          match match_pat v binder scope.env with
          | Some env -> Some (SEval ({ scope with env }, body, k))
          | None -> rt (Runtime_err.Match_failure (Value.show v)))
      | FMatch { clauses; scope; _ } ->
          let rec try_clauses = function
            | [] -> rt (Runtime_err.Match_failure (Value.show v))
            | { Kernel.cpat; cbody; _ } :: rest -> (
                match match_pat v cpat scope.env with
                | Some env -> SEval ({ scope with env }, cbody, k)
                | None -> try_clauses rest)
          in
          Some (try_clauses clauses)
      | FTuple { done_rev; pending = []; scope = _ } ->
          Some (SApply (VTuple (List.rev (v :: done_rev)), k))
      | FTuple { done_rev; pending = e :: rest; scope } ->
          Some (SEval (scope, e, FTuple { done_rev = v :: done_rev; pending = rest; scope } :: k))
      | FQuote { payload; done_rev; pending = []; scope = _ } ->
          let spliced = substitute_splices payload (List.rev (v :: done_rev)) in
          Some (SApply (VCode (stamp_scope_mark spliced), k))
      | FQuote { payload; done_rev; pending = e :: rest; scope } ->
          Some
            (SEval
               (scope, e, FQuote { payload; done_rev = v :: done_rev; pending = rest; scope } :: k))
      | FHandle { hret = rbinder, rbody; hscope; _ } -> (
          (* body finished normally: run the return clause in the handler's scope *)
          match match_pat v rbinder hscope.env with
          | Some env -> Some (SEval ({ hscope with env }, rbody, k))
          | None -> rt (Runtime_err.Match_failure (Value.show v))))

(** Drive a state to its terminal value (tail-recursive trampoline). *)
and run_state ctx state =
  match step ctx state with
  | Some next -> run_state ctx next
  | None -> ( match state with SApply (v, []) -> v | _ -> assert false)

(** [run_expr ctx e] evaluates a resolved expression to a value. *)
let run_expr ctx (e : Kernel.expr) : (Value.t, Runtime_err.t) result =
  let rec loop state =
    match step ctx state with
    | Some next -> loop next
    | None -> ( match state with SApply (v, []) -> v | _ -> assert false)
  in
  match loop (SEval (empty_scope, e, [])) with v -> Ok v | exception Rt e -> Error e

(** [call ctx fn args] applies an already-evaluated function value in a fresh continuation. Unused
    by M1 (the gated eval runs whole expressions via {!run_expr}); it exists for M3's native
    inference handlers, which must invoke resumption values from OCaml. *)
let call ctx (fn : Value.t) (args : Value.t list) : (Value.t, Runtime_err.t) result =
  match run_state ctx (apply ctx fn args []) with v -> Ok v | exception Rt e -> Error e
