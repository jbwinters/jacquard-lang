type bounds = { max_tasks : int; max_decisions : int }

let scheduler_version = "fifo-round-robin-v0"
let default_bounds = { max_tasks = 1024; max_decisions = 100_000 }

type outcome = {
  body : Value.t Concurrency_contract.task_result;
  root_error : Runtime_err.t option;
  aggregate : Value.t Scope_policy.aggregate;
  decisions : Concurrency_contract.decision list;
  trace : string;
  task_count : int;
  max_live : int;
  metrics_after_close : Structured_scope.metrics;
}

type proof = {
  decisions : Concurrency_contract.decision list;
  trace : string;
  task_count : int;
  max_live : int;
}

type global_resume =
  | Global_state of Eval.state
  | Global_awaiting of Structured_scope.handle * Value.t
  | Global_nested_wait of Value.t

type global_scope_run = {
  scope : (global_resume, Value.t) Structured_scope.t;
  body_handle : Structured_scope.handle;
  policy_controller : (global_resume, Value.t) Scope_policy.t;
  mutable children : Structured_scope.handle list;
  mutable seen_terminal : Structured_scope.handle list;
  mutable aggregate : Value.t Scope_policy.aggregate option;
  parent : global_parent option;
}

and global_parent = { parent_run : global_scope_run; parent_task : Structured_scope.handle }

module String_map = Map.Make (String)

type cache = { mutable entries : proof String_map.t }
type cache_status = Hit | Miss

let create_cache () = { entries = String_map.empty }

let hash_of_pinned name values =
  match Option.bind (List.assoc_opt name values) Hash.of_hex with
  | Some hash -> hash
  | None -> failwith ("Bug_round_robin: invalid pinned hash for " ^ name)

let spawn_hash = hash_of_pinned "async.spawn" Concurrency_contract.async_operation_hashes
let await_hash = hash_of_pinned "async.await" Concurrency_contract.async_operation_hashes
let cancel_hash = hash_of_pinned "async.cancel" Concurrency_contract.async_operation_hashes
let yield_hash = hash_of_pinned "async.yield" Concurrency_contract.async_operation_hashes

let done_hash =
  Option.get (Hash.of_hex "8bb29144a0570c1b4e6da9f9bb899b7938bb5eda078f5800a7acb24bb295a095")

let failed_hash =
  Option.get (Hash.of_hex "ce8613a28d881583c0239bd1f4d65156e0f28d48f12d61f246f386a8b3fb0934")

let cancelled_hash =
  Option.get (Hash.of_hex "b2bbe23f39ea5e437f838e3bf9cfd030f6916f1d236b48716097a502328de697")

let task_result_value = function
  | Concurrency_contract.Done value ->
      Value.VCon { con = done_hash; name = "done"; args = [ value ] }
  | Concurrency_contract.Failed message ->
      Value.VCon { con = failed_hash; name = "failed"; args = [ Value.VText message ] }
  | Concurrency_contract.Cancelled ->
      Value.VCon { con = cancelled_hash; name = "cancelled"; args = [] }

let runtime_of_diagnostics diagnostics =
  let message =
    String.concat "; " (List.map (fun diagnostic -> diagnostic.Diag.message) diagnostics)
  in
  if
    List.exists
      (fun diagnostic -> String.equal diagnostic.Diag.code Concurrency_contract.task_escape_code)
      diagnostics
  then Runtime_err.Invalid_task_handle message
  else Runtime_err.Scheduler_error message

let id_text id = Concurrency_contract.trace_task_id id

let result_text = function
  | Concurrency_contract.Done value -> "done(" ^ Value.show value ^ ")"
  | Concurrency_contract.Failed message -> Printf.sprintf "failed(%S)" message
  | Concurrency_contract.Cancelled -> "cancelled"

let zero_metrics =
  Structured_scope.{ open_scopes = 0; live_tasks = 0; runnable_tasks = 0; owned_resumes = 0 }

