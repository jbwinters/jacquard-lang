type handle = Task_handle.t

type suspension =
  | Yielded
  | Awaiting of Concurrency_contract.task_id
  | Channel_sending of Channel_contract.channel_id
  | Channel_receiving of Channel_contract.channel_id

type ('resume, 'value) entry = {
  handle : handle;
  id : Concurrency_contract.task_id;
  mutable lifecycle : Concurrency_contract.lifecycle;
  mutable suspension : suspension option;
  mutable result : 'value Concurrency_contract.task_result option;
  mutable waiters : Concurrency_contract.task_id list;
  mutable cancellation_requested : bool;
  mutable resume : 'resume option;
}

type ('resume, 'value) t = {
  run : Task_handle.run;
  scope_path : int list;
  mutable next_spawn : int;
  mutable entries : ('resume, 'value) entry list;
  mutable closed : bool;
}

type 'value task_view = {
  id : Concurrency_contract.task_id;
  lifecycle : Concurrency_contract.lifecycle;
  suspension : suspension option;
  result : 'value Concurrency_contract.task_result option;
  waiters : Concurrency_contract.task_id list;
  cancellation_requested : bool;
  owns_resume : bool;
}

type 'value await_outcome =
  | Await_ready of 'value Concurrency_contract.task_result
  | Await_suspended
  | Await_deadlocked of string

