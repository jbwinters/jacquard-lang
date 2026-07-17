type handle = Scheduler_core.handle
type exit_reason = Normal | Aborted | Raised
type metrics = { open_scopes : int; live_tasks : int; runnable_tasks : int; owned_resumes : int }

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
let make_root scheduler = { scheduler; next_nested = 1; children = []; closed = false }

let create ~body_resume =
  Result.map
    (fun (scheduler, body) -> (make_root scheduler, body))
    (Scheduler_core.create ~scope_path:[ 0 ] ~body_resume)

let scope_path scope = Scheduler_core.scope_path scope.scheduler

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

let inspect scope handle =
  ensure_open scope (fun () -> Scheduler_core.inspect scope.scheduler handle)

let checkout scope handle =
  ensure_open scope (fun () -> Scheduler_core.checkout scope.scheduler handle)

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

let deliver_cancel scope ~point handle =
  ensure_open scope (fun () -> Scheduler_core.deliver_cancel scope.scheduler ~point handle)

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

let drop_all drop resumes =
  let first_exception = ref None in
  List.iter
    (fun resume ->
      match drop resume with
      | () -> ()
      | exception exn -> if Option.is_none !first_exception then first_exception := Some exn)
    resumes;
  Option.iter raise !first_exception

let close scope ~reason:_ ~escaping ~drop =
  let diagnostics = if scope.closed then [] else escaping_diagnostics scope escaping in
  close_owned scope |> drop_all drop;
  match diagnostics with [] -> Ok () | _ -> Error diagnostics

let protect scope ~drop ~escapes body =
  match body scope with
  | Ok value ->
      Result.map (fun () -> value) (close scope ~reason:Normal ~escaping:(escapes value) ~drop)
  | Error diagnostics ->
      (match close scope ~reason:Aborted ~escaping:[] ~drop with
      | Ok () | Error _ -> ()
      | exception _ -> ());
      Error diagnostics
  | exception exn ->
      let backtrace = Printexc.get_raw_backtrace () in
      (match close scope ~reason:Raised ~escaping:[] ~drop with
      | Ok () | Error _ -> ()
      | exception _ -> ());
      Printexc.raise_with_backtrace exn backtrace

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
