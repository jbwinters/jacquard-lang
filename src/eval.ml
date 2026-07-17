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

module Physical_key = struct
  type t = Obj.t

  let equal = ( == )
  let hash value = Hashtbl.hash_param 1 1 value
end

module Physical_seen = Hashtbl.Make (Physical_key)

module Runtime_value_key = struct
  type t = Value.t

  let equal = ( == )

  (* Cache keys must not depend on addresses: the major GC may move blocks. A bounded breadth-first
     fingerprint keeps lookup constant-time while incorporating payload near the roots of persistent
     lists and maps, where a one-node generic hash sees only the common constructor shape. *)
  let hash root =
    let mix accumulator value =
      let accumulator = accumulator lxor value in
      accumulator * 65599 land max_int
    in
    let scalar accumulator value = mix accumulator (Hashtbl.hash value) in
    let finish value =
      let value = value lxor (value lsr 16) * 0x45d9f3b in
      let value = value lxor (value lsr 16) * 0x45d9f3b in
      value lxor (value lsr 16) land max_int
    in
    let rec prepend_bounded budget items pending =
      if budget = 0 then pending
      else
        match items with
        | [] -> pending
        | item :: rest -> item :: prepend_bounded (budget - 1) rest pending
    in
    let rec loop budget accumulator pending =
      match (budget, pending) with
      | 0, _ | _, [] -> finish accumulator
      | budget, value :: rest -> (
          let budget = budget - 1 in
          match value with
          | VInt value -> loop budget (scalar (mix accumulator 1) value) rest
          | VReal value -> loop budget (scalar (mix accumulator 2) value) rest
          | VText value -> loop budget (scalar (mix accumulator 3) value) rest
          | VHash value -> loop budget (scalar (mix accumulator 12) value) rest
          | VSecret _ -> loop budget (mix accumulator 13) rest
          | VTuple items -> loop budget (mix accumulator 4) (prepend_bounded budget items rest)
          | VCon { con; name; args } ->
              let accumulator = scalar (scalar (mix accumulator 5) con) name in
              loop budget accumulator (prepend_bounded budget args rest)
          | VConstructor { con; name; arity } ->
              loop budget (scalar (scalar (scalar (mix accumulator 6) con) name) arity) rest
          | VOp { op; name; effect_ } ->
              loop budget (scalar (scalar (scalar (mix accumulator 7) op) name) effect_) rest
          | VClosure _ -> loop budget (mix accumulator 8) rest
          | VBuiltin (name, _) -> loop budget (scalar (mix accumulator 9) name) rest
          | VTrustedBuiltin builtin ->
              loop budget (scalar (mix accumulator 9) (Trusted_builtin.name builtin)) rest
          | VCode payload ->
              let form_arg_fingerprint = function
                | Form.F form -> scalar 1 form.Form.head
                | Form.Int value -> scalar 2 value
                | Form.Real value -> scalar 3 value
                | Form.Text value -> scalar 4 value
                | Form.Sym value -> scalar 5 value
                | Form.Hash value -> scalar 6 value
              in
              let accumulator = scalar (mix accumulator 10) payload.Form.head in
              let accumulator =
                match payload.Form.args with
                | [] -> mix accumulator 0
                | first :: _ -> mix accumulator (form_arg_fingerprint first)
              in
              loop budget accumulator rest
          | VResume _ | VOnceResume _ -> loop budget (mix accumulator 11) rest
          | VTask _ -> loop budget (mix accumulator 12) rest)
    in
    loop 4 0 [ root ]
end

module Runtime_value_seen = Hashtbl.Make (Runtime_value_key)
module Physical_cache = Ephemeron.K1.Make (Runtime_value_key)

type mutable_graph_snapshot = {
  cells : (Value.t ref * Value.t) list;
  once_states : (Value.kont Once_state.t * bool) list;
  contains_task : bool;
      (** Task-bearing graphs are never trusted by an unchanged mutable snapshot: run/scope
          ownership must be revalidated at every memo/native return boundary. *)
}

type mutable_snapshot = { snapshot_root : Value.t; snapshot_graph : mutable_graph_snapshot }
type native_snapshot_entry = { snapshot : mutable_snapshot; mutable last_used : int }
type native_snapshot_lru = { entries : native_snapshot_entry option array; mutable clock : int }

type ctx = {
  store : Store.t;
  task_run : Task_handle.run;
      (** evaluator-lifetime owner for affine Once resumptions; scheduler Task runs are distinct *)
  mutable scheduler_task_run : Task_handle.run option;
      (** fresh run owner dynamically installed only by the private scheduler bridge *)
  mutable task_scope_path : int list;
      (** currently active structured scope. SC.3 has only the inert root scope; the scheduler task
          that introduces executable scopes will own updates to this private field *)
  builtins : (Hash.t, Value.t) Hashtbl.t;
      (** term hash -> native value; consulted before the store so prelude markers get their native
          implementations (W2.6) *)
  memo : (Hash.t, Value.t) Hashtbl.t;  (** evaluated top-level terms, by member hash *)
  evaluator_clean_memo : (Hash.t, Value.t) Hashtbl.t;
      (** evaluator-owned memo entries that passed the complete recovery guard. A hit is trusted
          only when [memo] still contains this exact physical value; entries inserted or replaced
          through the public memo table therefore remain untrusted. *)
  evaluator_mutable_snapshots : (Hash.t, mutable_snapshot) Hashtbl.t;
      (** exact memo root plus the reachable mutable cells and their validated contents *)
  native_mutable_snapshots : native_snapshot_lru;
      (** bounded physical-root LRU for mutable-capable native arguments *)
  root_handlers : (Hash.t, Value.t list -> (Value.t, Runtime_err.t) result) Hashtbl.t;
      (** op hash -> granted native handler; shallow (the op resumes exactly once with the native
          result), installed only by explicit grants *)
  mutable capture_ops : bool;
      (** when set (by {!run_state_capturing}), an op that reaches the root with no handler and no
          grant is CAPTURED — returned with its continuation — instead of dying [Unhandled]; this is
          how native inference drivers (M3) receive resumptions *)
  mutable capture_root_handlers : bool;
      (** scheduler-only mode: capture granted operations before invoking their root handlers *)
  mutable track_coverage : bool;
      (** coverage bookkeeping costs a hash-keyed table write per term reference — measured ~12% of
          a pure-recursion run (PF.2 phase 2). The run path never reads coverage, so the CLI turns
          tracking off there; the test runner (which reads it) leaves it on. *)
  mutable coverage : (Hash.t, unit) Hashtbl.t;
      (** semantic coverage (W6.8): every store TERM loaded through {!eval_ref} this run — populated
          on the memo-hit path too, so a second test exercising a term still counts it. The test
          runner swaps in a fresh table per test to get per-test sets. *)
  recovery_immutable_clean : unit Physical_cache.t;
      (** weak cache of immutable value containers already proven marker-free; closures and
          resumptions are never entered here because their environments can contain mutable cells *)
  recovery_static_clean : unit Physical_cache.t;
      (** weak cache recording that a closure's params/body or a resumption's frame AST has passed
          recovery validation. Mutable scopes and frame-held runtime values are never trusted by
          this cache. *)
  audit_context_id : int;
  mutable next_audit_run_id : int;
}

