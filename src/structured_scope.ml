type handle = Scheduler_core.handle
type channel_handle = Channel_handle.t
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

type channel_open_outcome = Channel_opened of channel_handle | Channel_invalid_capacity of int
type 'value channel_result = Channel_send_ok | Channel_recv_ok of 'value | Channel_closed

type 'resume channel_transition =
  | Channel_continues of { resume : 'resume; awakened : handle list }
  | Channel_suspended

type ('resume, 'value) channel_entry = {
  state : (Concurrency_contract.task_id, 'value) Channel_contract.t;
}

type ('resume, 'value) t = {
  scheduler : ('resume, 'value) Scheduler_core.t;
  mutable next_nested : int;
  mutable children : ('resume, 'value) t list;
  mutable next_channel : int;
  mutable channels : ('resume, 'value) channel_entry list;
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

let make_root scheduler =
  { scheduler; next_nested = 1; children = []; next_channel = 0; channels = []; closed = false }

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

let channel_run scope = Scheduler_core.task_run Task_capability.runtime scope.scheduler

let channel_open scope ~capacity =
  if capacity < 0 then Ok (Channel_invalid_capacity capacity)
  else
    ensure_open scope (fun () ->
        let open_index = scope.next_channel in
        match
          Channel_contract.open_channel ~scope_path:(scope_path scope) ~open_index ~capacity
        with
        | Channel_contract.Invalid_capacity rejected -> Ok (Channel_invalid_capacity rejected)
        | Channel_contract.Opened state ->
            let id = (Channel_contract.view state).id in
            let channel_handle = Channel_handle.create ~run:(channel_run scope) ~id in
            scope.next_channel <- open_index + 1;
            scope.channels <- scope.channels @ [ { state } ];
            Ok (Channel_opened channel_handle)
        | exception Channel_contract.Bug_invalid_channel_id detail ->
            Error
              [
                Diag.error ~code:"E0908" ~hint:"channel state was not allocated"
                  ("invalid structured-concurrency scheduler state: " ^ detail);
              ])

let same_channel_id left right = Channel_contract.compare_channel_id left right = 0
let equal_task_id left right = Concurrency_contract.compare_task_id left right = 0

let find_channel scope channel =
  ensure_open scope (fun () ->
      Result.bind
        (Channel_handle.validate_scope ~run:(channel_run scope) ~scope_path:(scope_path scope)
           channel)
        (fun id ->
          match
            List.find_opt
              (fun entry -> same_channel_id (Channel_contract.view entry.state).id id)
              scope.channels
          with
          | Some entry -> Ok entry
          | None -> closed_error ()))

let channel_value _capability scope channel =
  Result.map (fun _ -> Value.VChannel channel) (find_channel scope channel)

let channel_handle _capability scope = function
  | Value.VChannel channel -> Result.map (fun _ -> channel) (find_channel scope channel)
  | _ ->
      Error
        [
          Diag.error ~code:Concurrency_contract.task_escape_code
            "Channel operation expected an opaque ChannelHandle";
        ]

let prepare_channel_wake scope channel_id task_id result ~map_resume =
  Result.bind (Scheduler_core.handle_of_id scope.scheduler task_id) (fun handle ->
      Result.map
        (fun prepared -> (handle, prepared))
        (Scheduler_core.prepare_channel_wake Task_capability.runtime scope.scheduler handle
           ~channel:channel_id ~map_resume:(fun resume -> Ok (map_resume resume result))))

let commit_channel_wake (_, prepared) =
  Scheduler_core.commit_channel_wake Task_capability.runtime prepared

let prepared_handle (handle, _) = handle

let prepare_channel_caller scope task =
  Scheduler_core.validate_channel_caller Task_capability.runtime scope.scheduler task

let prepare_channel_suspend scope task ~channel ~direction ~resume =
  Scheduler_core.prepare_channel_suspend Task_capability.runtime scope.scheduler task ~channel
    ~direction ~resume

let commit_channel_suspend prepared =
  Scheduler_core.commit_channel_suspend Task_capability.runtime prepared

let bug_transition operation =
  failwith ("Bug_structured_scope: prepared channel " ^ operation ^ " changed before commit")

let validate_channel_operation scope ~task ~channel =
  ensure_open scope (fun () ->
      Result.bind (Scheduler_core.id scope.scheduler task) (fun task_id ->
          Result.map (fun channel_entry -> (task_id, channel_entry)) (find_channel scope channel)))

let channel_send scope ~task ~channel ~resume ~value ~map_resume =
  Result.bind (validate_channel_operation scope ~task ~channel) (fun (task_id, entry) ->
      let channel_id = (Channel_contract.view entry.state).id in
      let before = Channel_contract.snapshot entry.state in
      Result.bind (prepare_channel_caller scope task) (fun () ->
          if before.snapshot_closed then
            Ok (Channel_continues { resume = map_resume resume Channel_closed; awakened = [] })
          else
            match before.snapshot_receivers with
            | receiver :: _ ->
                Result.map
                  (fun prepared_wake ->
                    let sender_resume = map_resume resume Channel_send_ok in
                    (match Channel_contract.send entry.state ~sender:task_id ~value with
                    | Channel_contract.Send_delivered delivered
                      when equal_task_id delivered.receiver receiver.receiver ->
                        ()
                    | _ -> bug_transition "send");
                    commit_channel_wake prepared_wake;
                    Channel_continues
                      { resume = sender_resume; awakened = [ prepared_handle prepared_wake ] })
                  (prepare_channel_wake scope channel_id receiver.receiver (Channel_recv_ok value)
                     ~map_resume)
            | [] when List.length before.snapshot_buffer < before.snapshot_capacity ->
                let sender_resume = map_resume resume Channel_send_ok in
                (match Channel_contract.send entry.state ~sender:task_id ~value with
                | Channel_contract.Send_completed -> ()
                | _ -> bug_transition "send");
                Ok (Channel_continues { resume = sender_resume; awakened = [] })
            | [] ->
                Result.map
                  (fun prepared_suspend ->
                    (match Channel_contract.send entry.state ~sender:task_id ~value with
                    | Channel_contract.Send_blocked -> ()
                    | _ -> bug_transition "send");
                    commit_channel_suspend prepared_suspend;
                    Channel_suspended)
                  (prepare_channel_suspend scope task ~channel:channel_id ~direction:`Send ~resume)))

let channel_recv scope ~task ~channel ~resume ~map_resume =
  Result.bind (validate_channel_operation scope ~task ~channel) (fun (task_id, entry) ->
      let channel_id = (Channel_contract.view entry.state).id in
      let before = Channel_contract.snapshot entry.state in
      Result.bind (prepare_channel_caller scope task) (fun () ->
          let deliver value pending_sender =
            match pending_sender with
            | None ->
                let receiver_resume = map_resume resume (Channel_recv_ok value) in
                (match Channel_contract.recv entry.state ~receiver:task_id with
                | Channel_contract.Recv_delivered { completed_sender = None; _ } -> ()
                | _ -> bug_transition "receive");
                Ok (Channel_continues { resume = receiver_resume; awakened = [] })
            | Some sender ->
                Result.map
                  (fun prepared_wake ->
                    let receiver_resume = map_resume resume (Channel_recv_ok value) in
                    (match Channel_contract.recv entry.state ~receiver:task_id with
                    | Channel_contract.Recv_delivered { completed_sender = Some completed; _ }
                      when equal_task_id completed.Channel_contract.sender
                             sender.Channel_contract.sender ->
                        ()
                    | _ -> bug_transition "receive");
                    commit_channel_wake prepared_wake;
                    Channel_continues
                      { resume = receiver_resume; awakened = [ prepared_handle prepared_wake ] })
                  (prepare_channel_wake scope channel_id sender.Channel_contract.sender
                     Channel_send_ok ~map_resume)
          in
          match before.snapshot_buffer with
          | value :: _ ->
              deliver value
                (match before.snapshot_senders with sender :: _ -> Some sender | [] -> None)
          | [] -> (
              match before.snapshot_senders with
              | sender :: _ -> deliver sender.sent_value (Some sender)
              | [] when before.snapshot_closed ->
                  Ok
                    (Channel_continues { resume = map_resume resume Channel_closed; awakened = [] })
              | [] ->
                  Result.map
                    (fun prepared_suspend ->
                      (match Channel_contract.recv entry.state ~receiver:task_id with
                      | Channel_contract.Recv_blocked -> ()
                      | _ -> bug_transition "receive");
                      commit_channel_suspend prepared_suspend;
                      Channel_suspended)
                    (prepare_channel_suspend scope task ~channel:channel_id ~direction:`Recv ~resume)
              )))

let channel_close scope ~task ~channel ~resume ~map_resume ~map_closer =
  Result.bind (validate_channel_operation scope ~task ~channel) (fun (_, entry) ->
      let channel_id = (Channel_contract.view entry.state).id in
      let before = Channel_contract.snapshot entry.state in
      let pending =
        if before.snapshot_closed then []
        else
          List.map (fun sender -> sender.Channel_contract.sender) before.snapshot_senders
          @
          if before.snapshot_buffer = [] then
            List.map (fun receiver -> receiver.Channel_contract.receiver) before.snapshot_receivers
          else []
      in
      let rec prepare reversed = function
        | [] -> Ok (List.rev reversed)
        | pending_task :: rest ->
            Result.bind
              (prepare_channel_wake scope channel_id pending_task Channel_closed ~map_resume)
              (fun prepared -> prepare (prepared :: reversed) rest)
      in
      Result.bind (prepare_channel_caller scope task) (fun () ->
          Result.map
            (fun prepared_wakes ->
              let closer_resume = map_closer resume in
              ignore (Channel_contract.close entry.state);
              List.iter commit_channel_wake prepared_wakes;
              Channel_continues
                { resume = closer_resume; awakened = List.map prepared_handle prepared_wakes })
            (prepare [] pending)))

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

let remove_channel_waiter scope handle =
  Result.map
    (fun task_id ->
      List.iter
        (fun entry ->
          ignore (Channel_contract.cancel ~equal_task:equal_task_id entry.state task_id))
        scope.channels)
    (Scheduler_core.id scope.scheduler handle)

let deliver_cancel scope ~point handle ~drop =
  ensure_open scope (fun () ->
      Result.bind (Scheduler_core.cancellation_pending scope.scheduler handle) (fun pending ->
          let removed = if pending then remove_channel_waiter scope handle else Ok () in
          Result.bind removed (fun () ->
              Result.map
                (fun (awakened, resumes) ->
                  drop_all drop resumes;
                  awakened)
                (Scheduler_core.deliver_cancel scope.scheduler ~point handle))))

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
                      | Scheduler_core.Channel_sending _ | Scheduler_core.Channel_receiving _ ->
                          Concurrency_contract.Routed_effect
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
    List.iter (fun entry -> ignore (Channel_contract.teardown entry.state)) scope.channels;
    let own_resumes = Scheduler_core.close scope.scheduler in
    scope.closed <- true;
    child_resumes @ own_resumes

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
