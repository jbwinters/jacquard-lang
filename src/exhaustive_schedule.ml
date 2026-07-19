type bounds = { max_tasks : int; max_decisions : int; max_worlds : int }

let default_bounds = { max_tasks = 1024; max_decisions = 100_000; max_worlds = 10_000 }

type incomplete_reason =
  | Task_budget of { limit : int }
  | Decision_budget of { limit : int }
  | World_budget of { limit : int }
  | Routed_effect of { decision : int; operation : Hash.t }
  | Scheduler_refusal of string

type completeness = Complete | Incomplete of incomplete_reason list

type world = {
  result : (Value.t, Runtime_err.t) result;
  outcome : Round_robin.outcome;
  schedule : Schedule_trace.t;
}

type report = {
  worlds : world list;
  explored : int;
  worlds_started : int;
  completeness : completeness;
}

type path = World_execution of Round_robin.scheduled_outcome | Stopped_prefix of Schedule_trace.t

type work =
  | Explore of path * Schedule_trace.decision list
  | Fork of { trace : Schedule_trace.t; decision : int; chosen : Concurrency_contract.task_id }

let incomplete_reason_to_string = function
  | Task_budget { limit } -> Printf.sprintf "task budget %d exhausted" limit
  | Decision_budget { limit } -> Printf.sprintf "decision budget %d exhausted" limit
  | World_budget { limit } -> Printf.sprintf "world budget %d exhausted" limit
  | Routed_effect { decision; operation } ->
      Printf.sprintf "decision %d reached routed operation %s" decision (Hash.to_hex operation)
  | Scheduler_refusal message -> "scheduler refusal: " ^ message

let equal_reason left right =
  match (left, right) with
  | Task_budget left, Task_budget right -> left.limit = right.limit
  | Decision_budget left, Decision_budget right -> left.limit = right.limit
  | World_budget left, World_budget right -> left.limit = right.limit
  | Routed_effect left, Routed_effect right ->
      left.decision = right.decision && Hash.equal left.operation right.operation
  | Scheduler_refusal left, Scheduler_refusal right -> String.equal left right
  | Task_budget _, (Decision_budget _ | World_budget _ | Routed_effect _ | Scheduler_refusal _)
  | Decision_budget _, (Task_budget _ | World_budget _ | Routed_effect _ | Scheduler_refusal _)
  | World_budget _, (Task_budget _ | Decision_budget _ | Routed_effect _ | Scheduler_refusal _)
  | Routed_effect _, (Task_budget _ | Decision_budget _ | World_budget _ | Scheduler_refusal _)
  | Scheduler_refusal _, (Task_budget _ | Decision_budget _ | World_budget _ | Routed_effect _) ->
      false

let add_reason reasons reason =
  if List.exists (equal_reason reason) !reasons then () else reasons := !reasons @ [ reason ]

let decisions trace =
  List.filter_map
    (function Schedule_trace.Decide decision -> Some decision | Schedule_trace.Create _ -> None)
    trace.Schedule_trace.events

let scheduler_owned_routed_operations =
  Channel_contract.channel_operation_hashes
  |> List.map (fun (name, encoded) ->
      match Hash.of_hex encoded with
      | Some hash -> hash
      | None -> failwith ("Bug_exhaustive_schedule: malformed pinned hash for " ^ name))

let is_scheduler_owned_routed operation =
  List.exists (Hash.equal operation) scheduler_owned_routed_operations

let first_external_routed trace =
  List.find_map
    (function
      | Schedule_trace.Decide { sequence; operation = Schedule_trace.Routed operation; _ }
        when not (is_scheduler_owned_routed operation) ->
          Some (sequence, operation)
      | Schedule_trace.Decide _ | Schedule_trace.Create _ -> None)
    trace.Schedule_trace.events

let rec drop count values =
  if count = 0 then values else match values with [] -> [] | _ :: rest -> drop (count - 1) rest

let value_of_outcome (outcome : Round_robin.outcome) =
  match outcome with
  | { root_error = Some error; _ } -> Error error
  | { body = Concurrency_contract.Failed message; _ } -> Error (Runtime_err.Scheduler_error message)
  | { body = Concurrency_contract.Cancelled; _ } ->
      Error (Runtime_err.Scheduler_error "root task was cancelled")
  | {
   body = Concurrency_contract.Done _;
   aggregate = Scope_policy.Fail_fast_result (Concurrency_contract.Failed message);
   _;
  } ->
      Error (Runtime_err.Scheduler_error message)
  | {
   body = Concurrency_contract.Done _;
   aggregate = Scope_policy.Fail_fast_result Concurrency_contract.Cancelled;
   _;
  } ->
      Error (Runtime_err.Scheduler_error "scope was cancelled")
  | { body = Concurrency_contract.Done value; _ } -> Ok value