let next_audit_context_id = Atomic.make 0

(** [make_ctx store] builds a fresh evaluation context over [store]: empty builtin, memo, and
    root-handler tables. *)
let make_ctx store =
  {
    store;
    task_run = Task_handle.create_run ();
    scheduler_task_run = None;
    task_scope_path = [ 0 ];
    builtins = Hashtbl.create 64;
    memo = Hashtbl.create 64;
    evaluator_clean_memo = Hashtbl.create 64;
    evaluator_mutable_snapshots = Hashtbl.create 64;
    native_mutable_snapshots = { entries = Array.make 64 None; clock = 0 };
    root_handlers = Hashtbl.create 8;
    capture_ops = false;
    capture_root_handlers = false;
    track_coverage = true;
    coverage = Hashtbl.create 64;
    recovery_immutable_clean = Physical_cache.create 128;
    recovery_static_clean = Physical_cache.create 128;
    audit_context_id = Atomic.fetch_and_add next_audit_context_id 1;
    next_audit_run_id = 0;
  }

(** [store ctx] returns the immutable store handle used for name and declaration lookup. *)
let store ctx = ctx.store

(** [fresh_audit_run_id ctx] returns a deterministic, context-local sequence-owner identity. The
    private counter is not reachable from Jacquard code, and distinct evaluator contexts receive
    disjoint identity domains. *)
let fresh_audit_run_id ctx =
  let ordinal = ctx.next_audit_run_id in
  ctx.next_audit_run_id <- ordinal + 1;
  Hash.of_string
    (Printf.sprintf "jacquard-governance-audit-run-v0\000%d:%d" ctx.audit_context_id ordinal)

let current_task_run ctx = Option.value ctx.scheduler_task_run ~default:ctx.task_run

let with_scheduler_task_run _capability ctx ~run ~scope_path operation =
  let previous_run = ctx.scheduler_task_run in
  let previous_path = ctx.task_scope_path in
  ctx.scheduler_task_run <- Some run;
  ctx.task_scope_path <- scope_path;
  Fun.protect
    ~finally:(fun () ->
      ctx.scheduler_task_run <- previous_run;
      ctx.task_scope_path <- previous_path)
    operation

let task_message diagnostics =
  String.concat "; " (List.map (fun diagnostic -> diagnostic.Diag.message) diagnostics)

let foreign_evaluator_context kind =
  Runtime_err.Invalid_task_handle (Printf.sprintf "%s belongs to another evaluator run" kind)

(** [validate_task_value ctx] checks run and exact structured-scope ownership without scheduling.
    Non-Task, malformed, stale, foreign-run, and cross-scope values return E0907. *)
let validate_task_value ctx ~scope_path = function
  | VTask handle -> Task_handle.validate_scope ~run:(current_task_run ctx) ~scope_path handle
  | _ ->
      Error
        [
          Diag.error ~code:Concurrency_contract.task_escape_code
            "expected an opaque scheduler-owned Task handle";
        ]

let rec scope_prefix prefix path =
  match (prefix, path) with
  | [], _ -> true
  | _, [] -> false
  | expected :: prefix, actual :: path -> expected = actual && scope_prefix prefix path

(** [reject_task_escape] is the dynamic scope-boundary guard. It walks mutable closure environments
    and frame-held runtime values instead of checking only a returned value's outer constructor.
    Physical identity makes the walk terminate on recursive environments. *)
let reject_task_escape ctx ~scope_path root =
  let seen = Physical_seen.create 64 in
  let diagnostics = ref [] in
  let first_visit value =
    let key = Obj.repr value in
    if Obj.is_int key || Physical_seen.mem seen key then false
    else (
      Physical_seen.add seen key ();
      true)
  in
  let record_task handle =
    match Task_handle.validate_run ~run:(current_task_run ctx) handle with
    | Error task_diagnostics -> diagnostics := List.rev_append task_diagnostics !diagnostics
    | Ok id when scope_prefix scope_path id.scope_path ->
        diagnostics :=
          Diag.error ~code:Concurrency_contract.task_escape_code
            ~hint:"do not return or store a Task beyond its creating async.scope"
            (Concurrency_contract.task_escape_message ^ ": Task "
            ^ Concurrency_contract.trace_task_id id
            ^ " escaped its creating structured scope")
          :: !diagnostics
    | Ok _ -> ()
  in
  let rec value runtime_value =
    if first_visit runtime_value then
      match runtime_value with
      | VTask handle -> record_task handle
      | VTuple items | VCon { args = items; _ } -> List.iter value items
      | VClosure { scope = closure_scope; _ } -> scope closure_scope
      | VResume frames -> kont frames
      | VOnceResume state -> kont (Once_state.payload state)
      | VInt _ | VReal _ | VText _ | VHash _ | VSecret _ | VConstructor _ | VOp _ | VBuiltin _
      | VTrustedBuiltin _ | VCode _ ->
          ()
  and scope scope_value =
    if first_visit scope_value then Value.Env.iter (fun _ cell -> value !cell) scope_value.env
  and frame = function
    | FAppFn { scope = frame_scope; _ }
    | FLet { scope = frame_scope; _ }
    | FMatch { scope = frame_scope; _ } ->
        scope frame_scope
    | FAppArgs { fn; done_rev; scope = frame_scope; _ } ->
        value fn;
        List.iter value done_rev;
        scope frame_scope
    | FTuple { done_rev; scope = frame_scope; _ } | FQuote { done_rev; scope = frame_scope; _ } ->
        List.iter value done_rev;
        scope frame_scope
    | FHandle handler -> scope handler.hscope
  and kont frames = List.iter frame frames in
  value root;
  match List.rev !diagnostics with [] -> Ok () | found -> Error found