type 'resume cancellation_boundary =
  | Boundary_continue of 'resume
  | Boundary_cancelled of { resume : 'resume; awakened : handle list }

type ('resume, 'value) prepared_channel_suspend = {
  suspend_entry : ('resume, 'value) entry;
  suspend_channel : Channel_contract.channel_id;
  suspend_direction : [ `Send | `Recv ];
  suspend_resume : 'resume;
  mutable suspend_committed : bool;
}

type ('resume, 'value) prepared_channel_wake = {
  wake_entry : ('resume, 'value) entry;
  wake_resume : 'resume;
  mutable wake_committed : bool;
}

let diagnostic message =
  Diag.error ~domain:Concurrency ~code:"E0908"
    ~summary:"The structured-concurrency scheduler state is invalid."
    ~cause:("Invalid structured-concurrency scheduler state: " ^ message)
    ~next_step:"Advance the scheduler task state according to the documented transition."
    ~contrast:None ()

let error message = Error [ diagnostic message ]
let equal_id left right = Concurrency_contract.compare_task_id left right = 0

let find_entry scheduler id =
  List.find_opt (fun (entry : (_, _) entry) -> equal_id entry.id id) scheduler.entries

let validate scheduler handle =
  Result.bind
    (Task_handle.validate_scope ~run:scheduler.run ~scope_path:scheduler.scope_path handle)
    (fun id ->
      match find_entry scheduler id with
      | Some entry -> Ok entry
      | None -> error ("unknown task " ^ Concurrency_contract.trace_task_id id))

let create_in_run ~run ~scope_path ~body_resume =
  Result.bind (Task_handle.create ~run ~scope_path ~spawn_index:0) (fun handle ->
      Result.bind (Task_handle.validate_scope ~run ~scope_path handle) (fun id ->
          let entry =
            {
              handle;
              id;
              lifecycle = Concurrency_contract.Runnable;
              suspension = None;
              result = None;
              waiters = [];
              cancellation_requested = false;
              resume = Some body_resume;
            }
          in
          Ok ({ run; scope_path; next_spawn = 1; entries = [ entry ]; closed = false }, handle)))

let create ~scope_path ~body_resume =
  create_in_run ~run:(Task_handle.create_run ()) ~scope_path ~body_resume

let create_nested ~parent ~scope_path ~body_resume =
  create_in_run ~run:parent.run ~scope_path ~body_resume

let scope_path scheduler = scheduler.scope_path

let view_of_entry (entry : (_, _) entry) =
  {
    id = entry.id;
    lifecycle = entry.lifecycle;
    suspension = entry.suspension;
    result = entry.result;
    waiters = entry.waiters;
    cancellation_requested = entry.cancellation_requested;
    owns_resume = Option.is_some entry.resume;
  }

let task_views scheduler = List.map view_of_entry scheduler.entries
let is_closed scheduler = scheduler.closed

let spawn scheduler ~resume =
  if scheduler.closed then error "cannot spawn into a closed scope"
  else
    let spawn_index = scheduler.next_spawn in
    Result.bind
      (Task_handle.create ~run:scheduler.run ~scope_path:scheduler.scope_path ~spawn_index)
      (fun handle ->
        Result.bind
          (Task_handle.validate_scope ~run:scheduler.run ~scope_path:scheduler.scope_path handle)
          (fun id ->
            scheduler.next_spawn <- spawn_index + 1;
            scheduler.entries <-
              scheduler.entries
              @ [
                  {
                    handle;
                    id;
                    lifecycle = Concurrency_contract.Runnable;
                    suspension = None;
                    result = None;
                    waiters = [];
                    cancellation_requested = false;
                    resume = Some resume;
                  };
                ];
            Ok handle))

let id scheduler handle =
  Result.map (fun (entry : (_, _) entry) -> entry.id) (validate scheduler handle)

let handle_of_id scheduler (id : Concurrency_contract.task_id) =
  if scheduler.closed then error "cannot resolve a task in a closed scope"
  else if id.scope_path <> scheduler.scope_path then error "task identity belongs to another scope"
  else
    match find_entry scheduler id with
    | Some entry -> Ok entry.handle
    | None -> error ("unknown task " ^ Concurrency_contract.trace_task_id id)

let task_run _capability scheduler = scheduler.run

let task_value _capability scheduler handle =
  Result.map (fun _ -> Value.VTask handle) (id scheduler handle)

let task_handle _capability scheduler = function
  | Value.VTask handle -> Result.map (fun _ -> handle) (id scheduler handle)
  | _ ->
      Error
        [
          Diag.error ~domain:Concurrency ~code:Concurrency_contract.task_escape_code
            ~summary:"This Async operation did not receive a valid task handle."
            ~cause:"The operation expected an opaque Task value."
            ~next_step:"Pass the Task returned by async.spawn in the same structured scope."
            ~contrast:
              (Some
                 (Diag.contrast ~mistaken:"an ordinary value"
                    ~intended:"the opaque Task returned by async.spawn"))
            ();
        ]

let validate_run_handle scheduler handle = Task_handle.validate_run ~run:scheduler.run handle
let inspect scheduler handle = Result.map view_of_entry (validate scheduler handle)

let checkout scheduler handle =
  Result.bind (validate scheduler handle) (fun (entry : (_, _) entry) ->
      match (entry.lifecycle, entry.resume) with
      | Concurrency_contract.Runnable, Some resume ->
          entry.resume <- None;
          Ok resume
      | Concurrency_contract.Runnable, None -> error "runnable task is already checked out"
      | Concurrency_contract.Suspended, _ -> error "cannot check out a suspended task"
      | ( ( Concurrency_contract.Done_state | Concurrency_contract.Failed_state
          | Concurrency_contract.Cancelled_state ),
          _ ) ->
          error "cannot check out a terminal task")

let restore_checkout (entry : (_, _) entry) resume =
  match (entry.lifecycle, entry.resume) with
  | Concurrency_contract.Runnable, None -> entry.resume <- Some resume
  | Concurrency_contract.Runnable, Some _
  | Concurrency_contract.Suspended, Some _
  | ( ( Concurrency_contract.Done_state | Concurrency_contract.Failed_state
      | Concurrency_contract.Cancelled_state ),
      None ) ->
      ()
  | Concurrency_contract.Suspended, None
  | ( ( Concurrency_contract.Done_state | Concurrency_contract.Failed_state
      | Concurrency_contract.Cancelled_state ),
      Some _ ) ->
      failwith "Bug_scheduler_core: checkout operation left invalid resume ownership"

let with_checkout scheduler handle operation =
  Result.bind (validate scheduler handle) (fun entry ->
      Result.bind (checkout scheduler handle) (fun resume ->
          match operation resume with
          | (Ok _ | Error _) as result ->
              restore_checkout entry resume;
              result
          | exception exn ->
              let backtrace = Printexc.get_raw_backtrace () in
              restore_checkout entry resume;
              Printexc.raise_with_backtrace exn backtrace))

let ensure_checked_out (entry : (_, _) entry) =
  match (entry.lifecycle, entry.resume) with
  | Concurrency_contract.Runnable, None -> Ok ()
  | Concurrency_contract.Runnable, Some _ -> error "task still owns a resume token"
  | Concurrency_contract.Suspended, _ -> error "task is suspended"
  | ( ( Concurrency_contract.Done_state | Concurrency_contract.Failed_state
      | Concurrency_contract.Cancelled_state ),
      _ ) ->
      error "task is terminal"

let suspend_yield scheduler handle ~resume =
  Result.bind (validate scheduler handle) (fun (entry : (_, _) entry) ->
      Result.map
        (fun () ->
          entry.resume <- Some resume;
          entry.lifecycle <- Concurrency_contract.Suspended;
          entry.suspension <- Some Yielded)
        (ensure_checked_out entry))

let wake_yielded scheduler handle =
  Result.bind (validate scheduler handle) (fun (entry : (_, _) entry) ->
      match (entry.lifecycle, entry.suspension, entry.resume) with
      | Concurrency_contract.Suspended, Some Yielded, Some _ ->
          entry.lifecycle <- Concurrency_contract.Runnable;
          entry.suspension <- None;
          Ok ()
      | _ -> error "only a yielded task with one resume token can be made runnable")

let validate_channel_caller _capability scheduler handle =
  Result.bind (validate scheduler handle) ensure_checked_out

let prepare_channel_suspend _capability scheduler handle ~channel ~direction ~resume =
  Result.bind (validate scheduler handle) (fun (entry : (_, _) entry) ->
      Result.map
        (fun () ->
          {
            suspend_entry = entry;
            suspend_channel = channel;
            suspend_direction = direction;
            suspend_resume = resume;
            suspend_committed = false;
          })
        (ensure_checked_out entry))

let commit_channel_suspend _capability prepared =
  if prepared.suspend_committed then
    failwith "Bug_scheduler_core: prepared channel suspension committed twice";
  prepared.suspend_committed <- true;
  prepared.suspend_entry.resume <- Some prepared.suspend_resume;
  prepared.suspend_entry.lifecycle <- Concurrency_contract.Suspended;
  prepared.suspend_entry.suspension <-
    Some
      (match prepared.suspend_direction with
      | `Send -> Channel_sending prepared.suspend_channel
      | `Recv -> Channel_receiving prepared.suspend_channel)

let suspend_channel scheduler handle ~channel ~direction ~resume =
  Result.map
    (fun prepared -> commit_channel_suspend Task_capability.runtime prepared)
    (prepare_channel_suspend Task_capability.runtime scheduler handle ~channel ~direction ~resume)

let same_channel left right = Channel_contract.compare_channel_id left right = 0

let prepare_channel_wake _capability scheduler handle ~channel ~map_resume =
  Result.bind (validate scheduler handle) (fun (entry : (_, _) entry) ->
      match (entry.lifecycle, entry.suspension, entry.resume) with
      | ( Concurrency_contract.Suspended,
          Some (Channel_sending waiting | Channel_receiving waiting),
          Some resume )
        when same_channel waiting channel ->
          Result.map
            (fun mapped -> { wake_entry = entry; wake_resume = mapped; wake_committed = false })
            (map_resume resume)
      | _ -> error "only a task suspended on the exact channel can be channel-woken")

let commit_channel_wake _capability prepared =
  if prepared.wake_committed then
    failwith "Bug_scheduler_core: prepared channel wake committed twice";
  prepared.wake_committed <- true;
  prepared.wake_entry.resume <- Some prepared.wake_resume;
  prepared.wake_entry.lifecycle <- Concurrency_contract.Runnable;
  prepared.wake_entry.suspension <- None

let wake_channel_with scheduler handle ~channel ~map_resume =
  Result.map
    (fun prepared -> commit_channel_wake Task_capability.runtime prepared)
    (prepare_channel_wake Task_capability.runtime scheduler handle ~channel ~map_resume)

let result_lifecycle = function
  | Concurrency_contract.Done _ -> Concurrency_contract.Done_state
  | Concurrency_contract.Failed _ -> Concurrency_contract.Failed_state
  | Concurrency_contract.Cancelled -> Concurrency_contract.Cancelled_state

let remove_waiter scheduler waiter =
  List.iter
    (fun (entry : (_, _) entry) ->
      entry.waiters <- List.filter (fun id -> not (equal_id id waiter)) entry.waiters)
    scheduler.entries

let wake_waiters scheduler (entry : (_, _) entry) =
  let ids = Concurrency_contract.wake_waiters entry.waiters in
  entry.waiters <- [];
  List.filter_map
    (fun waiter_id ->
      match find_entry scheduler waiter_id with
      | Some waiter
        when waiter.lifecycle = Concurrency_contract.Suspended
             &&
             match waiter.suspension with
             | Some (Awaiting target) -> equal_id target entry.id
             | Some (Yielded | Channel_sending _ | Channel_receiving _) | None -> false ->
          waiter.lifecycle <- Concurrency_contract.Runnable;
          waiter.suspension <- None;
          Some waiter.handle
      | _ -> None)
    ids

let terminalize scheduler (entry : (_, _) entry) result =
  match entry.result with
  | Some _ -> error "terminal task result is immutable"
  | None ->
      remove_waiter scheduler entry.id;
      entry.resume <- None;
      entry.lifecycle <- result_lifecycle result;
      entry.suspension <- None;
      entry.result <- Some result;
      entry.cancellation_requested <- false;
      Ok (wake_waiters scheduler entry)

let wait_edges scheduler =
  List.filter_map
    (fun (entry : (_, _) entry) ->
      match (entry.lifecycle, entry.suspension) with
      | Concurrency_contract.Suspended, Some (Awaiting target) ->
          Some Concurrency_contract.{ waiter = entry.id; target }
      | _ -> None)
    scheduler.entries

let cycle_message cycle =
  match cycle with
  | [ id; repeated ] when equal_id id repeated ->
      "async deadlock: task " ^ Concurrency_contract.trace_task_id id ^ " awaited itself"
  | _ ->
      "async deadlock: await cycle "
      ^ String.concat " -> " (List.map Concurrency_contract.trace_task_id cycle)

let unique_cycle cycle =
  List.fold_left
    (fun ids id -> if List.exists (equal_id id) ids then ids else ids @ [ id ])
    [] cycle

let fail_cycle scheduler cycle =
  let message = cycle_message cycle in
  let members =
    unique_cycle cycle
    |> List.filter_map (fun id ->
        match find_entry scheduler id with
        | Some entry when entry.result = None -> Some entry
        | Some _ | None -> None)
  in
  (* Terminalize the complete cycle before reporting any wakeup. In particular, a cycle predecessor
     removed from another member's waiter list must never be transiently reported as runnable. *)
  List.iter (fun (entry : (_, _) entry) -> remove_waiter scheduler entry.id) members;
  List.iter
    (fun (entry : (_, _) entry) ->
      entry.resume <- None;
      entry.lifecycle <- Concurrency_contract.Failed_state;
      entry.suspension <- None;
      entry.result <- Some (Concurrency_contract.Failed message);
      entry.cancellation_requested <- false)
    members;
  let awakened = List.concat_map (wake_waiters scheduler) members in
  (message, awakened)

let await scheduler ~waiter ~target ~resume =
  Result.bind (validate scheduler waiter) (fun waiter_entry ->
      Result.bind (validate scheduler target) (fun target_entry ->
          Result.bind (ensure_checked_out waiter_entry) (fun () ->
              match target_entry.result with
              | Some result ->
                  waiter_entry.resume <- Some resume;
                  Ok (Await_ready result, [])
              | None -> (
                  waiter_entry.resume <- Some resume;
                  waiter_entry.lifecycle <- Concurrency_contract.Suspended;
                  waiter_entry.suspension <- Some (Awaiting target_entry.id);
                  target_entry.waiters <- target_entry.waiters @ [ waiter_entry.id ];
                  match Concurrency_contract.detect_wait_cycle (wait_edges scheduler) with
                  | None -> Ok (Await_suspended, [])
                  | Some cycle ->
                      let message, awakened = fail_cycle scheduler cycle in
                      Ok (Await_deadlocked message, awakened)))))

let finish scheduler handle result =
  Result.bind (validate scheduler handle) (fun (entry : (_, _) entry) ->
      Result.bind (ensure_checked_out entry) (fun () -> terminalize scheduler entry result))

let complete scheduler handle value = finish scheduler handle (Concurrency_contract.Done value)
let fail scheduler handle message = finish scheduler handle (Concurrency_contract.Failed message)

let request_cancel scheduler handle =
  Result.map
    (fun (entry : (_, _) entry) ->
      match entry.result with None -> entry.cancellation_requested <- true | Some _ -> ())
    (validate scheduler handle)

let cancellation_pending scheduler handle =
  Result.map
    (fun (entry : (_, _) entry) -> entry.result = None && entry.cancellation_requested)
    (validate scheduler handle)

let deliver_cancel scheduler ~point:_ handle =
  Result.bind (validate scheduler handle) (fun (entry : (_, _) entry) ->
      if entry.result <> None || not entry.cancellation_requested then Ok ([], [])
      else
        let resumes = Option.to_list entry.resume in
        Result.map
          (fun awakened -> (awakened, resumes))
          (terminalize scheduler entry Concurrency_contract.Cancelled))

let cancellation_boundary scheduler ~point:_ handle ~resume =
  Result.bind (validate scheduler handle) (fun (entry : (_, _) entry) ->
      match (entry.lifecycle, entry.result) with
      | Concurrency_contract.Runnable, None ->
          Result.bind (ensure_checked_out entry) (fun () ->
              if not entry.cancellation_requested then Ok (Boundary_continue resume)
              else
                Result.map
                  (fun awakened -> Boundary_cancelled { resume; awakened })
                  (terminalize scheduler entry Concurrency_contract.Cancelled))
      | Concurrency_contract.Cancelled_state, Some Concurrency_contract.Cancelled ->
          Ok (Boundary_cancelled { resume; awakened = [] })
      | Concurrency_contract.Suspended, None -> error "a suspended task cannot reach a new boundary"
      | Concurrency_contract.Done_state, Some (Concurrency_contract.Done _)
      | Concurrency_contract.Failed_state, Some (Concurrency_contract.Failed _) ->
          error "a completed task cannot reach a new boundary"
      | _ -> error "task lifecycle and terminal result disagree at cancellation boundary")

let close scheduler =
  if scheduler.closed then []
  else (
    scheduler.closed <- true;
    let resumes = List.filter_map (fun (entry : (_, _) entry) -> entry.resume) scheduler.entries in
    List.iter
      (fun (entry : (_, _) entry) ->
        entry.resume <- None;
        entry.waiters <- [];
        entry.suspension <- None;
        if entry.result = None then (
          entry.lifecycle <- Concurrency_contract.Cancelled_state;
          entry.result <- Some Concurrency_contract.Cancelled;
          entry.cancellation_requested <- false))
      scheduler.entries;
    resumes)
