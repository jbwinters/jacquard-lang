type handle = Scheduler_core.handle
type exit_reason = Normal | Aborted | Raised
type metrics = { open_scopes : int; live_tasks : int; runnable_tasks : int; owned_resumes : int }
type 'resume boundary_outcome = Boundary_continue of 'resume | Boundary_cancelled of handle list

type 'value cooperative_await_outcome =
  | Await_performed of 'value Scheduler_core.await_outcome * handle list
  | Await_cancelled of handle list

type yield_outcome = Yield_suspended | Yield_cancelled of handle list

type ('resume, 'value) routed_effect_outcome =
  | Effect_routed of { resume : 'resume; result : ('value, Diag.t list) result }
  | Effect_cancelled of handle list

type 'resume cancel_outcome =
  | Cancel_continues of { resume : 'resume; awakened : handle list }
  | Cancel_caller_cancelled of handle list

type ('resume, 'value) t = {
  scheduler : ('resume, 'value) Scheduler_core.t;
  mutable next_nested : int;
  mutable children : ('resume, 'value) t list;
  mutable closed : bool;
}

let escape_diagnostic detail =
  Diag.error ~code:Concurrency_contract.task_escape_code
    ~hint:"do not return or store a Task beyond its creating async.scope"
    (Concurrency_contract.task_escape_message ^ ": " ^ detail)

let closed_error () = Error [ escape_diagnostic "the handle's structured scope is already closed" ]
let ensure_open scope operation = if scope.closed then closed_error () else operation ()

let drop_all drop resumes =
  let first_exception = ref None in
  List.iter
    (fun resume ->
      match drop resume with
      | () -> ()
      | exception exn -> if Option.is_none !first_exception then first_exception := Some exn)
    resumes;
  Option.iter raise !first_exception

let make_root scheduler = { scheduler; next_nested = 1; children = []; closed = false }

let create ~body_resume =
  Result.map
    (fun (scheduler, body) -> (make_root scheduler, body))
    (Scheduler_core.create ~scope_path:[ 0 ] ~body_resume)

let scope_path scope = Scheduler_core.scope_path scope.scheduler

let with_eval_task_context capability ctx scope operation =
  Eval.with_scheduler_task_run capability ctx
    ~run:(Scheduler_core.task_run capability scope.scheduler)
    ~scope_path:(scope_path scope) operation

let nest parent ~body_resume =
  ensure_open parent (fun () ->
      let ordinal = parent.next_nested in
      let path = scope_path parent @ [ ordinal ] in
      Result.map
        (fun (scheduler, body) ->
          let child = make_root scheduler in
          parent.next_nested <- ordinal + 1;
          parent.children <- parent.children @ [ child ];
          (child, body))
        (Scheduler_core.create_nested ~parent:parent.scheduler ~scope_path:path ~body_resume))

let spawn scope ~resume = ensure_open scope (fun () -> Scheduler_core.spawn scope.scheduler ~resume)
let id scope handle = ensure_open scope (fun () -> Scheduler_core.id scope.scheduler handle)

let task_value capability scope handle =
  ensure_open scope (fun () -> Scheduler_core.task_value capability scope.scheduler handle)

let task_handle capability scope value =
  ensure_open scope (fun () -> Scheduler_core.task_handle capability scope.scheduler value)

let inspect scope handle =
  ensure_open scope (fun () -> Scheduler_core.inspect scope.scheduler handle)

let checkout scope handle =
  ensure_open scope (fun () -> Scheduler_core.checkout scope.scheduler handle)

let with_checkout scope handle operation =
  ensure_open scope (fun () -> Scheduler_core.with_checkout scope.scheduler handle operation)

let suspend_yield scope handle ~resume =
  ensure_open scope (fun () -> Scheduler_core.suspend_yield scope.scheduler handle ~resume)

let wake_yielded scope handle =
  ensure_open scope (fun () -> Scheduler_core.wake_yielded scope.scheduler handle)

let await scope ~waiter ~target ~resume =
  ensure_open scope (fun () -> Scheduler_core.await scope.scheduler ~waiter ~target ~resume)

let complete scope handle value =
  ensure_open scope (fun () -> Scheduler_core.complete scope.scheduler handle value)

let fail scope handle message =
  ensure_open scope (fun () -> Scheduler_core.fail scope.scheduler handle message)

let request_cancel scope handle =
  ensure_open scope (fun () -> Scheduler_core.request_cancel scope.scheduler handle)

let deliver_cancel scope ~point handle ~drop =
  ensure_open scope (fun () ->
      Result.map
        (fun (awakened, resumes) ->
          drop_all drop resumes;
          awakened)
        (Scheduler_core.deliver_cancel scope.scheduler ~point handle))

let at_cancellation_point scope ~point ~task ~resume ~drop =
  ensure_open scope (fun () ->
      Result.map
        (function
          | Scheduler_core.Boundary_continue resume -> Boundary_continue resume
          | Scheduler_core.Boundary_cancelled { resume; awakened } ->
              drop resume;
              Boundary_cancelled awakened)
        (Scheduler_core.cancellation_boundary scope.scheduler ~point task ~resume))

let await_cooperatively scope ~waiter ~target ~resume ~drop =
  Result.bind
    (at_cancellation_point scope ~point:Concurrency_contract.Await ~task:waiter ~resume ~drop)
    (function
    | Boundary_cancelled awakened -> Ok (Await_cancelled awakened)
    | Boundary_continue resume ->
        Result.map
          (fun (outcome, awakened) -> Await_performed (outcome, awakened))
          (await scope ~waiter ~target ~resume))

let yield_cooperatively scope ~task ~resume ~drop =
  Result.bind (at_cancellation_point scope ~point:Concurrency_contract.Yield ~task ~resume ~drop)
    (function
    | Boundary_cancelled awakened -> Ok (Yield_cancelled awakened)
    | Boundary_continue resume ->
        Result.map (fun () -> Yield_suspended) (suspend_yield scope task ~resume))

let route_effect scope ~task ~resume ~drop ~action =
  Result.map
    (function
      | Boundary_cancelled awakened -> Effect_cancelled awakened
      | Boundary_continue resume -> Effect_routed { resume; result = action () })
    (at_cancellation_point scope ~point:Concurrency_contract.Routed_effect ~task ~resume ~drop)

let cancel scope ~caller ~target ~resume ~drop =
  Result.bind
    (at_cancellation_point scope ~point:Concurrency_contract.Routed_effect ~task:caller ~resume
       ~drop) (function
    | Boundary_cancelled awakened -> Ok (Cancel_caller_cancelled awakened)
    | Boundary_continue resume ->
        Result.bind (request_cancel scope target) (fun () ->
            Result.bind (inspect scope target) (fun target_view ->
                match (target_view.lifecycle, target_view.suspension) with
                | Concurrency_contract.Suspended, Some suspension ->
                    let point =
                      match suspension with
                      | Scheduler_core.Yielded -> Concurrency_contract.Yield
                      | Scheduler_core.Awaiting _ -> Concurrency_contract.Await
                    in
                    Result.map
                      (fun awakened -> Cancel_continues { resume; awakened })
                      (deliver_cancel scope ~point target ~drop)
                | _ ->
                    Result.map
                      (function
                        | Boundary_continue resume -> Cancel_continues { resume; awakened = [] }
                        | Boundary_cancelled awakened -> Cancel_caller_cancelled awakened)
                      (* Recheck after the request so [target = caller] observes its
                         cancellation at this routed-effect boundary. For another
                         runnable or terminal target, the caller continuation is
                         preserved. *)
                      (at_cancellation_point scope ~point:Concurrency_contract.Routed_effect
                         ~task:caller ~resume ~drop))))

let rec is_prefix prefix path =
  match (prefix, path) with
  | [], _ -> true
  | _, [] -> false
  | left :: prefix, right :: path -> left = right && is_prefix prefix path

let escaping_diagnostics scope handles =
  let prefix = scope_path scope in
  List.filter_map
    (fun handle ->
      match Scheduler_core.validate_run_handle scope.scheduler handle with
      | Error diagnostics -> Some diagnostics
      | Ok id when is_prefix prefix id.scope_path ->
          Some
            [
              escape_diagnostic
                ("Task "
                ^ Concurrency_contract.trace_task_id id
                ^ " escaped its creating structured scope");
            ]
      | Ok _ -> None)
    handles
  |> List.concat

let rec close_owned scope =
  if scope.closed then []
  else
    let child_resumes = List.concat_map close_owned scope.children in
    let own_resumes = Scheduler_core.close scope.scheduler in
    scope.closed <- true;
    child_resumes @ own_resumes

let close scope ~reason:_ ~escaping ~drop =
  let diagnostics = if scope.closed then [] else escaping_diagnostics scope escaping in
  close_owned scope |> drop_all drop;
  match diagnostics with [] -> Ok () | _ -> Error diagnostics

let protect scope ~drop ~escapes body =
  try
    match body scope with
    | Ok value ->
        Result.map (fun () -> value) (close scope ~reason:Normal ~escaping:(escapes value) ~drop)
    | Error diagnostics ->
        ignore (close scope ~reason:Aborted ~escaping:[] ~drop);
        Error diagnostics
  with exn ->
    ignore (close scope ~reason:Raised ~escaping:[] ~drop);
    raise exn

let add_metrics left right =
  {
    open_scopes = left.open_scopes + right.open_scopes;
    live_tasks = left.live_tasks + right.live_tasks;
    runnable_tasks = left.runnable_tasks + right.runnable_tasks;
    owned_resumes = left.owned_resumes + right.owned_resumes;
  }

let metrics scope =
  let rec loop scope =
    let views = Scheduler_core.task_views scope.scheduler in
    let own =
      List.fold_left
        (fun metrics (view : _ Scheduler_core.task_view) ->
          let live, runnable =
            match view.lifecycle with
            | Concurrency_contract.Runnable -> (1, 1)
            | Concurrency_contract.Suspended -> (1, 0)
            | Concurrency_contract.Done_state | Concurrency_contract.Failed_state
            | Concurrency_contract.Cancelled_state ->
                (0, 0)
          in
          {
            open_scopes = metrics.open_scopes;
            live_tasks = metrics.live_tasks + live;
            runnable_tasks = metrics.runnable_tasks + runnable;
            owned_resumes = (metrics.owned_resumes + if view.owns_resume then 1 else 0);
          })
        {
          open_scopes = (if scope.closed then 0 else 1);
          live_tasks = 0;
          runnable_tasks = 0;
          owned_resumes = 0;
        }
        views
    in
    List.fold_left (fun totals child -> add_metrics totals (loop child)) own scope.children
  in
  loop scope
