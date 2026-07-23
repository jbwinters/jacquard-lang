type 'value child = {
  handle : Structured_scope.handle;
  id : Concurrency_contract.task_id;
  mutable terminal : 'value Concurrency_contract.task_result option;
}

type frozen_non_success = Frozen_failed of string | Frozen_cancelled

type ('resume, 'value) t = {
  scope : ('resume, 'value) Structured_scope.t;
  policy : Concurrency_contract.failure_policy;
  mutable children : 'value child list;
  mutable last_observation : (int * int) option;
  mutable first_non_success : frozen_non_success option;
  mutable awakened : Structured_scope.handle list;
}

type 'value aggregate =
  | Fail_fast_result of 'value Concurrency_contract.fail_fast_result
  | Collect_result of 'value Concurrency_contract.collect_result

let diagnostic message =
  Error
    [
      Diag.error ~domain:Concurrency ~code:"E0908"
        ~summary:"Structured-concurrency scope policy is invalid"
        ~cause:("The scope policy state is inconsistent: " ^ message)
        ~next_step:"Record each child terminal state once in scheduler decision order."
        ~contrast:None ();
    ]

let child_name child = Concurrency_contract.trace_task_id child.id

let create ?(policy = Concurrency_contract.default_failure_policy) scope ~children =
  let rec validate seen acc = function
    | [] ->
        Ok
          {
            scope;
            policy;
            children = List.rev acc;
            last_observation = None;
            first_non_success = None;
            awakened = [];
          }
    | handle :: rest ->
        Result.bind (Structured_scope.id scope handle) (fun id ->
            if List.exists (fun prior -> Concurrency_contract.compare_task_id prior id = 0) seen
            then diagnostic ("duplicate child " ^ Concurrency_contract.trace_task_id id)
            else validate (id :: seen) ({ handle; id; terminal = None } :: acc) rest)
  in
  validate [] [] children

let policy controller = controller.policy

let take_awakened controller =
  let awakened = controller.awakened in
  controller.awakened <- [];
  awakened

let register_child controller handle =
  Result.bind (Structured_scope.id controller.scope handle) (fun id ->
      if
        List.exists
          (fun child -> Concurrency_contract.compare_task_id child.id id = 0)
          controller.children
      then diagnostic ("duplicate child " ^ Concurrency_contract.trace_task_id id)
      else (
        controller.children <- controller.children @ [ { handle; id; terminal = None } ];
        Ok ()))

let find_child controller id =
  List.find_opt
    (fun child -> Concurrency_contract.compare_task_id child.id id = 0)
    controller.children

let cancellation_point = function
  | Scheduler_core.Yielded -> Concurrency_contract.Yield
  | Scheduler_core.Awaiting _ -> Concurrency_contract.Await
  | Scheduler_core.Channel_sending _ | Scheduler_core.Channel_receiving _
  | Scheduler_core.Host_readiness _ ->
      Concurrency_contract.Routed_effect

let cancel_unfinished controller ~drop =
  let ( let* ) = Result.bind in
  let diagnostics = ref [] in
  let first_exception = ref None in
  let awakened = ref [] in
  let remember_exception exn backtrace =
    if Option.is_none !first_exception then first_exception := Some (exn, backtrace)
  in
  let guarded_drop resume =
    match drop resume with
    | () -> ()
    | exception exn -> remember_exception exn (Printexc.get_raw_backtrace ())
  in
  let attempt operation =
    match operation () with
    | Ok woken -> awakened := !awakened @ woken
    | Error errors -> diagnostics := !diagnostics @ errors
    | exception exn -> remember_exception exn (Printexc.get_raw_backtrace ())
  in
  let cancel child =
    let* view = Structured_scope.inspect controller.scope child.handle in
    match (view.result, view.suspension) with
    | Some _, _ -> Ok []
    | None, suspension -> (
        let* () = Structured_scope.request_cancel controller.scope child.handle in
        match suspension with
        | None -> Ok []
        | Some suspension ->
            Structured_scope.deliver_cancel controller.scope ~point:(cancellation_point suspension)
              child.handle ~drop:guarded_drop)
  in
  List.iter (fun child -> attempt (fun () -> cancel child)) controller.children;
  controller.awakened <- controller.awakened @ !awakened;
  match !first_exception with
  | Some (exn, backtrace) -> Printexc.raise_with_backtrace exn backtrace
  | None -> if !diagnostics = [] then Ok () else Error !diagnostics

let valid_observation controller decision ordinal =
  if decision < 0 then diagnostic "decision sequence must be non-negative"
  else if ordinal < 0 then diagnostic "terminal observation ordinal must be non-negative"
  else
    match controller.last_observation with
    | Some (previous_decision, previous_ordinal)
      when decision < previous_decision
           || (decision = previous_decision && ordinal <= previous_ordinal) ->
        diagnostic
          (Printf.sprintf "terminal observation (%d,%d) does not follow (%d,%d)" decision ordinal
             previous_decision previous_ordinal)
    | None | Some _ -> Ok ()

let record_terminal controller ~decision ?(ordinal = 0) handle ~drop =
  Result.bind (valid_observation controller decision ordinal) (fun () ->
      Result.bind (Structured_scope.id controller.scope handle) (fun id ->
          match find_child controller id with
          | None ->
              diagnostic
                ("task " ^ Concurrency_contract.trace_task_id id ^ " is not a registered child")
          | Some child when Option.is_some child.terminal ->
              diagnostic ("child " ^ child_name child ^ " was already observed terminal")
          | Some child ->
              Result.bind (Structured_scope.inspect controller.scope child.handle) (fun view ->
                  match view.result with
                  | None -> diagnostic ("child " ^ child_name child ^ " is not terminal")
                  | Some result -> (
                      controller.last_observation <- Some (decision, ordinal);
                      child.terminal <- Some result;
                      match (controller.policy, result, controller.first_non_success) with
                      | Concurrency_contract.Fail_fast, Concurrency_contract.Failed message, None ->
                          controller.first_non_success <- Some (Frozen_failed message);
                          cancel_unfinished controller ~drop
                      | Concurrency_contract.Fail_fast, Concurrency_contract.Cancelled, None ->
                          controller.first_non_success <- Some Frozen_cancelled;
                          cancel_unfinished controller ~drop
                      | _ -> Ok ()))))

let finish controller =
  let results = List.map (fun child -> child.terminal) controller.children in
  if List.exists Option.is_none results then
    diagnostic "scope results requested before all children terminated"
  else
    let results = List.map Option.get results in
    match controller.policy with
    | Concurrency_contract.Collect -> Ok (Collect_result results)
    | Concurrency_contract.Fail_fast -> (
        match controller.first_non_success with
        | Some (Frozen_failed message) ->
            Ok (Fail_fast_result (Concurrency_contract.Failed message))
        | Some Frozen_cancelled -> Ok (Fail_fast_result Concurrency_contract.Cancelled)
        | None ->
            let rec values acc = function
              | [] -> Ok (List.rev acc)
              | Concurrency_contract.Done value :: rest -> values (value :: acc) rest
              | (Concurrency_contract.Failed _ | Concurrency_contract.Cancelled) :: _ ->
                  diagnostic "terminal summary disagrees with the selected fail-fast result"
            in
            Result.map
              (fun values -> Fail_fast_result (Concurrency_contract.Done values))
              (values [] results))