(** [register_root_handler ctx op handler] installs one explicitly granted root handler. Arguments,
    continuation state, callback mutation, and callback results are guarded at dispatch time. *)
let register_root_handler ctx op handler = Hashtbl.replace ctx.root_handlers op handler

(** [set_coverage_tracking ctx enabled] controls semantic term-reference collection. Disabling it
    avoids bookkeeping when callers will not inspect coverage. *)
let set_coverage_tracking ctx enabled = ctx.track_coverage <- enabled

(** [with_fresh_coverage ctx f] runs [f] with a fresh per-call coverage set, merges that set into
    the enclosing set even when [f] raises, restores the enclosing set, and returns the covered
    hashes. *)
let with_fresh_coverage ctx f =
  let outer = ctx.coverage in
  let mine = Hashtbl.create 64 in
  ctx.coverage <- mine;
  let result =
    Fun.protect
      ~finally:(fun () ->
        Hashtbl.iter (fun hash () -> Hashtbl.replace outer hash ()) mine;
        ctx.coverage <- outer)
      f
  in
  (result, Hashtbl.fold (fun hash () hashes -> hash :: hashes) mine [])

(* Internal control flow only; never escapes this module. *)
exception Rt of Runtime_err.t

(* Internal: carries a root-reaching op to the capturing runner. *)
exception
  Op_captured of {
    op : Hash.t;
    name : string;
    effect_ : string;
    mode : Kernel.op_mode;
    args : Value.t list;
    kont : Value.frame list;
  }

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

let locate ctx ~trusted h =
  match if trusted then Store.locate_internal ctx.store h else Store.locate ctx.store h with
  | Ok l -> l
  | Error ds -> rt (Runtime_err.Unresolved (String.concat "; " (List.map Diag.to_string ds)))

(* Source-order member hashes of a defterm decl, for GroupRef. *)
let group_hashes (decl : Kernel.decl) : Hash.t array =
  match Canon.hash_decl decl with
  | Ok { Canon.named; _ } -> Array.of_list (List.map snd named)
  | Error ds -> rt (Runtime_err.Unresolved (String.concat "; " (List.map Diag.to_string ds)))

let con_value ctx ~trusted h =
  if Concurrency_contract.is_task_private_hash h then
    rt
      (Runtime_err.Invalid_task_handle
         "the Task opaque carrier is scheduler-private and cannot be constructed");
  match locate ctx ~trusted h with
  | { Store.decl = { Kernel.it = Kernel.DefType { cons; _ }; _ }; role = Store.Constructor i; _ } ->
      let { Kernel.con_name; fields; _ } = nth_or_bug "constructor" cons i in
      let arity = List.length fields in
      if arity = 0 then VCon { con = h; name = con_name; args = [] }
      else VConstructor { con = h; name = con_name; arity }
  | _ -> rt_type "hash %s is not a constructor" (Hash.to_hex h)

let op_value ctx ~trusted h =
  match locate ctx ~trusted h with
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

(* Runtime environments can be cyclic through [let rec]. The scan returns whether a value contains
   mutable runtime edges, so only closure/resumption-free data containers enter the immutable cache.
   [static_trusted] skips AST/form portions already checked at a trusted boundary, but environment
   cells always restart complete validation because host code can replace their contents. *)
let scan_recovery_state ctx ~static_trusted (state : state) =
  let seen = Physical_seen.create 64 in
  let seen_values = Runtime_value_seen.create 64 in
  let first_visit value =
    let value = Obj.repr value in
    if Obj.is_int value || Physical_seen.mem seen value then false
    else (
      Physical_seen.add seen value ();
      true)
  in
  let marked () = rt_type "E1202: recovery holes are not valid input to evaluation" in
  let rec value ~static_trusted runtime_value =
    if Runtime_value_seen.mem seen_values runtime_value then true
    else
      let () = Runtime_value_seen.add seen_values runtime_value () in
      match runtime_value with
      | VInt _ | VReal _ | VText _ | VHash _ | VSecret _ | VConstructor _ | VOp _ | VBuiltin _
      | VTrustedBuiltin _ ->
          false
      | VTask handle -> (
          match
            Task_handle.validate_scope ~run:(current_task_run ctx) ~scope_path:ctx.task_scope_path
              handle
          with
          | Ok _ -> true
          | Error diagnostics -> rt (Runtime_err.Invalid_task_handle (task_message diagnostics)))
      | VCode payload ->
          if (not static_trusted) && Recovery_marker.form payload then marked ();
          false
      | (VTuple items | VCon { args = items; _ }) as container ->
          if Physical_cache.mem ctx.recovery_immutable_clean container then false
          else
            let mutable_edges =
              List.fold_left (fun found item -> value ~static_trusted item || found) false items
            in
            if not mutable_edges then
              Physical_cache.replace ctx.recovery_immutable_clean container ();
            mutable_edges
      | VClosure { scope = closure_scope; params; body } ->
          if
            (not static_trusted) && not (Physical_cache.mem ctx.recovery_static_clean runtime_value)
          then (
            if List.exists Recovery_marker.pat params || Recovery_marker.expr body then marked ();
            Physical_cache.replace ctx.recovery_static_clean runtime_value ());
          scope closure_scope;
          true
      | VResume frames ->
          let check_static =
            (not static_trusted) && not (Physical_cache.mem ctx.recovery_static_clean runtime_value)
          in
          kont ~check_static frames;
          if check_static then Physical_cache.replace ctx.recovery_static_clean runtime_value ();
          true
      | VOnceResume state ->
          if not (Once_state.owned_by ~owner:ctx.task_run state) then
            rt (foreign_evaluator_context "once resumption");
          let check_static =
            (not static_trusted) && not (Physical_cache.mem ctx.recovery_static_clean runtime_value)
          in
          kont ~check_static (Once_state.payload state);
          if check_static then Physical_cache.replace ctx.recovery_static_clean runtime_value ();
          true
  and scope scope_value =
    if first_visit scope_value then
      Value.Env.iter (fun _ cell -> ignore (value ~static_trusted:false !cell)) scope_value.env
  and frame ~check_static frame_value =
    match frame_value with
    | FAppFn { args; scope = frame_scope } ->
        if check_static && List.exists Recovery_marker.expr args then marked ();
        scope frame_scope
    | FAppArgs { fn; done_rev; pending; scope = frame_scope } ->
        if check_static && List.exists Recovery_marker.expr pending then marked ();
        ignore (value ~static_trusted fn);
        List.iter (fun item -> ignore (value ~static_trusted item)) done_rev;
        scope frame_scope
    | FLet { binder; body; scope = frame_scope } ->
        if check_static && (Recovery_marker.pat binder || Recovery_marker.expr body) then marked ();
        scope frame_scope
    | FMatch { scrutinee_meta; clauses; scope = frame_scope } ->
        if
          check_static
          && (Recovery_marker.marked_meta scrutinee_meta
             || List.exists
                  (fun clause ->
                    Recovery_marker.marked_meta clause.Kernel.cmeta
                    || Recovery_marker.pat clause.cpat || Recovery_marker.expr clause.cbody)
                  clauses)
        then marked ();
        scope frame_scope
    | FTuple { done_rev; pending; scope = frame_scope } ->
        if check_static && List.exists Recovery_marker.expr pending then marked ();
        List.iter (fun item -> ignore (value ~static_trusted item)) done_rev;
        scope frame_scope
    | FQuote { payload; done_rev; pending; scope = frame_scope } ->
        if check_static && (Recovery_marker.form payload || List.exists Recovery_marker.expr pending)
        then marked ();
        List.iter (fun item -> ignore (value ~static_trusted item)) done_rev;
        scope frame_scope
    | FHandle handler ->
        let binder, body = handler.hret in
        if
          check_static
          && (Recovery_marker.pat binder || Recovery_marker.expr body
             || List.exists
                  (fun (_, operation) ->
                    Recovery_marker.marked_meta operation.Kernel.ometa
                    || List.exists Recovery_marker.pat operation.params
                    || Recovery_marker.expr operation.obody)
                  handler.hops)
        then marked ();
        scope handler.hscope
  and kont ~check_static frames = List.iter (frame ~check_static) frames in
  match state with
  | SEval (state_scope, expression, frames) ->
      if (not static_trusted) && Recovery_marker.expr expression then marked ();
      scope state_scope;
      kont ~check_static:(not static_trusted) frames
  | SApply (result, frames) ->
      ignore (value ~static_trusted result);
      kont ~check_static:(not static_trusted) frames

