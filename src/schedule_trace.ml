let format_version = 1

type operation =
  | Return
  | Failure
  | Async_spawn
  | Async_await
  | Async_cancel
  | Async_yield
  | Async_scope
  | Routed of Hash.t

type creation = {
  scope_path : int list;
  task : Concurrency_contract.task_id;
  parent : Concurrency_contract.task_id option;
}

type decision = {
  sequence : int;
  runnable : Concurrency_contract.task_id list;
  chosen : Concurrency_contract.task_id;
  operation : operation;
}

type event = Create of creation | Decide of decision
type fork = { decision : int; chosen : Concurrency_contract.task_id }

type t = {
  scheduler : string;
  program : Hash.t;
  policy : Concurrency_contract.failure_policy;
  max_tasks : int;
  max_decisions : int;
  fork : fork option;
  events : event list;
}

let error message =
  Error
    [
      Diag.error ~code:"E0908" ~hint:"record a fresh canonical v1 schedule trace"
        ("invalid schedule trace: " ^ message);
    ]

let id_text = Concurrency_contract.trace_task_id
let equal_id left right = Concurrency_contract.compare_task_id left right = 0

let policy_to_string = function
  | Concurrency_contract.Fail_fast -> "fail-fast"
  | Concurrency_contract.Collect -> "collect"

let operation_to_string = function
  | Return -> "return"
  | Failure -> "failure"
  | Async_spawn -> "async.spawn"
  | Async_await -> "async.await"
  | Async_cancel -> "async.cancel"
  | Async_yield -> "async.yield"
  | Async_scope -> "async.scope"
  | Routed hash -> "routed:" ^ Hash.to_hex hash

let scope_text path = String.concat "/" (List.map string_of_int path)

let fork_text = function
  | None -> "-"
  | Some fork -> Printf.sprintf "%d:%s" fork.decision (id_text fork.chosen)

let event_to_string = function
  | Create creation ->
      Printf.sprintf "create scope=%s task=%s parent=%s" (scope_text creation.scope_path)
        (id_text creation.task)
        (Option.fold ~none:"-" ~some:id_text creation.parent)
  | Decide decision ->
      Printf.sprintf "decision sequence=%d runnable=%s chosen=%s operation=%s" decision.sequence
        (String.concat "," (List.map id_text decision.runnable))
        (id_text decision.chosen)
        (operation_to_string decision.operation)

let serialize trace =
  let header =
    Printf.sprintf
      "jacquard-schedule format=%d scheduler=%s program=%s policy=%s max-tasks=%d max-decisions=%d \
       fork=%s"
      format_version trace.scheduler (Hash.to_hex trace.program) (policy_to_string trace.policy)
      trace.max_tasks trace.max_decisions (fork_text trace.fork)
  in
  String.concat "\n" (header :: List.map event_to_string trace.events) ^ "\n"

