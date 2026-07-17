type mode =
  | Record
  | Record_with of
      (sequence:int ->
      runnable:Concurrency_contract.task_id list ->
      (Concurrency_contract.task_id, Diag.t list) result)
  | Replay of Schedule_trace.t
  | Fork of { trace : Schedule_trace.t; decision : int; chosen : Concurrency_contract.task_id }

type cursor = { mutable remaining : Schedule_trace.event list }

type replay_state =
  | Recording
  | Strict of cursor
  | Forking of {
      cursor : cursor;
      decision : int;
      chosen : Concurrency_contract.task_id;
      mutable forked : bool;
    }

type current = {
  sequence : int;
  runnable : Concurrency_contract.task_id list;
  chosen : Concurrency_contract.task_id;
  expected_operation : Schedule_trace.operation option;
  mutable operation : Schedule_trace.operation option;
  mutable creations_rev : Schedule_trace.event list;
}

type t = {
  mode : mode;
  scheduler : string;
  program : Hash.t;
  policy : Concurrency_contract.failure_policy;
  max_tasks : int;
  max_decisions : int;
  provenance : Schedule_trace.fork option;
  replay : replay_state;
  mutable current : current option;
  mutable events_rev : Schedule_trace.event list;
}

let error message =
  Error
    [
      Diag.error ~code:"E0908" ~hint:"re-record the schedule or use an explicit valid fork"
        ("schedule replay drift: " ^ message);
    ]

let equal_id left right = Concurrency_contract.compare_task_id left right = 0
let id_text = Concurrency_contract.trace_task_id
let equal_ids left right = List.length left = List.length right && List.for_all2 equal_id left right
let queue_text queue = "[" ^ String.concat "," (List.map id_text queue) ^ "]"

let equal_operation left right =
  match (left, right) with
  | Schedule_trace.Return, Schedule_trace.Return
  | Schedule_trace.Failure, Schedule_trace.Failure
  | Schedule_trace.Async_spawn, Schedule_trace.Async_spawn
  | Schedule_trace.Async_await, Schedule_trace.Async_await
  | Schedule_trace.Async_cancel, Schedule_trace.Async_cancel
  | Schedule_trace.Async_yield, Schedule_trace.Async_yield
  | Schedule_trace.Async_scope, Schedule_trace.Async_scope ->
      true
  | Schedule_trace.Routed left, Schedule_trace.Routed right -> Hash.equal left right
  | _ -> false

let equal_creation left right =
  left.Schedule_trace.scope_path = right.Schedule_trace.scope_path
  && equal_id left.task right.task
  &&
  match (left.parent, right.parent) with
  | None, None -> true
  | Some left, Some right -> equal_id left right
  | None, Some _ | Some _, None -> false

let validate_trace trace = Schedule_trace.parse (Schedule_trace.serialize trace)

let check_header ~scheduler ~program ~policy ~max_tasks ~max_decisions trace =
  if not (String.equal trace.Schedule_trace.scheduler scheduler) then
    error (Printf.sprintf "scheduler identity expected %s, found %s" scheduler trace.scheduler)
  else if not (Hash.equal trace.program program) then
    error
      (Printf.sprintf "program identity expected %s, found %s" (Hash.to_hex program)
         (Hash.to_hex trace.program))
  else if trace.policy <> policy then error "failure policy differs from the recorded trace"
  else if trace.max_tasks <> max_tasks then error "max-tasks differs from the recorded trace"
  else if trace.max_decisions <> max_decisions then
    error "max-decisions differs from the recorded trace"
  else Ok ()

let create ~scheduler ~program ~policy ~max_tasks ~max_decisions mode =
  let ( let* ) = Result.bind in
  let* replay, provenance =
    match mode with
    | Record | Record_with _ -> Ok (Recording, None)
    | Replay trace ->
        let* trace = validate_trace trace in
        let* () = check_header ~scheduler ~program ~policy ~max_tasks ~max_decisions trace in
        Ok (Strict { remaining = trace.events }, trace.fork)
    | Fork { trace; decision; chosen } ->
        if decision < 0 then error "fork decision must be non-negative"
        else
          let* trace = validate_trace trace in
          let* () = check_header ~scheduler ~program ~policy ~max_tasks ~max_decisions trace in
          Ok
            ( Forking { cursor = { remaining = trace.events }; decision; chosen; forked = false },
              Some Schedule_trace.{ decision; chosen } )
  in
  Ok
    {
      mode;
      scheduler;
      program;
      policy;
      max_tasks;
      max_decisions;
      provenance;
      replay;
      current = None;
      events_rev = [];
    }

let creation controller actual =
  let validate_expected () =
    match controller.replay with
    | Recording -> Ok ()
    | Strict state -> (
        match state.remaining with
        | Schedule_trace.Create expected :: rest when equal_creation expected actual ->
            state.remaining <- rest;
            Ok ()
        | Schedule_trace.Create expected :: _ ->
            error
              (Printf.sprintf "creation expected task=%s parent=%s, found task=%s parent=%s"
                 (id_text expected.task)
                 (Option.fold ~none:"-" ~some:id_text expected.parent)
                 (id_text actual.task)
                 (Option.fold ~none:"-" ~some:id_text actual.parent))
        | Schedule_trace.Decide decision :: _ ->
            error
              (Printf.sprintf "unexpected creation of %s before recorded decision %d"
                 (id_text actual.task) decision.sequence)
        | [] -> error ("unexpected creation of " ^ id_text actual.task ^ " after trace EOF"))
    | Forking state when state.forked -> Ok ()
    | Forking state -> (
        match state.cursor.remaining with
        | Schedule_trace.Create expected :: rest when equal_creation expected actual ->
            state.cursor.remaining <- rest;
            Ok ()
        | Schedule_trace.Create expected :: _ ->
            error
              (Printf.sprintf "creation expected %s, found %s" (id_text expected.task)
                 (id_text actual.task))
        | Schedule_trace.Decide decision :: _ ->
            error
              (Printf.sprintf "unexpected creation before recorded decision %d" decision.sequence)
        | [] -> error "unexpected creation after trace EOF")
  in
  Result.map
    (fun () ->
      let event = Schedule_trace.Create actual in
      match controller.current with
      | None -> controller.events_rev <- event :: controller.events_rev
      | Some current -> current.creations_rev <- event :: current.creations_rev)
    (validate_expected ())