let reject_recovery_state ctx state = scan_recovery_state ctx ~static_trusted:false state

(** [register_builtin ctx hash value] installs a native term implementation after rejecting any
    recovery-marked runtime graph. Custom callbacks remain guarded before and after every call. *)
let register_builtin ctx hash value =
  reject_recovery_state ctx (SApply (value, []));
  Hashtbl.replace ctx.builtins hash value

let rec needs_mutable_recheck ctx value =
  match value with
  | VInt _ | VReal _ | VText _ | VHash _ | VSecret _ | VConstructor _ | VOp _ | VBuiltin _
  | VTrustedBuiltin _ ->
      false
  | VTask handle -> (
      match
        Task_handle.validate_scope ~run:(current_task_run ctx) ~scope_path:ctx.task_scope_path
          handle
      with
      | Ok _ -> true
      | Error diagnostics -> rt (Runtime_err.Invalid_task_handle (task_message diagnostics)))
  | VCode payload ->
      if Recovery_marker.form payload then
        rt_type "E1202: recovery holes are not valid input to evaluation";
      false
  | VClosure { scope; params; body } ->
      if Value.Env.is_empty scope.env then (
        if not (Physical_cache.mem ctx.recovery_static_clean value) then (
          if List.exists Recovery_marker.pat params || Recovery_marker.expr body then
            rt_type "E1202: recovery holes are not valid input to evaluation";
          Physical_cache.replace ctx.recovery_static_clean value ());
        false)
      else true
  | VResume [] -> false
  | VResume (_ :: _) | VOnceResume _ -> true
  | (VTuple items | VCon { args = items; _ }) as container ->
      if Physical_cache.mem ctx.recovery_immutable_clean container then false
      else
        let mutable_edges = List.exists (needs_mutable_recheck ctx) items in
        if not mutable_edges then Physical_cache.replace ctx.recovery_immutable_clean container ();
        mutable_edges

let snapshot_mutable_graph root =
  let seen_values = Runtime_value_seen.create 16 in
  let seen_scopes = Physical_seen.create 16 in
  let seen_cells = Physical_seen.create 16 in
  let seen_once_states = Physical_seen.create 16 in
  let cells = ref [] in
  let once_states = ref [] in
  let contains_task = ref false in
  let first_visit seen value =
    let key = Obj.repr value in
    if Obj.is_int key || Physical_seen.mem seen key then false
    else (
      Physical_seen.add seen key ();
      true)
  in
  let rec value runtime_value =
    if not (Runtime_value_seen.mem seen_values runtime_value) then (
      Runtime_value_seen.add seen_values runtime_value ();
      match runtime_value with
      | VInt _ | VReal _ | VText _ | VHash _ | VSecret _ | VConstructor _ | VOp _ | VBuiltin _
      | VTrustedBuiltin _ | VCode _ ->
          ()
      | VTask _ -> contains_task := true
      | VTuple items | VCon { args = items; _ } -> List.iter value items
      | VClosure { scope = closure_scope; _ } -> scope closure_scope
      | VResume frames -> List.iter frame frames
      | VOnceResume state ->
          if first_visit seen_once_states state then
            once_states := (state, Once_state.snapshot state) :: !once_states;
          List.iter frame (Once_state.payload state))
  and scope scope_value =
    if first_visit seen_scopes scope_value then
      Value.Env.iter
        (fun _ cell ->
          if first_visit seen_cells cell then (
            let current = !cell in
            cells := (cell, current) :: !cells;
            value current))
        scope_value.env
  and frame = function
    | FAppFn { scope = frame_scope; _ }
    | FLet { scope = frame_scope; _ }
    | FMatch { scope = frame_scope; _ } ->
        scope frame_scope
    | FAppArgs { fn; done_rev; scope = frame_scope; _ } ->
        value fn;
        List.iter value done_rev;
        scope frame_scope
    | FTuple { done_rev; scope = frame_scope; _ } | FQuote { done_rev; scope = frame_scope; _ } ->
        List.iter value done_rev;
        scope frame_scope
    | FHandle handler -> scope handler.hscope
  in
  value root;
  { cells = !cells; once_states = !once_states; contains_task = !contains_task }