let validate trace =
  let ( let* ) = Result.bind in
  if String.length trace.scheduler = 0 then error "scheduler identity is empty"
  else if String.exists (fun char -> char = ' ' || char = '\n' || char = '\r') trace.scheduler then
    error "scheduler identity contains whitespace"
  else if trace.max_tasks <= 0 then error "max-tasks must be positive"
  else if trace.max_decisions <= 0 then error "max-decisions must be positive"
  else
    let* () =
      match trace.fork with
      | Some { decision; _ } when decision < 0 -> error "fork decision must be non-negative"
      | None | Some _ -> Ok ()
    in
    let root = Concurrency_contract.task_id ~scope_path:[ 0 ] ~spawn_index:0 in
    let* () =
      match trace.events with
      | Create { scope_path = [ 0 ]; task; parent = None } :: _ when equal_id task root -> Ok ()
      | _ -> error "the first event must create root task 0#0 without a parent"
    in
    let created = Hashtbl.create 32 in
    let terminal = Hashtbl.create 32 in
    let task_count = ref 0 in
    let fork_choice = ref None in
    let rec loop expected_sequence (previous_decision : decision option) = function
      | [] -> Ok ()
      | Create creation :: rest ->
          let task = id_text creation.task in
          if creation.task.scope_path <> creation.scope_path then
            error
              (Printf.sprintf "task %s does not belong to scope %s" task
                 (scope_text creation.scope_path))
          else if Hashtbl.mem created task then error ("task " ^ task ^ " is created more than once")
          else if !task_count >= trace.max_tasks then
            error (Printf.sprintf "trace creates more than max-tasks %d tasks" trace.max_tasks)
          else
            let* () =
              match creation.parent with
              | None when !task_count = 0 -> Ok ()
              | None -> error "only root task 0#0 may omit its parent"
              | Some parent when not (Hashtbl.mem created (id_text parent)) ->
                  error ("creation parent " ^ id_text parent ^ " does not exist yet")
              | Some parent -> (
                  match previous_decision with
                  | Some decision when equal_id parent decision.chosen -> (
                      match decision.operation with
                      | Async_spawn
                        when creation.scope_path = parent.scope_path
                             && creation.task.spawn_index > 0 ->
                          Ok ()
                      | Async_scope
                        when creation.task.spawn_index = 0
                             && List.length creation.scope_path = List.length parent.scope_path + 1
                             && List.for_all2 ( = ) parent.scope_path
                                  (List.rev (List.tl (List.rev creation.scope_path))) ->
                          Ok ()
                      | Async_spawn ->
                          error "async.spawn must create a non-body task in its parent's scope"
                      | Async_scope ->
                          error "async.scope must create a body task in a direct child scope"
                      | Return | Failure | Async_await | Async_cancel | Async_yield | Routed _ ->
                          error
                            (Printf.sprintf "operation %s cannot create a task"
                               (operation_to_string decision.operation)))
                  | Some decision ->
                      error
                        (Printf.sprintf "creation parent %s is not decision %d's chosen task %s"
                           (id_text parent) decision.sequence (id_text decision.chosen))
                  | None -> error "a non-root creation must follow a decision")
            in
            Hashtbl.add created task ();
            incr task_count;
            loop expected_sequence None rest
      | Decide decision :: rest ->
          if decision.sequence <> expected_sequence then
            error
              (Printf.sprintf "decision sequence %d was expected, found %d" expected_sequence
                 decision.sequence)
          else if expected_sequence >= trace.max_decisions then
            error
              (Printf.sprintf "trace has more than max-decisions %d decisions" trace.max_decisions)
          else if decision.runnable = [] then error "a decision has an empty runnable queue"
          else if List.length decision.runnable > trace.max_tasks then
            error
              (Printf.sprintf "decision %d runnable queue exceeds max-tasks %d" decision.sequence
                 trace.max_tasks)
          else
            let runnable = Hashtbl.create 16 in
            let rec validate_runnable = function
              | [] -> Ok ()
              | task :: tasks ->
                  let key = id_text task in
                  if Hashtbl.mem runnable key then
                    error (Printf.sprintf "decision %d repeats a runnable task" decision.sequence)
                  else if not (Hashtbl.mem created key) then
                    error
                      (Printf.sprintf "decision %d names task %s before creation" decision.sequence
                         key)
                  else if Hashtbl.mem terminal key then
                    error
                      (Printf.sprintf "terminal task %s reappears at decision %d" key
                         decision.sequence)
                  else (
                    Hashtbl.add runnable key ();
                    validate_runnable tasks)
            in
            let* () = validate_runnable decision.runnable in
            let chosen = id_text decision.chosen in
            if not (Hashtbl.mem runnable chosen) then
              error
                (Printf.sprintf "decision %d chooses %s outside its runnable queue"
                   decision.sequence chosen)
            else (
              (match trace.fork with
              | Some fork when fork.decision = decision.sequence ->
                  fork_choice := Some decision.chosen
              | None | Some _ -> ());
              (match decision.operation with
              | Return | Failure -> Hashtbl.replace terminal chosen ()
              | Async_spawn | Async_await | Async_cancel | Async_yield | Async_scope | Routed _ ->
                  ());
              loop (expected_sequence + 1) (Some decision) rest)
    in
    let* () = loop 0 None trace.events in
    let* () =
      match trace.fork with
      | None -> Ok ()
      | Some fork -> (
          match !fork_choice with
          | Some chosen when equal_id chosen fork.chosen -> Ok ()
          | Some chosen ->
              error
                (Printf.sprintf "fork provenance chooses %s but decision %d chooses %s"
                   (id_text fork.chosen) fork.decision (id_text chosen))
          | None ->
              error (Printf.sprintf "fork provenance decision %d does not exist" fork.decision))
    in
    Ok trace

let make ~scheduler ~program ~policy ~max_tasks ~max_decisions ?fork events =
  validate { scheduler; program; policy; max_tasks; max_decisions; fork; events }

let split_once char value =
  match String.index_opt value char with
  | None -> None
  | Some index ->
      Some (String.sub value 0 index, String.sub value (index + 1) (String.length value - index - 1))

let int_component label value =
  match Int64.of_string_opt value with
  | Some number when number >= 0L && number <= 0xffff_ffffL -> Ok (Int64.to_int number)
  | Some _ | None -> error (Printf.sprintf "%s %S is not an unsigned 32-bit integer" label value)