let recorded_decision state sequence runnable =
  match state.remaining with
  | Schedule_trace.Decide expected :: rest ->
      if expected.sequence <> sequence then
        error (Printf.sprintf "expected decision sequence %d, found %d" expected.sequence sequence)
      else if not (equal_ids expected.runnable runnable) then
        error
          (Printf.sprintf "decision %d runnable queue expected %s, found %s" sequence
             (queue_text expected.runnable) (queue_text runnable))
      else (
        state.remaining <- rest;
        Ok expected)
  | Schedule_trace.Create creation :: _ ->
      error
        (Printf.sprintf "recorded creation of %s was not observed before decision %d"
           (id_text creation.task) sequence)
  | [] -> error (Printf.sprintf "missing decision %d at trace EOF" sequence)

let begin_decision controller ~sequence ~runnable =
  if Option.is_some controller.current then error "a prior decision was not finished"
  else
    let ( let* ) = Result.bind in
    let* chosen, expected_operation =
      match controller.replay with
      | Recording -> (
          match controller.mode with
          | Record -> (
              match runnable with
              | chosen :: _ -> Ok (chosen, None)
              | [] -> error "cannot choose from an empty runnable queue")
          | Record_with choose ->
              Result.map (fun chosen -> (chosen, None)) (choose ~sequence ~runnable)
          | Replay _ | Fork _ -> assert false)
      | Strict state ->
          let* expected = recorded_decision state sequence runnable in
          Ok (expected.chosen, Some expected.operation)
      | Forking state when state.forked -> (
          match runnable with
          | chosen :: _ -> Ok (chosen, None)
          | [] -> error "cannot choose from an empty runnable queue")
      | Forking state ->
          let* expected = recorded_decision state.cursor sequence runnable in
          if sequence < state.decision then Ok (expected.chosen, Some expected.operation)
          else if sequence = state.decision then
            if List.exists (equal_id state.chosen) runnable then (
              state.forked <- true;
              Ok (state.chosen, None))
            else
              error
                (Printf.sprintf "fork decision %d requested non-runnable task %s from %s" sequence
                   (id_text state.chosen) (queue_text runnable))
          else error (Printf.sprintf "fork decision %d was skipped" state.decision)
    in
    if not (List.exists (equal_id chosen) runnable) then
      error
        (Printf.sprintf "decision %d recorded impossible chosen task %s outside %s" sequence
           (id_text chosen) (queue_text runnable))
    else (
      controller.current <-
        Some
          { sequence; runnable; chosen; expected_operation; operation = None; creations_rev = [] };
      Ok chosen)

let observe_operation controller operation =
  match controller.current with
  | None -> error "an operation was observed outside a decision"
  | Some { operation = Some _; _ } -> error "a decision observed more than one operation"
  | Some current ->
      let result =
        match current.expected_operation with
        | None -> Ok ()
        | Some expected when equal_operation expected operation -> Ok ()
        | Some expected ->
            error
              (Printf.sprintf "decision %d operation expected %s, found %s" current.sequence
                 (Schedule_trace.operation_to_string expected)
                 (Schedule_trace.operation_to_string operation))
      in
      Result.map (fun () -> current.operation <- Some operation) result

let finish_decision controller =
  match controller.current with
  | None -> error "no scheduler decision is active"
  | Some { operation = None; sequence; _ } ->
      error (Printf.sprintf "decision %d did not observe an operation" sequence)
  | Some current ->
      let decision =
        Schedule_trace.Decide
          {
            sequence = current.sequence;
            runnable = current.runnable;
            chosen = current.chosen;
            operation = Option.get current.operation;
          }
      in
      let chronological = decision :: List.rev current.creations_rev in
      controller.events_rev <- List.rev_append chronological controller.events_rev;
      controller.current <- None;
      Ok ()

let finish controller =
  let ( let* ) = Result.bind in
  let* () =
    match controller.current with
    | Some current -> error (Printf.sprintf "decision %d was not finished" current.sequence)
    | None -> Ok ()
  in
  let* () =
    match controller.replay with
    | Recording -> Ok ()
    | Strict { remaining = [] } -> Ok ()
    | Strict { remaining = event :: _ } ->
        error
          ("recorded event was not reached: "
          ^
          match event with
          | Schedule_trace.Create creation -> "create " ^ id_text creation.task
          | Schedule_trace.Decide decision -> "decision " ^ string_of_int decision.sequence)
    | Forking { forked = false; decision; _ } ->
        error (Printf.sprintf "fork decision %d was not reached" decision)
    | Forking { forked = true; _ } -> Ok ()
  in
  Schedule_trace.make ~scheduler:controller.scheduler ~program:controller.program
    ~policy:controller.policy ~max_tasks:controller.max_tasks
    ~max_decisions:controller.max_decisions ?fork:controller.provenance
    (List.rev controller.events_rev)