let make_mutable_snapshot ctx root =
  {
    snapshot_root = root;
    snapshot_graph =
      (if needs_mutable_recheck ctx root then snapshot_mutable_graph root
       else { cells = []; once_states = []; contains_task = false });
  }

let snapshot_unchanged snapshot =
  (not snapshot.contains_task)
  && List.for_all (fun (cell, captured) -> !cell == captured) snapshot.cells
  && List.for_all
       (fun (state, captured) -> Once_state.snapshot state = captured)
       snapshot.once_states

let atomic_non_task_value = function
  | VInt _ | VReal _ | VText _ | VHash _ | VSecret _ | VConstructor _ | VOp _ | VBuiltin _
  | VTrustedBuiltin _ ->
      true
  | VTuple [] | VCon { args = []; _ } -> true
  | VTask _
  | VTuple (_ :: _)
  | VCon { args = _ :: _; _ }
  | VClosure _ | VCode _ | VResume _ | VOnceResume _ ->
      false

let reject_recovery_result_value ctx root =
  let rec validate value =
    match value with
    | VInt _ | VReal _ | VText _ | VHash _ | VSecret _ | VConstructor _ | VOp _ | VBuiltin _
    | VTrustedBuiltin _ ->
        true
    | VTask handle -> (
        match
          Task_handle.validate_scope ~run:(current_task_run ctx) ~scope_path:ctx.task_scope_path
            handle
        with
        | Ok _ -> false
        | Error diagnostics -> rt (Runtime_err.Invalid_task_handle (task_message diagnostics)))
    | VCode payload ->
        if Recovery_marker.form payload then
          rt_type "E1202: recovery holes are not valid input to evaluation";
        true
    | VClosure _ | VResume _ | VOnceResume _ ->
        reject_recovery_state ctx (SApply (value, []));
        false
    | (VTuple items | VCon { args = items; _ }) as container ->
        if Physical_cache.mem ctx.recovery_immutable_clean container then true
        else
          let immutable = List.for_all validate items in
          if immutable then Physical_cache.replace ctx.recovery_immutable_clean container ();
          immutable
  in
  ignore (validate root)

(* Continuations reaching these boundaries are already validated. Scan newly introduced values with
   a fresh traversal so memo and native results cannot inherit stale trust. Environment cells belong
   to the guarded machine state; internal transitions only initialize the fresh [let rec] cell before
   its closure can escape. *)
let checked_result_state ctx value kont =
  if not (atomic_non_task_value value) then reject_recovery_result_value ctx value;
  SApply (value, kont)

let find_native_snapshot lru root =
  lru.clock <- lru.clock + 1;
  let rec find index =
    if index = Array.length lru.entries then -1
    else
      match lru.entries.(index) with
      | Some entry when entry.snapshot.snapshot_root == root ->
          entry.last_used <- lru.clock;
          index
      | Some _ | None -> find (index + 1)
  in
  find 0

let replace_native_snapshot ctx root index =
  let lru = ctx.native_mutable_snapshots in
  let index =
    if index >= 0 then index
    else
      let rec oldest current best_index best_age =
        if current = Array.length lru.entries then best_index
        else
          match lru.entries.(current) with
          | None -> current
          | Some entry ->
              if entry.last_used < best_age then oldest (current + 1) current entry.last_used
              else oldest (current + 1) best_index best_age
      in
      oldest 0 0 max_int
  in
  lru.entries.(index) <-
    Some
      {
        snapshot = { snapshot_root = root; snapshot_graph = snapshot_mutable_graph root };
        last_used = lru.clock;
      }

let prepare_native_argument ctx root =
  if needs_mutable_recheck ctx root then
    let index = find_native_snapshot ctx.native_mutable_snapshots root in
    if index < 0 then replace_native_snapshot ctx root index
    else
      let entry = Option.get ctx.native_mutable_snapshots.entries.(index) in
      if not (snapshot_unchanged entry.snapshot.snapshot_graph) then (
        reject_recovery_state ctx (SApply (root, []));
        replace_native_snapshot ctx root index)

let check_native_argument ctx root =
  if needs_mutable_recheck ctx root then
    let index = find_native_snapshot ctx.native_mutable_snapshots root in
    if index < 0 then (
      reject_recovery_state ctx (SApply (root, []));
      replace_native_snapshot ctx root index)
    else
      let entry = Option.get ctx.native_mutable_snapshots.entries.(index) in
      if not (snapshot_unchanged entry.snapshot.snapshot_graph) then (
        reject_recovery_state ctx (SApply (root, []));
        replace_native_snapshot ctx root index)

let invoke_untrusted_native ctx fn native args kont =
  let invocation_roots = [ fn; VTuple args; VResume kont ] in
  List.iter (prepare_native_argument ctx) invocation_roots;
  let result = native args in
  List.iter (check_native_argument ctx) invocation_roots;
  match result with Ok value -> checked_result_state ctx value kont | Error error -> rt error

let invoke_trusted_native ctx native args kont =
  match native args with Ok value -> checked_result_state ctx value kont | Error error -> rt error

let handler_covers (h : handler) op = List.exists (fun (o, _) -> Hash.equal o op) h.hops

(* Mode lookup is deliberately store-backed: the declaration hash owns the contract, and a mode
   change therefore changes both the op hash and the runtime behavior selected for its handler. *)
let op_mode ctx op =
  match locate ctx ~trusted:true op with
  | { Store.decl = { Kernel.it = Kernel.DefEffect { ops; _ }; _ }; role = Store.Operation i; _ } ->
      let { Kernel.op_mode; _ } = nth_or_bug "operation" ops i in
      op_mode
  | _ -> rt_type "hash %s is not an effect operation" (Hash.to_hex op)

(** Perform an operation: walk the continuation outward for the nearest matching handler (deep
    semantics; the captured resumption is inner frames + that handler frame); fall back to root
    handlers (grants); otherwise raise [Unhandled]. *)