let run_state_global ctx ~policy ~bounds initial_state =
  if bounds.max_tasks <= 0 then Error (Runtime_err.Scheduler_error "task bound must be positive")
  else if bounds.max_decisions <= 0 then
    Error (Runtime_err.Scheduler_error "decision bound must be positive")
  else
    let ( let* ) = Result.bind in
    let* root_scope, root_body =
      Structured_scope.create ~body_resume:(Global_state initial_state)
      |> Result.map_error runtime_of_diagnostics
    in
    let make_scope_run scope body_handle parent scope_policy =
      let* policy_controller =
        Scope_policy.create ~policy:scope_policy scope ~children:[]
        |> Result.map_error runtime_of_diagnostics
      in
      Ok
        {
          scope;
          body_handle;
          policy_controller;
          children = [];
          seen_terminal = [];
          aggregate = None;
          parent;
        }
    in
    let* root_run = make_scope_run root_scope root_body None policy in
    let queue = ref [ (root_run, root_body) ] in
    let all_scopes = ref [ root_run ] in
    let decisions = ref [] in
    let events = ref [] in
    let task_errors = ref [] in
    let sequence = ref 0 in
    let current_decision = ref 0 in
    let terminal_ordinal = ref 0 in
    let task_count = ref 1 in
    let live_count = ref 1 in
    let max_live = ref 1 in
    let fatal_diagnostics = ref [] in
    let add_event event = events := event :: !events in
    let append runnable = queue := !queue @ runnable in
    let id run handle = Structured_scope.id run.scope handle in
    let same_handle run left right =
      match (id run left, id run right) with
      | Ok left, Ok right -> Concurrency_contract.compare_task_id left right = 0
      | _ -> false
    in
    let same_task (left_run, left) (right_run, right) =
      match (id left_run left, id right_run right) with
      | Ok left, Ok right -> Concurrency_contract.compare_task_id left right = 0
      | _ -> false
    in
    let remove_task run handle =
      queue := List.filter (fun queued -> not (same_task queued (run, handle))) !queue
    in
    let is_body run handle = same_handle run handle run.body_handle in
    let has_seen run handle = List.exists (same_handle run handle) run.seen_terminal in
    let drop _resume = () in
    let allocate_task () =
      if !task_count >= bounds.max_tasks then (
        let diagnostics =
          [ Diag.error ~code:"E0908" (Printf.sprintf "task bound %d exceeded" bounds.max_tasks) ]
        in
        fatal_diagnostics := diagnostics;
        Error diagnostics)
      else (
        incr task_count;
        incr live_count;
        max_live := max !max_live !live_count;
        Ok ())
    in
    let rec reject_results run body aggregate =
      let values =
        body
        ::
        (match aggregate with
        | Scope_policy.Fail_fast_result (Concurrency_contract.Done values) ->
            List.map (fun value -> Concurrency_contract.Done value) values
        | Scope_policy.Collect_result values -> values
        | Scope_policy.Fail_fast_result
            (Concurrency_contract.Failed _ | Concurrency_contract.Cancelled) ->
            [])
      in
      let rec reject = function
        | [] -> Ok ()
        | Concurrency_contract.Done value :: rest ->
            let* () =
              Eval.reject_task_escape ctx ~scope_path:(Structured_scope.scope_path run.scope) value
            in
            reject rest
        | (Concurrency_contract.Failed _ | Concurrency_contract.Cancelled) :: rest -> reject rest
      in
      reject values
    and resume_parent run result =
      match run.parent with
      | None -> Ok ()
      | Some { parent_run; parent_task } -> (
          let* parent_view = Structured_scope.inspect parent_run.scope parent_task in
          match parent_view.result with
          | Some _ -> Ok ()
          | None ->
              let* () = Structured_scope.wake_yielded parent_run.scope parent_task in
              let* owned = Structured_scope.checkout parent_run.scope parent_task in
              let continuation =
                match owned with
                | Global_nested_wait owned -> owned
                | Global_state _ | Global_awaiting _ ->
                    failwith "Bug_round_robin: nested parent owned the wrong continuation"
              in
              let next = Eval.apply_state ctx continuation [ task_result_value result ] in
              let* () =
                Structured_scope.suspend_yield parent_run.scope parent_task
                  ~resume:(Global_state next)
              in
              let* () = Structured_scope.wake_yielded parent_run.scope parent_task in
              append [ (parent_run, parent_task) ];
              Ok ())
    and maybe_finalize run =
      match run.aggregate with
      | Some _ -> Ok ()
      | None -> (
          let* body_view = Structured_scope.inspect run.scope run.body_handle in
          if
            Option.is_none body_view.result
            || not (List.for_all (fun child -> has_seen run child) run.children)
          then Ok ()
          else
            let body = Option.get body_view.result in
            let* aggregate = Scope_policy.finish run.policy_controller in
            let* () = reject_results run body aggregate in
            run.aggregate <- Some aggregate;
            match run.parent with
            | None -> Ok ()
            | Some _ ->
                let result =
                  match aggregate with
                  | Scope_policy.Fail_fast_result
                      ((Concurrency_contract.Failed _ | Concurrency_contract.Cancelled) as failure)
                    ->
                      failure
                  | Scope_policy.Fail_fast_result (Concurrency_contract.Done _)
                  | Scope_policy.Collect_result _ ->
                      body
                in
                let path = Structured_scope.scope_path run.scope in
                add_event
                  (Printf.sprintf "scope-complete path=%s result=%s"
                     (String.concat "/" (List.map string_of_int path))
                     (result_text result));
                resume_parent run result)
    and observe_terminal run handle =
      if has_seen run handle then maybe_finalize run
      else
        let* view = Structured_scope.inspect run.scope handle in
        match view.result with
        | None -> Ok ()
        | Some result ->
            run.seen_terminal <- handle :: run.seen_terminal;
            decr live_count;
            let* task_id = id run handle in
            add_event
              (Printf.sprintf "terminal task=%s result=%s" (id_text task_id) (result_text result));
            let* () =
              if is_body run handle then Ok ()
              else
                let decision = !current_decision in
                let ordinal = !terminal_ordinal in
                incr terminal_ordinal;
                add_event
                  (Printf.sprintf "policy-observe decision=%d ordinal=%d task=%s" decision ordinal
                     (id_text task_id));
                let* () =
                  Scope_policy.record_terminal run.policy_controller ~decision ~ordinal handle ~drop
                in
                append
                  (List.map
                     (fun awakened -> (run, awakened))
                     (Scope_policy.take_awakened run.policy_controller));
                Ok ()
            in
            let* () = observe_all_children run run.children in
            maybe_finalize run
    and observe_all_children run = function
      | [] -> Ok ()
      | child :: rest ->
          let* () = observe_terminal run child in
          observe_all_children run rest
    in
    let suspend_and_requeue run handle resume =
      let* () = Structured_scope.suspend_yield run.scope handle ~resume in
      let* () = Structured_scope.wake_yielded run.scope handle in
      append [ (run, handle) ];
      Ok ()
    in
    let state_for_awakened run = function
      | Global_state state -> Ok state
      | Global_awaiting (target, continuation) ->
          let* view = Structured_scope.inspect run.scope target in
          let* result =
            match view.result with
            | Some result -> Ok result
            | None -> Error [ Diag.error ~code:"E0908" "awakened await target is not terminal" ]
          in
          Ok (Eval.apply_state ctx continuation [ task_result_value result ])
      | Global_nested_wait _ ->
          Error [ Diag.error ~code:"E0908" "nested scope parent woke before scope completion" ]
    in
    let fail_task run handle error =
      task_errors := (run, handle, error) :: !task_errors;
      let* awakened = Structured_scope.fail run.scope handle (Runtime_err.to_string error) in
      append (List.map (fun awakened -> (run, awakened)) awakened);
      observe_terminal run handle
    in
    let finish_cancelled run handle awakened =
      remove_task run handle;
      append (List.map (fun awakened -> (run, awakened)) awakened);
      observe_terminal run handle
    in
    let route ?(error_of_diagnostics = runtime_of_diagnostics) run handle resume ~action ~continue =
      let* outcome = Structured_scope.route_effect run.scope ~task:handle ~resume ~drop ~action in
      match outcome with
      | Structured_scope.Effect_cancelled awakened -> finish_cancelled run handle awakened
      | Structured_scope.Effect_routed { resume; result = Ok value } -> continue resume value
      | Structured_scope.Effect_routed { result = Error diagnostics; _ } ->
          fail_task run handle (error_of_diagnostics diagnostics)
    in
    let step run handle state =
      Structured_scope.with_eval_task_context Task_capability.runtime ctx run.scope (fun () ->
          match Eval.run_state_capturing_once_routed ctx state with
          | Error error -> fail_task run handle error
          | Ok (Eval.OCValue value) ->
              let* awakened = Structured_scope.complete run.scope handle value in
              append (List.map (fun awakened -> (run, awakened)) awakened);
              observe_terminal run handle
          | Ok (Eval.OCOp { op; args; resume; _ }) when Hash.equal op spawn_hash -> (
              match args with
              | [ thunk ] ->
                  route run handle
                    (Global_awaiting (handle, resume))
                    ~action:(fun () ->
                      let* () = allocate_task () in
                      let child_state = Eval.apply_state ctx thunk [] in
                      let* child =
                        Structured_scope.spawn run.scope ~resume:(Global_state child_state)
                      in
                      let* () = Scope_policy.register_child run.policy_controller child in
                      run.children <- run.children @ [ child ];
                      Ok child)
                    ~continue:(fun owned child ->
                      let* parent_id = id run handle in
                      let* child_id = id run child in
                      let* child_value =
                        Structured_scope.task_value Task_capability.runtime run.scope child
                      in
                      let continuation =
                        match owned with
                        | Global_awaiting (_, continuation) -> continuation
                        | Global_state _ | Global_nested_wait _ -> assert false
                      in
                      let next = Eval.apply_state ctx continuation [ child_value ] in
                      let* () = suspend_and_requeue run handle (Global_state next) in
                      add_event
                        (Printf.sprintf "spawn parent=%s child=%s" (id_text parent_id)
                           (id_text child_id));
                      remove_task run handle;
                      append [ (run, child); (run, handle) ];
                      Ok ())
              | _ -> fail_task run handle (Runtime_err.Arity "async.spawn expects one thunk"))
          | Ok (Eval.OCOp { op; args; resume; _ }) when Hash.equal op await_hash -> (
              match args with
              | [ target_value ] -> (
                  let* target =
                    Structured_scope.task_handle Task_capability.runtime run.scope target_value
                  in
                  let token = Global_awaiting (target, resume) in
                  let* outcome =
                    Structured_scope.await_cooperatively run.scope ~waiter:handle ~target
                      ~resume:token ~drop
                  in
                  match outcome with
                  | Structured_scope.Await_cancelled awakened ->
                      finish_cancelled run handle awakened
                  | Structured_scope.Await_performed (Scheduler_core.Await_suspended, awakened) ->
                      append (List.map (fun awakened -> (run, awakened)) awakened);
                      let* waiter_id = id run handle in
                      let* target_id = id run target in
                      add_event
                        (Printf.sprintf "await waiter=%s target=%s blocked" (id_text waiter_id)
                           (id_text target_id));
                      Ok ()
                  | Structured_scope.Await_performed (Scheduler_core.Await_ready result, awakened)
                    ->
                      append (List.map (fun awakened -> (run, awakened)) awakened);
                      let next = Eval.apply_state ctx resume [ task_result_value result ] in
                      let* _ = Structured_scope.checkout run.scope handle in
                      suspend_and_requeue run handle (Global_state next)
                  | Structured_scope.Await_performed
                      (Scheduler_core.Await_deadlocked message, awakened) ->
                      append (List.map (fun awakened -> (run, awakened)) awakened);
                      add_event ("deadlock=" ^ Printf.sprintf "%S" message);
                      observe_all_children run run.children)
              | _ -> fail_task run handle (Runtime_err.Arity "async.await expects one Task"))
          | Ok (Eval.OCOp { op; args = []; resume; _ }) when Hash.equal op yield_hash -> (
              let* outcome =
                Structured_scope.yield_cooperatively run.scope ~task:handle
                  ~resume:(Global_awaiting (handle, resume))
                  ~drop
              in
              match outcome with
              | Structured_scope.Yield_cancelled awakened -> finish_cancelled run handle awakened
              | Structured_scope.Yield_suspended ->
                  let next = Eval.apply_state ctx resume [ Value.unit_v ] in
                  let* () = Structured_scope.wake_yielded run.scope handle in
                  let* _ = Structured_scope.checkout run.scope handle in
                  let* () = suspend_and_requeue run handle (Global_state next) in
                  let* task_id = id run handle in
                  add_event ("yield task=" ^ id_text task_id);
                  Ok ())
          | Ok (Eval.OCOp { op; args; resume; _ }) when Hash.equal op cancel_hash -> (
              match args with
              | [ target_value ] -> (
                  let* target =
                    Structured_scope.task_handle Task_capability.runtime run.scope target_value
                  in
                  let* outcome =
                    Structured_scope.cancel run.scope ~caller:handle ~target
                      ~resume:(Global_awaiting (target, resume))
                      ~drop
                  in
                  match outcome with
                  | Structured_scope.Cancel_caller_cancelled awakened ->
                      finish_cancelled run handle awakened
                  | Structured_scope.Cancel_continues { resume = owned; awakened } ->
                      append (List.map (fun awakened -> (run, awakened)) awakened);
                      let* target_view = Structured_scope.inspect run.scope target in
                      (match target_view.result with
                      | Some _ -> remove_task run target
                      | None -> ());
                      let continuation =
                        match owned with
                        | Global_awaiting (_, continuation) -> continuation
                        | Global_state _ | Global_nested_wait _ -> assert false
                      in
                      let next = Eval.apply_state ctx continuation [ Value.unit_v ] in
                      let* () = suspend_and_requeue run handle (Global_state next) in
                      let* caller_id = id run handle in
                      let* target_id = id run target in
                      add_event
                        (Printf.sprintf "cancel caller=%s target=%s" (id_text caller_id)
                           (id_text target_id));
                      observe_all_children run run.children)
              | _ -> fail_task run handle (Runtime_err.Arity "async.cancel expects one Task"))
          | Ok (Eval.OCOp { op; name = "async.scope"; args = [ body ]; resume })
            when Hash.equal op Concurrency_contract.scope_control_hash ->
              route run handle (Global_nested_wait resume)
                ~action:(fun () ->
                  let* () = allocate_task () in
                  let nested_state = Eval.apply_state ctx body [] in
                  let* nested_scope, nested_body =
                    Structured_scope.nest run.scope ~body_resume:(Global_state nested_state)
                  in
                  let parent = Some { parent_run = run; parent_task = handle } in
                  let* nested_run =
                    make_scope_run nested_scope nested_body parent Concurrency_contract.Fail_fast
                    |> Result.map_error (fun error ->
                        [ Diag.error ~code:"E0908" (Runtime_err.to_string error) ])
                  in
                  all_scopes := nested_run :: !all_scopes;
                  Ok nested_run)
                ~continue:(fun owned nested_run ->
                  let continuation =
                    match owned with
                    | Global_nested_wait continuation -> continuation
                    | Global_state _ | Global_awaiting _ -> assert false
                  in
                  let* () =
                    Structured_scope.suspend_yield run.scope handle
                      ~resume:(Global_nested_wait continuation)
                  in
                  add_event
                    (Printf.sprintf "scope-open parent=%s child=%s"
                       (String.concat "/"
                          (List.map string_of_int (Structured_scope.scope_path run.scope)))
                       (String.concat "/"
                          (List.map string_of_int (Structured_scope.scope_path nested_run.scope))));
                  append [ (nested_run, nested_run.body_handle) ];
                  Ok ())
          | Ok (Eval.OCOp { op; name; args; resume }) ->
              let routed_error = ref None in
              route run handle
                (Global_awaiting (handle, resume))
                ~error_of_diagnostics:(fun diagnostics ->
                  Option.value ~default:(runtime_of_diagnostics diagnostics) !routed_error)
                ~action:(fun () ->
                  match
                    Eval.dispatch_root_operation ctx ~resume ~op ~name ~effect_:"routed" args
                  with
                  | Ok value -> Ok value
                  | Error error ->
                      routed_error := Some error;
                      Error [ Diag.error ~code:"E0908" (Runtime_err.to_string error) ])
                ~continue:(fun owned value ->
                  let continuation =
                    match owned with
                    | Global_awaiting (_, continuation) -> continuation
                    | Global_state _ | Global_nested_wait _ -> assert false
                  in
                  suspend_and_requeue run handle
                    (Global_state (Eval.apply_state ctx continuation [ value ]))))
    in
    let rec drive () =
      match !queue with
      | [] -> Ok ()
      | _ when !sequence >= bounds.max_decisions ->
          Error [ Diag.error ~code:"E0908" "decision bound exceeded" ]
      | runnable ->
          let rec ids acc = function
            | [] -> Ok (List.rev acc)
            | (run, handle) :: rest ->
                let* task_id = id run handle in
                ids (task_id :: acc) rest
          in
          let* runnable_ids = ids [] runnable in
          let decision =
            Option.get (Concurrency_contract.decide_round_robin ~sequence:!sequence runnable_ids)
          in
          decisions := decision :: !decisions;
          add_event
            (Printf.sprintf "decision=%d runnable=[%s] chosen=%s" decision.sequence
               (String.concat "," (List.map id_text decision.runnable))
               (id_text decision.chosen));
          let chosen_run, chosen = List.hd runnable in
          queue := List.tl runnable;
          current_decision := decision.sequence;
          terminal_ordinal := 0;
          let* () =
            Structured_scope.with_eval_task_context Task_capability.runtime ctx chosen_run.scope
              (fun () ->
                let* owned = Structured_scope.checkout chosen_run.scope chosen in
                let* state = state_for_awakened chosen_run owned in
                step chosen_run chosen state)
          in
          incr sequence;
          drive ()
    in
    let protected =
      Structured_scope.protect root_scope ~drop
        ~escapes:(fun _ -> [])
        (fun _ ->
          let* () = drive () in
          let* () =
            match !fatal_diagnostics with [] -> Ok () | diagnostics -> Error diagnostics
          in
          let* () =
            List.fold_left
              (fun result run ->
                let* () = result in
                observe_all_children run run.children)
              (Ok ()) !all_scopes
          in
          let* body_view = Structured_scope.inspect root_scope root_body in
          let* body =
            match body_view.result with
            | Some body -> Ok body
            | None -> Error [ Diag.error ~code:"E0908" "root scope body did not terminate" ]
          in
          let* aggregate =
            match root_run.aggregate with
            | Some aggregate -> Ok aggregate
            | None -> Error [ Diag.error ~code:"E0908" "root scope did not drain" ]
          in
          let* () = reject_results root_run body aggregate in
          let root_error =
            List.find_map
              (fun (run, handle, error) ->
                if same_task (run, handle) (root_run, root_body) then Some error else None)
              !task_errors
          in
          Ok
            ( body,
              root_error,
              aggregate,
              List.rev !decisions,
              String.concat "\n" (List.rev !events) ^ "\n",
              !task_count,
              !max_live ))
    in
    let metrics_after_close = Structured_scope.metrics root_scope in
    if metrics_after_close <> zero_metrics then
      Error (Runtime_err.Scheduler_error "scope cleanup left nonzero ownership metrics")
    else
      match protected with
      | Error diagnostics -> Error (runtime_of_diagnostics diagnostics)
      | Ok (body, root_error, aggregate, decisions, trace, task_count, max_live) ->
          Ok
            {
              body;
              root_error;
              aggregate;
              decisions;
              trace;
              task_count;
              max_live;
              metrics_after_close;
            }