let reason_of_budget bounds = function
  | Round_robin.Task_limit -> Task_budget { limit = bounds.max_tasks }
  | Round_robin.Decision_limit -> Decision_budget { limit = bounds.max_decisions }

let trace_of_path = function
  | World_execution execution -> execution.Round_robin.execution_schedule
  | Stopped_prefix trace -> trace

let validate_bounds bounds =
  let invalid field value =
    Diag.error ~domain:Concurrency ~code:"E0908"
      ~summary:"Exhaustive-schedule bound must be positive"
      ~cause:
        (Printf.sprintf "The %s is %d; exhaustive bounds must be greater than zero." field value)
      ~next_step:(Printf.sprintf "Set the %s to a positive integer." field)
      ~contrast:None ()
  in
  let diagnostics =
    [
      (if bounds.max_tasks > 0 then None else Some (invalid "task budget" bounds.max_tasks));
      (if bounds.max_decisions > 0 then None
       else Some (invalid "decision budget" bounds.max_decisions));
      (if bounds.max_worlds > 0 then None else Some (invalid "world budget" bounds.max_worlds));
    ]
    |> List.filter_map Fun.id
  in
  match diagnostics with [] -> Ok () | _ -> Error diagnostics

let run_expr ctx ?(policy = Concurrency_contract.default_failure_policy) ?(bounds = default_bounds)
    expression =
  let ( let* ) = Result.bind in
  let* () = validate_bounds bounds in
  let scheduler_bounds : Round_robin.bounds =
    { max_tasks = bounds.max_tasks; max_decisions = bounds.max_decisions }
  in
  let worlds_rev = ref [] in
  let worlds_started = ref 0 in
  let reasons = ref [] in
  let execute mode =
    if !worlds_started >= bounds.max_worlds then (
      add_reason reasons (World_budget { limit = bounds.max_worlds });
      None)
    else (
      incr worlds_started;
      match
        Round_robin.run_expr_scheduled_attempt ctx ~policy ~bounds:scheduler_bounds
          ~allow_routed:false ~mode expression
      with
      | Ok (Round_robin.Finished execution) -> Some (World_execution execution)
      | Ok (Round_robin.Stopped { budget; schedule_prefix; _ }) ->
          add_reason reasons (reason_of_budget bounds budget);
          Some (Stopped_prefix schedule_prefix)
      | Error error ->
          add_reason reasons (Scheduler_refusal (Runtime_err.to_string error));
          None)
  in
  let rec drive = function
    | [] -> ()
    | Explore (Stopped_prefix _, []) :: rest -> drive rest
    | Explore (World_execution execution, []) :: rest ->
        (match first_external_routed execution.execution_schedule with
        | Some (decision, operation) -> add_reason reasons (Routed_effect { decision; operation })
        | None ->
            worlds_rev :=
              {
                result = value_of_outcome execution.execution_outcome;
                outcome = execution.execution_outcome;
                schedule = execution.execution_schedule;
              }
              :: !worlds_rev);
        drive rest
    | Explore (path, decision :: later) :: rest ->
        let trace = trace_of_path path in
        let choices =
          List.map
            (fun chosen ->
              if Concurrency_contract.compare_task_id chosen decision.chosen = 0 then
                Explore (path, later)
              else Fork { trace; decision = decision.sequence; chosen })
            decision.runnable
        in
        drive (choices @ rest)
    | Fork { trace; decision; chosen } :: rest -> (
        match execute (Round_robin.Fork_schedule { trace; decision; chosen }) with
        | None -> drive rest
        | Some path ->
            let later = decisions (trace_of_path path) |> drop (decision + 1) in
            drive (Explore (path, later) :: rest))
  in
  (match execute Round_robin.Record_schedule with
  | None -> ()
  | Some path -> drive [ Explore (path, decisions (trace_of_path path)) ]);
  let worlds = List.rev !worlds_rev in
  Ok
    {
      worlds;
      explored = List.length worlds;
      worlds_started = !worlds_started;
      completeness = (match !reasons with [] -> Complete | reasons -> Incomplete reasons);
    }