let perform_unchecked ctx (op : Hash.t) ~name ~effect_ (args : Value.t list) (k : kont) : state =
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
        let resume_value =
          match op_mode ctx op with
          | Kernel.Multi -> VResume captured
          | Kernel.Once -> VOnceResume (Once_state.create ~owner:ctx.task_run captured)
        in
        let env = Env.add resume (ref resume_value) env in
        SEval ({ h.hscope with env }, obody, outer)
    | f :: outer -> split (f :: inner_rev) outer
    | [] -> (
        match Hashtbl.find_opt ctx.root_handlers op with
        | Some native when not ctx.capture_root_handlers ->
            invoke_untrusted_native ctx (VOp { op; name; effect_ }) native args k
        | Some _ | None ->
            if ctx.capture_ops then
              raise
                (Op_captured
                   { op; name; effect_; mode = op_mode ctx op; args; kont = List.rev inner_rev })
            else rt (Runtime_err.Unhandled { effect_; op = name }))
  in
  split [] k

(** Apply a function-position value to fully evaluated arguments (uncurried, decision D5): closures,
    builtins, constructors, ops (perform), and resumptions. *)
let apply_unchecked ctx (fn : Value.t) (args : Value.t list) (k : kont) : state =
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
  | VBuiltin (_, native) as fn -> invoke_untrusted_native ctx fn native args k
  | VTrustedBuiltin builtin when String.equal (Trusted_builtin.name builtin) "async.scope-v0" -> (
      match args with
      | [ _body ] when ctx.capture_ops ->
          raise
            (Op_captured
               {
                 op = Concurrency_contract.scope_control_hash;
                 name = "async.scope";
                 effect_ = "Async";
                 mode = Kernel.Once;
                 args;
                 kont = k;
               })
      | [ _ ] -> rt (Runtime_err.Unhandled { effect_ = "Async"; op = "async.scope" })
      | _ -> rt_arity "async.scope expects one thunk, got %d" (List.length args))
  | VTrustedBuiltin builtin -> invoke_trusted_native ctx (Trusted_builtin.invoke builtin) args k
  | VConstructor { con; name; arity } ->
      if List.length args <> arity then
        rt_arity "constructor %s expects %d argument(s), got %d" name arity (List.length args)
      else SApply (VCon { con; name; args }, k)
  | VOp { op; name; effect_ } -> perform_unchecked ctx op ~name ~effect_ args k
  | VResume frames -> (
      match args with
      | [ v ] -> SApply (v, frames @ k)
      | _ -> rt_arity "a resumption takes exactly one argument, got %d" (List.length args))
  | VOnceResume once -> (
      match args with
      | [ v ] -> (
          match Once_state.consume once with
          | Some frames -> SApply (v, frames @ k)
          | None -> rt Runtime_err.Once_resumed_twice)
      | _ -> rt_arity "a resumption takes exactly one argument, got %d" (List.length args))
  | v -> rt_type "%s is not applicable" (Value.show v)

(** [apply ctx fn args k] validates all reachable runtime payloads before invoking native code or
    performing an operation. Machine transitions use [apply_unchecked] after their initial state has
    passed the same guard. *)
let apply ctx fn args k =
  reject_recovery_state ctx (SApply (VTuple (fn :: args), k));
  apply_unchecked ctx fn args k

(** Resolve a store reference to a runtime value: builtins and memoized terms short-circuit; other
    terms load from the store and evaluate in an ISOLATED sub-run. Isolation is a soundness
    requirement (review finding): a top-level body's effects must not be captured by handlers around
    the referencing expression, or a handled branch's value could be memoized and leak past the
    handler's dynamic extent. A top-level body therefore either handles its own effects, uses
    granted root handlers, or dies with [Unhandled] at the referencing point. *)
let rec eval_ref ctx ~trusted (h : Hash.t) (kind : Kernel.refkind) (k : kont) : state =
  match kind with
  | Kernel.Con -> SApply (con_value ctx ~trusted h, k)
  | Kernel.Op -> SApply (op_value ctx ~trusted h, k)
  | Kernel.Term -> (
      (* A native registration is an implementation override, not public reachability. Source
         references must cross [Store.locate] before builtin/memo shortcuts; only evaluation of an
         already-resolved stored body may use a hidden marker hash. *)
      if not trusted then ignore (locate ctx ~trusted:false h);
      if ctx.track_coverage then Hashtbl.replace ctx.coverage h ();
      match Hashtbl.find_opt ctx.builtins h with
      | Some v -> checked_result_state ctx v k
      | None -> (
          match Hashtbl.find_opt ctx.memo h with
          | Some v -> (
              match Hashtbl.find_opt ctx.evaluator_clean_memo h with
              | Some clean when clean == v -> (
                  match Hashtbl.find_opt ctx.evaluator_mutable_snapshots h with
                  | Some snapshot
                    when snapshot.snapshot_root == v && snapshot_unchanged snapshot.snapshot_graph
                    ->
                      SApply (v, k)
                  | Some _ | None ->
                      let next = checked_result_state ctx v k in
                      Hashtbl.replace ctx.evaluator_mutable_snapshots h
                        (make_mutable_snapshot ctx v);
                      next)
              | Some _ | None -> checked_result_state ctx v k)
          | None -> (
              match locate ctx ~trusted h with
              | {
               Store.decl = { Kernel.it = Kernel.DefTerm bindings; _ } as decl;
               role = Store.Member i;
               _;
              } ->
                  let binding = nth_or_bug "member" bindings i in
                  let scope =
                    { env = Env.empty; group = group_hashes decl; trusted_store_refs = true }
                  in
                  (* capture is disabled inside the isolated sub-run: an op escaping a
                     top-level body must die loudly (Unhandled) rather than be captured
                     with a truncated continuation (review finding; E0815 makes this
                     unreachable for checked programs, this is the belt to its braces) *)
                  let initial = SEval (scope, binding.Kernel.value, []) in
                  reject_recovery_state ctx initial;
                  let saved_capture = ctx.capture_ops in
                  ctx.capture_ops <- false;
                  let v =
                    Fun.protect
                      ~finally:(fun () -> ctx.capture_ops <- saved_capture)
                      (fun () -> run_state_unchecked ctx initial)
                  in
                  let next = checked_result_state ctx v k in
                  (* The isolated run has completed all closure construction and [let rec] knot
                     tying, and [checked_result_state] has traversed the finished graph. Evaluator
                     transitions never mutate a memoized graph after this point. Record ownership
                     only after publishing the exact guarded value to the public memo table. *)
                  Hashtbl.replace ctx.memo h v;
                  Hashtbl.replace ctx.evaluator_clean_memo h v;
                  Hashtbl.replace ctx.evaluator_mutable_snapshots h (make_mutable_snapshot ctx v);
                  next
              | _ -> rt_type "hash %s is not a term" (Hash.to_hex h))))