let run_state ctx ?(policy = Concurrency_contract.default_failure_policy) ?(bounds = default_bounds)
    initial_state =
  run_state_global ctx ~policy ~bounds initial_state

let run_expr ctx ?policy ?bounds expression =
  match run_state ctx ?policy ?bounds (Eval.expr_state expression) with
  | Error error -> Error error
  | Ok { root_error = Some error; _ } -> Error error
  | Ok { body = Concurrency_contract.Failed message; _ } ->
      Error (Runtime_err.Scheduler_error message)
  | Ok { body = Concurrency_contract.Cancelled; _ } ->
      Error (Runtime_err.Scheduler_error "root task was cancelled")
  | Ok
      {
        body = Concurrency_contract.Done _;
        aggregate = Scope_policy.Fail_fast_result (Concurrency_contract.Failed message);
        _;
      } ->
      Error (Runtime_err.Scheduler_error message)
  | Ok
      {
        body = Concurrency_contract.Done _;
        aggregate = Scope_policy.Fail_fast_result Concurrency_contract.Cancelled;
        _;
      } ->
      Error (Runtime_err.Scheduler_error "scope was cancelled")
  | Ok { body = Concurrency_contract.Done value; _ } -> Ok value

let run_call ctx ?policy ?bounds callable arguments =
  match run_state ctx ?policy ?bounds (Eval.apply_state ctx callable arguments) with
  | Error error -> Error error
  | Ok { root_error = Some error; _ } -> Error error
  | Ok { body = Concurrency_contract.Failed message; _ } ->
      Error (Runtime_err.Scheduler_error message)
  | Ok { body = Concurrency_contract.Cancelled; _ } ->
      Error (Runtime_err.Scheduler_error "root task was cancelled")
  | Ok { aggregate = Scope_policy.Fail_fast_result (Concurrency_contract.Failed message); _ } ->
      Error (Runtime_err.Scheduler_error message)
  | Ok { aggregate = Scope_policy.Fail_fast_result Concurrency_contract.Cancelled; _ } ->
      Error (Runtime_err.Scheduler_error "scope was cancelled")
  | Ok { body = Concurrency_contract.Done value; _ } -> Ok value