let parse_scope value =
  let ( let* ) = Result.bind in
  let pieces = String.split_on_char '/' value in
  let rec loop index acc = function
    | [] -> Ok (List.rev acc)
    | piece :: rest ->
        let* component = int_component "scope component" piece in
        if index = 0 && component <> 0 then error "a scope path must begin with zero"
        else if index > 0 && component = 0 then error "nested scope components must be one-based"
        else loop (index + 1) (component :: acc) rest
  in
  if value = "" || List.length pieces > 65_532 then error "scope path is empty or too deep"
  else loop 0 [] pieces

let parse_task value =
  let ( let* ) = Result.bind in
  match split_once '#' value with
  | None -> error (Printf.sprintf "task ID %S is missing #spawn" value)
  | Some (path, spawn) ->
      let* scope_path = parse_scope path in
      let* spawn_index = int_component "spawn index" spawn in
      Ok (Concurrency_contract.task_id ~scope_path ~spawn_index)

let task_id_of_string = parse_task

let parse_policy = function
  | "fail-fast" -> Ok Concurrency_contract.Fail_fast
  | "collect" -> Ok Concurrency_contract.Collect
  | value -> error (Printf.sprintf "unknown failure policy %S" value)

let parse_operation value =
  match value with
  | "return" -> Ok Return
  | "failure" -> Ok Failure
  | "async.spawn" -> Ok Async_spawn
  | "async.await" -> Ok Async_await
  | "async.cancel" -> Ok Async_cancel
  | "async.yield" -> Ok Async_yield
  | "async.scope" -> Ok Async_scope
  | _ when String.starts_with ~prefix:"routed:" value -> (
      let raw = String.sub value 7 (String.length value - 7) in
      match Hash.of_hex raw with
      | Some hash -> Ok (Routed hash)
      | None -> error "invalid routed hash")
  | _ -> error (Printf.sprintf "unknown operation %S" value)

let field prefix token =
  if String.starts_with ~prefix token && String.length token > String.length prefix then
    Ok (String.sub token (String.length prefix) (String.length token - String.length prefix))
  else error (Printf.sprintf "expected field %s, found %S" prefix token)

let parse_header = function
  | [ "jacquard-schedule"; format; scheduler; program; policy; max_tasks; max_decisions; fork ] ->
      let ( let* ) = Result.bind in
      let* format = field "format=" format in
      let* () =
        match int_of_string_opt format with
        | Some version when version = format_version -> Ok ()
        | Some version -> error (Printf.sprintf "unsupported format version %d" version)
        | None -> error "format version is not an integer"
      in
      let* scheduler = field "scheduler=" scheduler in
      let* program = field "program=" program in
      let* program =
        match Hash.of_hex program with Some hash -> Ok hash | None -> error "invalid program hash"
      in
      let* policy = field "policy=" policy in
      let* policy = parse_policy policy in
      let* max_tasks = field "max-tasks=" max_tasks in
      let* max_tasks =
        match int_of_string_opt max_tasks with
        | Some value -> Ok value
        | None -> error "invalid max-tasks"
      in
      let* max_decisions = field "max-decisions=" max_decisions in
      let* max_decisions =
        match int_of_string_opt max_decisions with
        | Some value -> Ok value
        | None -> error "invalid max-decisions"
      in
      let* fork = field "fork=" fork in
      let* fork =
        if String.equal fork "-" then Ok None
        else
          match split_once ':' fork with
          | None -> error "fork provenance must be DECISION:TASK or -"
          | Some (decision, chosen) ->
              let* decision =
                match int_of_string_opt decision with
                | Some value when value >= 0 -> Ok value
                | Some _ | None -> error "fork decision must be non-negative"
              in
              let* chosen = parse_task chosen in
              Ok (Some { decision; chosen })
      in
      Ok (scheduler, program, policy, max_tasks, max_decisions, fork)
  | "jacquard-schedule" :: _ -> error "malformed v1 header"
  | _ -> error "unversioned schedule traces are unsupported"