(** One small step of the machine; [None] means the state is terminal ([SApply] with an empty
    continuation). Raises internal [Rt] on runtime errors ([run_expr] catches). *)
and step_unchecked ctx (state : state) : state option =
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
      | Kernel.Ref (h, kind) -> Some (eval_ref ctx ~trusted:scope.trusted_store_refs h kind k)
      | Kernel.GroupRef i ->
          if i >= 0 && i < Array.length scope.group then
            Some (eval_ref ctx ~trusted:scope.trusted_store_refs scope.group.(i) Kernel.Term k)
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
      | FAppFn { args = []; scope = _ } -> Some (apply_unchecked ctx v [] k)
      | FAppFn { args = a0 :: rest; scope } ->
          Some (SEval (scope, a0, FAppArgs { fn = v; done_rev = []; pending = rest; scope } :: k))
      | FAppArgs { fn; done_rev; pending = []; scope = _ } ->
          Some (apply_unchecked ctx fn (List.rev (v :: done_rev)) k)
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

(** Drive a validated state to its terminal value (tail-recursive trampoline). Internal transitions
    only rearrange validated payloads or tie a fresh recursive cell; native and untrusted memo
    boundaries validate fresh values before constructing their result states. *)
and run_state_unchecked ctx state =
  match step_unchecked ctx state with
  | Some next -> run_state_unchecked ctx next
  | None -> (
      match state with
      | SApply (v, []) ->
          if not (atomic_non_task_value v) then reject_recovery_result_value ctx v;
          v
      | _ -> assert false)

(** [run_state ctx state] validates the complete runtime graph before driving it. Runtime blocks are
    visited by physical identity so recursive closure environments terminate safely. *)
let run_state ctx state =
  reject_recovery_state ctx state;
  run_state_unchecked ctx state

(** [run_expr ctx e] evaluates a resolved expression to a value. *)
let run_expr ctx (e : Kernel.expr) : (Value.t, Runtime_err.t) result =
  match run_state ctx (SEval (empty_scope, e, [])) with v -> Ok v | exception Rt e -> Error e

type captured_kont = Multi_kont of ctx * Value.frame list | Once_kont of ctx * Value.t

type capture =
  | CValue of Value.t
  | COp of { op : Hash.t; name : string; args : Value.t list; kont : captured_kont }
      (** An unhandled, ungranted op reached the root. [Multi_kont] exposes immutable frames for
          algorithms that deliberately branch; [Once_kont] contains an opaque affine resumption
          whose budget cannot be recreated from this API. *)

(** [validate_state ctx state] checks a complete state for recovery markers without executing it. *)
let validate_state ctx state =
  match reject_recovery_state ctx state with () -> Ok () | exception Rt error -> Error error

type validated_state = Validated_state of ctx * state * mutable_graph_snapshot option
type validated_kont = Validated_kont of ctx * Value.frame list

type validated_captured_kont =
  | Validated_multi_kont of validated_kont
  | Validated_once_kont of ctx * Value.t

type validated_capture =
  | VCValue of Value.t
  | VCOp of { op : Hash.t; name : string; args : Value.t list; kont : validated_captured_kont }

(** [validate_state_once ctx state] validates a complete externally supplied state and seals it for
    repeated capture runs. The abstract result cannot be forged by library clients. *)
let validate_state_once ctx state =
  match validate_state ctx state with
  | Ok () ->
      let root =
        match state with
        | SEval (scope, expression, kont) ->
            VTuple [ VClosure { scope; params = []; body = expression }; VResume kont ]
        | SApply (value, kont) -> VTuple [ value; VResume kont ]
      in
      Ok (Validated_state (ctx, state, Some (snapshot_mutable_graph root)))
  | Error error -> Error error

(** Restore an initial validated state before one semantically independent execution. Immutable
    syntax and values remain shared; mutable cells in the state and evaluator-owned memo graph are
    reset to their validated snapshots. *)
let fresh_validated_state ctx (Validated_state (owner, state, initial_graph) as validated) =
  if owner != ctx then validated
  else
    let restore graph = List.iter (fun (cell, value) -> cell := value) graph.cells in
    Option.iter restore initial_graph;
    Hashtbl.iter (fun _ snapshot -> restore snapshot.snapshot_graph) ctx.evaluator_mutable_snapshots;
    Validated_state (owner, state, None)

(** [run_state_capturing_trusted ctx state] captures like {!run_state_capturing} without scanning
    [state] first. The caller must have validated the immutable initial state and must only supply
    states derived from evaluator transitions; memo and native result guards remain active. *)
let run_state_capturing_trusted ?(capture_root_handlers = false) ctx (state : state) :
    (capture, Runtime_err.t) result =
  let saved = ctx.capture_ops in
  let saved_root = ctx.capture_root_handlers in
  ctx.capture_ops <- true;
  ctx.capture_root_handlers <- capture_root_handlers;
  Fun.protect
    ~finally:(fun () ->
      ctx.capture_ops <- saved;
      ctx.capture_root_handlers <- saved_root)
    (fun () ->
      match run_state_unchecked ctx state with
      | v -> Ok (CValue v)
      | exception Op_captured { op; name; mode; args; kont; _ } ->
          (* Captured arguments are already inside the validated machine graph. Any value newly
             introduced by a host callback crossed [checked_result_state] before it could become an
             operation argument, so rescanning here would duplicate the boundary check on every
             inference sample. *)
          let kont =
            match mode with
            | Kernel.Multi -> Multi_kont (ctx, kont)
            | Kernel.Once ->
                Once_kont (ctx, VOnceResume (Once_state.create ~owner:ctx.task_run kont))
          in
          Ok (COp { op; name; args; kont })
      | exception Rt e -> Error e)