let policy_text = function Concurrency_contract.Fail_fast -> "fail-fast" | Collect -> "collect"

let proof_of (outcome : outcome) : proof =
  {
    decisions = outcome.decisions;
    trace = outcome.trace;
    task_count = outcome.task_count;
    max_live = outcome.max_live;
  }

let equal_proof left right =
  left.decisions = right.decisions
  && String.equal left.trace right.trace
  && left.task_count = right.task_count
  && left.max_live = right.max_live

let run_expr_cached cache ctx ?(policy = Concurrency_contract.default_failure_policy)
    ?(bounds = default_bounds) expression =
  match Canon.hash_expr expression with
  | Error diagnostics -> Error (runtime_of_diagnostics diagnostics)
  | Ok program_hash ->
      let key =
        String.concat ":"
          [
            Hash.to_hex program_hash;
            scheduler_version;
            policy_text policy;
            string_of_int bounds.max_tasks;
            string_of_int bounds.max_decisions;
          ]
      in
      Result.bind
        (run_state ctx ~policy ~bounds (Eval.expr_state expression))
        (fun outcome ->
          let proof = proof_of outcome in
          match String_map.find_opt key cache.entries with
          | None ->
              cache.entries <- String_map.add key proof cache.entries;
              Ok (outcome, Miss)
          | Some expected when equal_proof expected proof -> Ok (outcome, Hit)
          | Some _ ->
              Error
                (Runtime_err.Scheduler_error
                   "cached scheduler proof disagrees with a fresh run of the same identity"))