let parse_event line =
  let ( let* ) = Result.bind in
  match String.split_on_char ' ' line with
  | [ "create"; scope; task; parent ] ->
      let* scope = field "scope=" scope in
      let* scope_path = parse_scope scope in
      let* task = field "task=" task in
      let* task = parse_task task in
      let* parent = field "parent=" parent in
      let* parent =
        if String.equal parent "-" then Ok None else Result.map Option.some (parse_task parent)
      in
      Ok (Create { scope_path; task; parent })
  | [ "decision"; sequence; runnable; chosen; operation ] ->
      let* sequence = field "sequence=" sequence in
      let* sequence =
        match int_of_string_opt sequence with
        | Some value when value >= 0 -> Ok value
        | Some _ | None -> error "decision sequence must be non-negative"
      in
      let* runnable = field "runnable=" runnable in
      let* runnable =
        if runnable = "" then Ok []
        else
          let rec loop acc = function
            | [] -> Ok (List.rev acc)
            | item :: rest ->
                let* task = parse_task item in
                loop (task :: acc) rest
          in
          loop [] (String.split_on_char ',' runnable)
      in
      let* chosen = field "chosen=" chosen in
      let* chosen = parse_task chosen in
      let* operation = field "operation=" operation in
      let* operation = parse_operation operation in
      Ok (Decide { sequence; runnable; chosen; operation })
  | _ -> error (Printf.sprintf "malformed event %S" line)

let parse bytes =
  let ( let* ) = Result.bind in
  let lines = String.split_on_char '\n' bytes in
  let* lines =
    match List.rev lines with
    | "" :: reversed -> Ok (List.rev reversed)
    | _ -> error "canonical trace must end with LF"
  in
  match lines with
  | [] -> error "unversioned schedule traces are unsupported"
  | header :: event_lines ->
      let* scheduler, program, policy, max_tasks, max_decisions, fork =
        parse_header (String.split_on_char ' ' header)
      in
      let rec events acc = function
        | [] -> Ok (List.rev acc)
        | line :: rest ->
            let* event = parse_event line in
            events (event :: acc) rest
      in
      let* events = events [] event_lines in
      let* trace = make ~scheduler ~program ~policy ~max_tasks ~max_decisions ?fork events in
      if String.equal bytes (serialize trace) then Ok trace
      else error "trace bytes are not canonical"

let max_input_bytes = 64 * 1024 * 1024
let max_input_line_bytes = 1024 * 1024
let max_header_bytes = 4096
let max_input_lines = 200_001

let parse_channel channel =
  let ( let* ) = Result.bind in
  let bytes = Buffer.create 4096 in
  let chunk = Bytes.create 4096 in
  let total_bytes = ref 0 in
  let line_bytes = ref 0 in
  let line_count = ref 0 in
  let header_seen = ref false in
  let byte_limit = ref max_input_bytes in
  let line_limit = ref max_input_lines in
  let configure_from_header () =
    let header_length = Buffer.length bytes - 1 in
    let header = Buffer.sub bytes 0 header_length in
    let* _, _, _, max_tasks, max_decisions, _ = parse_header (String.split_on_char ' ' header) in
    if max_tasks <= 0 then error "max-tasks must be positive"
    else if max_decisions <= 0 then error "max-decisions must be positive"
    else
      let max_events =
        if max_tasks > max_input_lines - max_decisions then max_input_lines
        else min max_input_lines (max_tasks + max_decisions)
      in
      line_limit := min max_input_lines (max_events + 1);
      let event_byte_capacity = (max_input_bytes - max_header_bytes) / max_input_line_bytes in
      byte_limit :=
        if max_events >= event_byte_capacity then max_input_bytes
        else max_header_bytes + (max_events * max_input_line_bytes);
      header_seen := true;
      Ok ()
  in
  let rec consume index length =
    if index = length then Ok ()
    else
      let char = Bytes.get chunk index in
      incr total_bytes;
      incr line_bytes;
      let current_line_limit = if !header_seen then max_input_line_bytes else max_header_bytes in
      if !total_bytes > !byte_limit then
        error (Printf.sprintf "schedule trace input exceeds %d-byte limit" !byte_limit)
      else if !line_bytes > current_line_limit then
        error (Printf.sprintf "schedule trace line exceeds %d-byte limit" current_line_limit)
      else (
        Buffer.add_char bytes char;
        let* () =
          if char <> '\n' then Ok ()
          else (
            incr line_count;
            line_bytes := 0;
            let* () = if !header_seen then Ok () else configure_from_header () in
            if !line_count > !line_limit then
              error
                (Printf.sprintf
                   "schedule trace has more than %d lines permitted by max-tasks/max-decisions"
                   !line_limit)
            else Ok ())
        in
        consume (index + 1) length)
  in
  let rec read () =
    match input channel chunk 0 (Bytes.length chunk) with
    | 0 -> parse (Buffer.contents bytes)
    | length ->
        let* () = consume 0 length in
        read ()
  in
  read ()

let identity trace = Hash.of_string (serialize trace)