(** [run_validated_state_capturing ctx state] captures a previously validated state without
    rescanning its immutable syntax. Native and memo result guards remain active. *)
let run_validated_state_capturing ctx (Validated_state (owner, state, _)) =
  if owner != ctx then Error (foreign_evaluator_context "validated state")
  else
    match run_state_capturing_trusted ctx state with
    | Ok (CValue value) -> Ok (VCValue value)
    | Ok (COp { op; name; args; kont = Multi_kont (owner, kont) }) ->
        Ok (VCOp { op; name; args; kont = Validated_multi_kont (Validated_kont (owner, kont)) })
    | Ok (COp { op; name; args; kont = Once_kont (owner, resume) }) ->
        Ok (VCOp { op; name; args; kont = Validated_once_kont (owner, resume) })
    | Error error -> Error error

(** [resume_validated_state ctx kont value] seals a state derived from a captured continuation. Only
    the newly introduced value needs validation because [kont] came from a validated run. *)
let resume_validated_state ctx kont value =
  match kont with
  | Validated_multi_kont (Validated_kont (owner, frames)) -> (
      if owner != ctx then Error (foreign_evaluator_context "validated continuation")
      else
        match checked_result_state ctx value frames with
        | state -> Ok (Validated_state (owner, state, None))
        | exception Rt error -> Error error)
  | Validated_once_kont (owner, resume) -> (
      if owner != ctx then Error (foreign_evaluator_context "validated continuation")
      else
        match apply ctx resume [ value ] [] with
        | state -> Ok (Validated_state (owner, state, None))
        | exception Rt error -> Error error)

(** [run_state_capturing ctx state] drives [state] to completion, but instead of dying on an
    unhandled op it returns the op with its continuation ({!COp}). Used by native inference drivers
    (M3); nested [run_state] sub-runs (store-term isolation) still die [Unhandled], which the
    checker's E0815 makes unreachable for checked programs. *)
let run_state_capturing ctx (state : state) : (capture, Runtime_err.t) result =
  match validate_state ctx state with
  | Error error -> Error error
  | Ok () -> run_state_capturing_trusted ctx state

type once_capture =
  | OCValue of Value.t
  | OCOp of { op : Hash.t; name : string; args : Value.t list; resume : Value.t }

(** [run_state_capturing_once ctx state] is the EL.0 low-level once-capture boundary. A root op's
    actual continuation is sealed inside an opaque affine token before it crosses the public API;
    clients cannot extract or rewrap its frames to mint a second budget. *)
let run_state_capturing_once ctx state =
  match run_state_capturing ctx state with
  | Ok (CValue value) -> Ok (OCValue value)
  | Ok (COp { op; name; args; kont = Multi_kont (owner, kont) }) ->
      Ok
        (OCOp
           { op; name; args; resume = VOnceResume (Once_state.create ~owner:owner.task_run kont) })
  | Ok (COp { op; name; args; kont = Once_kont (_, resume) }) ->
      Ok (OCOp { op; name; args; resume })
  | Error error -> Error error

let run_state_capturing_once_routed ctx state =
  match validate_state ctx state with
  | Error error -> Error error
  | Ok () -> (
      match run_state_capturing_trusted ~capture_root_handlers:true ctx state with
      | Ok (CValue value) -> Ok (OCValue value)
      | Ok (COp { op; name; args; kont = Multi_kont (owner, kont) }) ->
          Ok
            (OCOp
               {
                 op;
                 name;
                 args;
                 resume = VOnceResume (Once_state.create ~owner:owner.task_run kont);
               })
      | Ok (COp { op; name; args; kont = Once_kont (_, resume) }) ->
          Ok (OCOp { op; name; args; resume })
      | Error error -> Error error)

let dispatch_root_operation ctx ~resume ~op ~name ~effect_ args =
  let effect_ =
    match locate ctx ~trusted:true op with
    | { Store.decl = { Kernel.it = Kernel.DefEffect { ename; _ }; _ }; role = Store.Operation _; _ }
      ->
        ename
    | _ -> effect_
  in
  match Hashtbl.find_opt ctx.root_handlers op with
  | None -> Error (Runtime_err.Unhandled { effect_; op = name })
  | Some native -> (
      try
        let roots = [ VOp { op; name; effect_ }; VTuple args; resume ] in
        List.iter (prepare_native_argument ctx) roots;
        let result = native args in
        List.iter (check_native_argument ctx) roots;
        match result with
        | Ok value ->
            if not (atomic_non_task_value value) then reject_recovery_result_value ctx value;
            Ok value
        | Error error -> Error error
      with Rt error -> Error error)

(** [resume_captured_state ctx kont value] constructs the state that resumes a root capture. Multi
    continuations remain reusable; applying a Once token consumes its single budget and a later call
    reports E0906. Newly introduced values are recovery-validated at this boundary. *)
let resume_captured_state ctx kont value =
  match kont with
  | Multi_kont (owner, frames) -> (
      if owner != ctx then Error (foreign_evaluator_context "captured continuation")
      else
        match checked_result_state ctx value frames with
        | state -> Ok state
        | exception Rt error -> Error error)
  | Once_kont (owner, resume) -> (
      if owner != ctx then Error (foreign_evaluator_context "captured continuation")
      else
        match apply ctx resume [ value ] [] with
        | state -> Ok state
        | exception Rt error -> Error error)

(** [resume_state kont v] is the state that delivers [v] to a captured continuation. *)
let resume_state (kont : Value.frame list) (v : Value.t) : state = SApply (v, kont)

(** [apply_state ctx fn args] is the state that applies [fn] (used to start a model thunk). *)
let apply_state ctx (fn : Value.t) (args : Value.t list) : state = apply ctx fn args []

(** [expr_state e] is the state that evaluates a resolved expression from scratch. *)
let expr_state (e : Kernel.expr) : state = SEval (empty_scope, e, [])

(** [call ctx fn args] applies an already-evaluated function value in a fresh continuation. Unused
    by M1 (the gated eval runs whole expressions via {!run_expr}); it exists for M3's native
    inference handlers, which must invoke resumption values from OCaml. *)
let call ctx (fn : Value.t) (args : Value.t list) : (Value.t, Runtime_err.t) result =
  match run_state ctx (apply ctx fn args []) with v -> Ok v | exception Rt e -> Error e
