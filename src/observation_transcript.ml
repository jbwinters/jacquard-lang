(** Policy-bound observation transcripts (OBS.1). See [observation_transcript.mli]. *)

let format_version = 1

type field =
  | Data of string
  | Truncated of { total : int; prefix : string }
  | Unsupported of string
  | Failure of string
  | Missing
  | Unfinished

type event = {
  operation : Hash.t;
  arguments : (int * field) list;
  result : field option;
  output : field option;
}

type status = Complete of field option | Failed of string | Incomplete of string
type run = { status : status; events : event list }
type transcript = { identity : Hash.t; runs : run list }

let policy_identity (transcript : transcript) = transcript.identity
let runs transcript = transcript.runs

type pending = {
  operation : Hash.t;
  rule : Observation_policy.rule;
  mutable arguments : (int * field) list;
  mutable result_seen : field option option;  (** [Some _] once the Result event arrived *)
  mutable output_seen : (string * int) option;
      (** every output chunk of the call, in order: its first [field_bytes] bytes and its length *)
}

type recorder = {
  policy : Observation_policy.t;
  mutable completed_rev : run list;
  mutable current_rev : pending list;
  by_call : (int, pending) Hashtbl.t;  (** the current run's recorded calls, by correlation id *)
  mutable active : bool;
}

exception Bug_observation_transcript of string

let bug format = Printf.ksprintf (fun message -> raise (Bug_observation_transcript message)) format

let create policy =
  { policy; completed_rev = []; current_rev = []; by_call = Hashtbl.create 16; active = false }

(* the opaque kinds {!Observation.of_value} produces *)
let opaque_kinds =
  [
    "secret";
    "closure";
    "resumption";
    "builtin";
    "operation";
    "constructor";
    "task";
    "channel";
    "capability";
    "opaque";
  ]

let rec first_opaque = function
  | Observation.Opaque kind -> Some kind
  | Observation.Tuple items -> List.find_map first_opaque items
  | Observation.Constructor { arguments; _ } -> List.find_map first_opaque arguments
  | Observation.Int _ | Observation.Real _ | Observation.Text _ | Observation.Hash _
  | Observation.Code _ ->
      None

let bounded policy bytes =
  let limit = Observation_policy.field_bytes policy in
  if String.length bytes <= limit then Data bytes
  else Truncated { total = String.length bytes; prefix = String.sub bytes 0 limit }

(* a value with an opaque part has no observable rendering: comparing its marker would call two
   different secrets or closures equal, so it is recorded as unsupported and never rendered *)
(* data-v1: the Observation rendering, except that a constructor is qualified by its identity, so two
   constructors that share a display name never render alike; it draws on fuel like the projection *)
let rec render_data value =
  match value with
  | Observation.Constructor { identity; name; arguments } -> (
      Fuel_meter.tick (1 + String.length name);
      let head = name ^ "#" ^ Hash.to_hex identity in
      match arguments with
      | [] -> head
      | _ -> head ^ "(" ^ String.concat ", " (List.map render_data arguments) ^ ")")
  | Observation.Tuple items ->
      Fuel_meter.tick 1;
      "(" ^ String.concat ", " (List.map render_data items) ^ ")"
  | Observation.Int _ | Observation.Real _ | Observation.Text _ | Observation.Hash _
  | Observation.Code _ | Observation.Opaque _ ->
      Observation.render value

let field_of_value policy value =
  match first_opaque value with
  | Some kind -> Unsupported kind
  | None -> bounded policy (render_data value)

let failure_code error = Diag.code_or_uncoded (Runtime_err.to_diag error)

(* every incomplete run is stopped by its fuel budget *)
let fuel_code = "E0919"
let uncoded = "uncoded"

let recorded_arguments policy (rule : Observation_policy.rule) arguments =
  match rule.arguments with
  | Observation_policy.No_arguments -> []
  | Observation_policy.All_arguments ->
      List.mapi (fun index value -> (index, field_of_value policy value)) (Lazy.force arguments)
  | Observation_policy.Selected_arguments positions ->
      let values = Lazy.force arguments in
      List.map
        (fun position ->
          match List.nth_opt values position with
          | Some value -> (position, field_of_value policy value)
          | None -> (position, Missing))
        positions

(* the recorded event of [call]: output and results pair with their call exactly, by correlation
   id, even when calls to one operation nest or a call is captured and dispatched later *)
let pending_call recorder ~call operation =
  match Hashtbl.find_opt recorder.by_call call with
  | Some pending when Hash.equal pending.operation operation -> Some pending
  | Some _ | None -> None

(* the fields a projection that ran out of fuel could not finish *)
let unfinished_arguments (rule : Observation_policy.rule) =
  match rule.arguments with
  | Observation_policy.No_arguments -> []
  | Observation_policy.All_arguments -> [ (0, Unfinished) ]
  | Observation_policy.Selected_arguments positions ->
      List.map (fun position -> (position, Unfinished)) positions

let on_event recorder = function
  | Observation.Operation { call; operation; arguments; _ } -> (
      match Observation_policy.rule_for recorder.policy operation with
      | None -> ()
      | Some rule -> (
          (* the operation is recorded before its arguments are projected, so running out of fuel
             while projecting them keeps its identity *)
          let pending =
            { operation; rule; arguments = []; result_seen = None; output_seen = None }
          in
          recorder.current_rev <- pending :: recorder.current_rev;
          Hashtbl.replace recorder.by_call call pending;
          try pending.arguments <- recorded_arguments recorder.policy rule arguments
          with Fuel_meter.Exceeded as exceeded ->
            pending.arguments <- unfinished_arguments rule;
            raise exceeded))
  | Observation.Output { call; operation; bytes } -> (
      (* a trusted adapter may emit several chunks for one call: all of them are its output, kept
         as a bounded prefix and a total length *)
      match pending_call recorder ~call operation with
      | Some pending -> (
          match pending.rule.output with
          | Observation_policy.Ignore -> ()
          | Observation_policy.Compare ->
              let limit = Observation_policy.field_bytes recorder.policy in
              let prefix, total = Option.value pending.output_seen ~default:("", 0) in
              let room = max 0 (limit - String.length prefix) in
              let kept = String.sub bytes 0 (min room (String.length bytes)) in
              pending.output_seen <- Some (prefix ^ kept, total + String.length bytes))
      | None -> ())
  | Observation.Result { call; operation; result } -> (
      match pending_call recorder ~call operation with
      | Some pending when Option.is_none pending.result_seen -> (
          match pending.rule.result with
          | Observation_policy.Ignore -> pending.result_seen <- Some None
          | Observation_policy.Compare -> (
              try
                pending.result_seen <-
                  Some
                    (Some
                       (match Lazy.force result with
                       | Ok value -> field_of_value recorder.policy value
                       | Error error -> Failure (failure_code error)))
              with Fuel_meter.Exceeded as exceeded ->
                pending.result_seen <- Some (Some Unfinished);
                raise exceeded))
      | Some _ | None -> ())

let finished (pending : pending) =
  let compared field seen =
    match field with
    | Observation_policy.Ignore -> None
    | Observation_policy.Compare -> (
        match seen with Some (Some field) -> Some field | Some None | None -> Some Missing)
  in
  {
    operation = pending.operation;
    arguments = pending.arguments;
    result = compared pending.rule.result pending.result_seen;
    output =
      (match pending.rule.output with
      | Observation_policy.Ignore -> None
      | Observation_policy.Compare -> (
          match pending.output_seen with
          | None -> Some Missing
          | Some (prefix, total) when total = String.length prefix -> Some (Data prefix)
          | Some (prefix, total) -> Some (Truncated { total; prefix })));
  }

let record recorder ctx run =
  if recorder.active then bug "a recorder cannot record overlapping runs";
  recorder.active <- true;
  recorder.current_rev <- [];
  Hashtbl.reset recorder.by_call;
  Fun.protect
    ~finally:(fun () ->
      recorder.current_rev <- [];
      Hashtbl.reset recorder.by_call;
      recorder.active <- false)
    (fun () ->
      let outcome = Eval.with_observer ctx (on_event recorder) run in
      let status =
        match outcome with
        | Ok value -> (
            match Observation_policy.result recorder.policy with
            | Observation_policy.Ignore -> Complete None
            | Observation_policy.Compare -> (
                (* the result's data-v1 rendering draws on the same fuel; if it runs out, the
                   observation is incomplete rather than lost *)
                match field_of_value recorder.policy (Observation.of_value value) with
                | field -> Complete (Some field)
                | exception Fuel_meter.Exceeded -> Incomplete fuel_code))
        | Error error when Runtime_err.is_fuel_exhausted error -> Incomplete fuel_code
        | Error error -> Failed (failure_code error)
      in
      let events = List.rev_map finished recorder.current_rev in
      recorder.completed_rev <- { status; events } :: recorder.completed_rev;
      outcome)

let transcript recorder =
  if recorder.active then bug "cannot inspect a recorder while a run is active";
  { identity = Observation_policy.identity recorder.policy; runs = List.rev recorder.completed_rev }

(* canonical encoding *)

let add_field buffer = function
  | Data bytes -> Printf.bprintf buffer "data bytes=%d\n%s\n" (String.length bytes) bytes
  | Truncated { total; prefix } ->
      Printf.bprintf buffer "truncated total=%d bytes=%d\n%s\n" total (String.length prefix) prefix
  | Unsupported kind -> Printf.bprintf buffer "unsupported kind=%s\n" kind
  | Failure code -> Printf.bprintf buffer "failure code=%s\n" code
  | Missing -> Buffer.add_string buffer "missing\n"
  | Unfinished -> Buffer.add_string buffer "unfinished\n"

let serialize transcript =
  let buffer = Buffer.create 256 in
  Printf.bprintf buffer "jacquard-observation-transcript format=%d policy=%s runs=%d\n"
    format_version (Hash.to_hex transcript.identity) (List.length transcript.runs);
  List.iteri
    (fun run_index run ->
      let events = List.length run.events in
      (match run.status with
      | Complete value -> (
          Printf.bprintf buffer "run index=%d status=complete events=%d\n" run_index events;
          match value with
          | Some field ->
              Buffer.add_string buffer "value ";
              add_field buffer field
          | None -> ())
      | Failed code ->
          Printf.bprintf buffer "run index=%d status=failed code=%s events=%d\n" run_index code
            events
      | Incomplete code ->
          Printf.bprintf buffer "run index=%d status=incomplete code=%s events=%d\n" run_index code
            events);
      List.iteri
        (fun event_index (event : event) ->
          Printf.bprintf buffer "event index=%d operation=%s arguments=%d\n" event_index
            (Hash.to_hex event.operation) (List.length event.arguments);
          List.iter
            (fun (position, field) ->
              Printf.bprintf buffer "argument index=%d " position;
              add_field buffer field)
            event.arguments;
          Option.iter
            (fun field ->
              Buffer.add_string buffer "result ";
              add_field buffer field)
            event.result;
          Option.iter
            (fun field ->
              Buffer.add_string buffer "output ";
              add_field buffer field)
            event.output)
        run.events)
    transcript.runs;
  Buffer.contents buffer

(* strict decoding *)

let transcript_error cause =
  Error
    [
      Diag.error ~domain:Warp ~code:"E1006"
        ~summary:"The observation transcript is invalid or was recorded under another policy."
        ~cause
        ~next_step:
          "Use canonical observation-transcript-v1 bytes recorded by this Jacquard version under \
           the same observation policy."
        ~contrast:None ();
    ]

let invalid_at offset detail =
  transcript_error
    (Printf.sprintf "Invalid observation transcript at byte offset %d: %s" offset detail)

let diagnostics_at offset detail = Result.get_error (invalid_at offset detail)
let expect cursor literal = Strict_cursor.expect_literal ~invalid:diagnostics_at cursor literal
let unsigned cursor = Strict_cursor.parse_unsigned ~invalid:diagnostics_at cursor
let hash cursor = Strict_cursor.parse_hash ~invalid:diagnostics_at cursor

let word cursor =
  let offset = cursor.Strict_cursor.offset in
  match Strict_cursor.parse_word cursor with
  | "" -> invalid_at offset "a word field is empty"
  | word -> Ok word

let parse_field policy cursor =
  let ( let* ) = Result.bind in
  let limit = Observation_policy.field_bytes policy in
  let payload bytes =
    let* () = expect cursor "\n" in
    let* payload = Strict_cursor.read_payload ~invalid:diagnostics_at cursor bytes in
    let* () = expect cursor "\n" in
    Ok payload
  in
  let offset = cursor.Strict_cursor.offset in
  if Strict_cursor.peek_literal cursor "data " then
    let* () = expect cursor "data bytes=" in
    let* bytes = unsigned cursor in
    let* () =
      if bytes <= limit then Ok () else invalid_at offset "a data field exceeds the limit"
    in
    Result.map (fun bytes -> Data bytes) (payload bytes)
  else if Strict_cursor.peek_literal cursor "truncated " then
    let* () = expect cursor "truncated total=" in
    let* total = unsigned cursor in
    let* () = expect cursor " bytes=" in
    let* bytes = unsigned cursor in
    let* () =
      if bytes = limit && total > limit then Ok ()
      else invalid_at offset "a truncated field does not match the policy's limit"
    in
    Result.map (fun prefix -> Truncated { total; prefix }) (payload bytes)
  else if Strict_cursor.peek_literal cursor "unsupported " then
    let* () = expect cursor "unsupported kind=" in
    let offset = cursor.Strict_cursor.offset in
    let* kind = word cursor in
    let* () =
      if List.mem kind opaque_kinds then Ok () else invalid_at offset "an opaque kind is unknown"
    in
    let* () = expect cursor "\n" in
    Ok (Unsupported kind)
  else if Strict_cursor.peek_literal cursor "failure " then
    let* () = expect cursor "failure code=" in
    let* code = word cursor in
    let* () = expect cursor "\n" in
    Ok (Failure code)
  else if Strict_cursor.peek_literal cursor "unfinished" then
    let* () = expect cursor "unfinished\n" in
    Ok Unfinished
  else
    let* () = expect cursor "missing\n" in
    Ok Missing

(* a failure is only a handler result; a missing field only something the policy asked for that the
   run did not produce, never a run's own value *)
let checked_field ?(unsupported = true) ?(unfinished = true) ~offset ~failure ~missing field =
  match field with
  | Failure _ when not failure -> invalid_at offset "a failure appears outside a result"
  | Missing when not missing -> invalid_at offset "a field the run always has is missing"
  | Unsupported _ when not unsupported -> invalid_at offset "raw output cannot be unsupported"
  | Unfinished when not unfinished -> invalid_at offset "this field cannot be unfinished"
  | Data _ | Truncated _ | Unsupported _ | Failure _ | Missing | Unfinished -> Ok field

let parse_event policy cursor ~expected_index =
  let ( let* ) = Result.bind in
  let* () = expect cursor "event index=" in
  let* index = unsigned cursor in
  let* () =
    if index = expected_index then Ok ()
    else invalid_at cursor.offset "event indices are not contiguous from zero"
  in
  let* () = expect cursor " operation=" in
  let offset = cursor.Strict_cursor.offset in
  let* operation = hash cursor in
  let* rule =
    match Observation_policy.rule_for policy operation with
    | Some rule -> Ok rule
    | None -> invalid_at offset "the policy does not record this operation"
  in
  let* () = expect cursor " arguments=" in
  let* count = unsigned cursor in
  let* () = expect cursor "\n" in
  let* () =
    match rule.arguments with
    | Observation_policy.All_arguments -> Ok ()
    | Observation_policy.No_arguments ->
        if count = 0 then Ok () else invalid_at offset "the policy compares no arguments here"
    | Observation_policy.Selected_arguments positions ->
        if count = List.length positions then Ok ()
        else invalid_at offset "the argument count differs from the policy's selection"
  in
  let expected_position index =
    match rule.arguments with
    | Observation_policy.Selected_arguments positions -> List.nth positions index
    | Observation_policy.All_arguments | Observation_policy.No_arguments -> index
  in
  let rec arguments index reversed =
    if index = count then Ok (List.rev reversed)
    else
      let* () = expect cursor "argument index=" in
      let offset = cursor.Strict_cursor.offset in
      let* position = unsigned cursor in
      let* () =
        if position = expected_position index then Ok ()
        else invalid_at offset "argument positions differ from the policy's selection"
      in
      let* () = expect cursor " " in
      let* field = parse_field policy cursor in
      (* under all-arguments every recorded position exists *)
      let missing =
        match rule.arguments with
        | Observation_policy.All_arguments -> false
        | Observation_policy.No_arguments | Observation_policy.Selected_arguments _ -> true
      in
      let* field = checked_field ~offset ~failure:false ~missing field in
      arguments (index + 1) ((position, field) :: reversed)
  in
  let* arguments = arguments 0 [] in
  let optional ?unsupported ?unfinished choice literal ~failure =
    match choice with
    | Observation_policy.Ignore -> Ok None
    | Observation_policy.Compare ->
        let* () = expect cursor literal in
        let offset = cursor.Strict_cursor.offset in
        let* field = parse_field policy cursor in
        Result.map Option.some
          (checked_field ?unsupported ?unfinished ~offset ~failure ~missing:true field)
  in
  let* result = optional rule.result "result " ~failure:true in
  let* output =
    optional ~unsupported:false ~unfinished:false rule.output "output " ~failure:false
  in
  Ok { operation; arguments; result; output }

let parse_run policy cursor ~expected_index =
  let ( let* ) = Result.bind in
  let* () = expect cursor "run index=" in
  let* index = unsigned cursor in
  let* () =
    if index = expected_index then Ok ()
    else invalid_at cursor.offset "run indices are not contiguous from zero"
  in
  let* () = expect cursor " status=" in
  let offset = cursor.Strict_cursor.offset in
  let* kind = word cursor in
  let* status =
    match kind with
    | "complete" -> Ok `Complete
    | "failed" ->
        let* () = expect cursor " code=" in
        let offset = cursor.Strict_cursor.offset in
        let* code = word cursor in
        if String.equal code fuel_code then
          invalid_at offset "a run stopped by fuel is incomplete, not failed"
        else Ok (`Failed code)
    | "incomplete" ->
        let* () = expect cursor " code=" in
        let offset = cursor.Strict_cursor.offset in
        let* code = word cursor in
        if String.equal code fuel_code then Ok (`Incomplete code)
        else invalid_at offset "only fuel exhaustion (E0919) makes a run incomplete"
    | _ -> invalid_at offset "a run status is unknown"
  in
  let* () = expect cursor " events=" in
  let* count = unsigned cursor in
  let* () = expect cursor "\n" in
  let* status =
    match status with
    | `Failed code -> Ok (Failed code)
    | `Incomplete code -> Ok (Incomplete code)
    | `Complete -> (
        match Observation_policy.result policy with
        | Observation_policy.Ignore -> Ok (Complete None)
        | Observation_policy.Compare ->
            let* () = expect cursor "value " in
            let offset = cursor.Strict_cursor.offset in
            let* field = parse_field policy cursor in
            let* field =
              checked_field ~unfinished:false ~offset ~failure:false ~missing:false field
            in
            Ok (Complete (Some field)))
  in
  let rec events index reversed =
    if index = count then Ok (List.rev reversed)
    else
      let* event = parse_event policy cursor ~expected_index:index in
      events (index + 1) (event :: reversed)
  in
  let* events = events 0 [] in
  (* running out of fuel does not always end a run (a fuel scope, a nested bounded invocation, or
     recording outside an invocation lets it continue), so unfinished fields and fuel-coded handler
     results may appear anywhere; the one fixed shape is that unfinished arguments mean the handler
     never ran: every selected position unfinished, no result or output *)
  let exact_unfinished (event : event) =
    let arguments_unfinished = List.exists (fun (_, field) -> field = Unfinished) event.arguments in
    let absent = function None | Some Missing -> true | Some _ -> false in
    if arguments_unfinished then
      match Observation_policy.rule_for policy event.operation with
      | Some rule ->
          event.arguments = unfinished_arguments rule && absent event.result && absent event.output
      | None -> false
    else true
  in
  if List.for_all exact_unfinished events then Ok { status; events }
  else invalid_at cursor.offset "unfinished arguments do not have the shape the recorder writes"

let parse ~policy bytes =
  let ( let* ) = Result.bind in
  let cursor = Strict_cursor.create bytes in
  let* () = expect cursor "jacquard-observation-transcript format=" in
  let* version = unsigned cursor in
  let* () =
    if version = format_version then Ok ()
    else invalid_at cursor.offset "the transcript format version is unsupported"
  in
  let* () = expect cursor " policy=" in
  let* identity = hash cursor in
  let* () =
    if Hash.equal identity (Observation_policy.identity policy) then Ok ()
    else
      transcript_error
        "The transcript was recorded under a different observation policy than the one supplied."
  in
  let* () = expect cursor " runs=" in
  let* count = unsigned cursor in
  let* () = expect cursor "\n" in
  let rec runs index reversed =
    if index = count then Ok (List.rev reversed)
    else
      let* run = parse_run policy cursor ~expected_index:index in
      runs (index + 1) (run :: reversed)
  in
  let* runs = runs 0 [] in
  let* () =
    if Strict_cursor.at_end cursor then Ok ()
    else invalid_at cursor.offset "bytes remain after the final run"
  in
  let transcript = { identity; runs } in
  if String.equal (serialize transcript) bytes then Ok transcript
  else invalid_at 0 "the decoded bytes are not canonical observation-transcript-v1"

(* comparison *)

type position =
  | Run_position of int
  | Status_position of int
  | Value_position of int
  | Event_position of { run : int; event : int }
  | Operation_position of { run : int; event : int }
  | Argument_position of { run : int; event : int; argument : int }
  | Result_position of { run : int; event : int }
  | Output_position of { run : int; event : int }

type side = Field_side of field | Status_side of status | Operation_side of Hash.t | Missing_side
type difference = { position : position; left : side; right : side }
type verdict = Equal | Divergent of difference | Inconclusive of difference
type agreement = Same | Differs | Unsure

let compare_fields left right =
  match (left, right) with
  | Data left, Data right -> if String.equal left right then Same else Differs
  | Truncated left, Truncated right ->
      if left.total = right.total && String.equal left.prefix right.prefix then Unsure else Differs
  | Unsupported left, Unsupported right -> if String.equal left right then Unsure else Differs
  | Failure left, Failure right ->
      (* failures without a diagnostic code cannot be told apart, so they cannot be called equal *)
      if not (String.equal left right) then Differs
      else if String.equal left uncoded then Unsure
      else Same
  | Missing, Missing -> Same
  | Unfinished, _ | _, Unfinished -> Unsure
  | (Data _ | Truncated _ | Unsupported _ | Failure _ | Missing), _ -> Differs

exception Found of difference

let compare left right =
  if not (Hash.equal left.identity right.identity) then
    transcript_error "The transcripts were recorded under different observation policies."
  else
    let unsure = ref None in
    let check position left right =
      match compare_fields left right with
      | Same -> ()
      | Differs -> raise (Found { position; left = Field_side left; right = Field_side right })
      | Unsure ->
          if Option.is_none !unsure then
            unsure := Some { position; left = Field_side left; right = Field_side right }
    in
    let check_option position left right =
      match (left, right) with
      | Some left, Some right -> check position left right
      | None, None -> ()
      | Some field, None ->
          raise (Found { position; left = Field_side field; right = Missing_side })
      | None, Some field ->
          raise (Found { position; left = Missing_side; right = Field_side field })
    in
    let compare_event run event (left : event) (right : event) =
      if not (Hash.equal left.operation right.operation) then
        raise
          (Found
             {
               position = Operation_position { run; event };
               left = Operation_side left.operation;
               right = Operation_side right.operation;
             });
      let unfinished = List.exists (fun (_, field) -> field = Unfinished) in
      let rec arguments left right =
        match (left, right) with
        | [], [] -> ()
        | (position, left_field) :: left_rest, (right_position, right_field) :: right_rest ->
            if position <> right_position then
              raise
                (Found
                   {
                     position =
                       Argument_position { run; event; argument = min position right_position };
                     left = Field_side left_field;
                     right = Field_side right_field;
                   });
            check (Argument_position { run; event; argument = position }) left_field right_field;
            arguments left_rest right_rest
        | (position, field) :: _, [] ->
            raise
              (Found
                 {
                   position = Argument_position { run; event; argument = position };
                   left = Field_side field;
                   right = Missing_side;
                 })
        | [], (position, field) :: _ ->
            raise
              (Found
                 {
                   position = Argument_position { run; event; argument = position };
                   left = Missing_side;
                   right = Field_side field;
                 })
      in
      (* a projection that ran out of fuel says nothing about the arguments it did not reach *)
      if unfinished left.arguments || unfinished right.arguments then (
        if Option.is_none !unsure then
          unsure :=
            Some
              {
                position = Argument_position { run; event; argument = 0 };
                left = Operation_side left.operation;
                right = Operation_side right.operation;
              })
      else arguments left.arguments right.arguments;
      check_option (Result_position { run; event }) left.result right.result;
      check_option (Output_position { run; event }) left.output right.output
    in
    let compare_run index (left : run) (right : run) =
      (match (left.status, right.status) with
      | Complete left_value, Complete right_value ->
          check_option (Value_position index) left_value right_value
      | Failed left_code, Failed right_code when String.equal left_code right_code ->
          if String.equal left_code uncoded && Option.is_none !unsure then
            unsure :=
              Some
                {
                  position = Status_position index;
                  left = Status_side left.status;
                  right = Status_side right.status;
                }
      | Incomplete left_code, Incomplete right_code when String.equal left_code right_code ->
          (* a run stopped by fuel never produced what it would have compared next *)
          if Option.is_none !unsure then
            unsure :=
              Some
                {
                  position = Status_position index;
                  left = Status_side left.status;
                  right = Status_side right.status;
                }
      | _ ->
          raise
            (Found
               {
                 position = Status_position index;
                 left = Status_side left.status;
                 right = Status_side right.status;
               }));
      let rec events event left right =
        match (left, right) with
        | [], [] -> ()
        | left_event :: left_rest, right_event :: right_rest ->
            compare_event index event left_event right_event;
            events (event + 1) left_rest right_rest
        | (present : event) :: _, [] ->
            raise
              (Found
                 {
                   position = Event_position { run = index; event };
                   left = Operation_side present.operation;
                   right = Missing_side;
                 })
        | [], (present : event) :: _ ->
            raise
              (Found
                 {
                   position = Event_position { run = index; event };
                   left = Missing_side;
                   right = Operation_side present.operation;
                 })
      in
      events 0 left.events right.events
    in
    let rec runs index left right =
      match (left, right) with
      | [], [] -> ()
      | left_run :: left_rest, right_run :: right_rest ->
          compare_run index left_run right_run;
          runs (index + 1) left_rest right_rest
      | (present : run) :: _, [] ->
          raise
            (Found
               {
                 position = Run_position index;
                 left = Status_side present.status;
                 right = Missing_side;
               })
      | [], (present : run) :: _ ->
          raise
            (Found
               {
                 position = Run_position index;
                 left = Missing_side;
                 right = Status_side present.status;
               })
    in
    match runs 0 left.runs right.runs with
    | () -> Ok (match !unsure with Some difference -> Inconclusive difference | None -> Equal)
    | exception Found difference -> Ok (Divergent difference)

let position_path = function
  | Run_position run -> Printf.sprintf "run[%d]" run
  | Status_position run -> Printf.sprintf "run[%d].status" run
  | Value_position run -> Printf.sprintf "run[%d].value" run
  | Event_position { run; event } -> Printf.sprintf "run[%d].event[%d]" run event
  | Operation_position { run; event } -> Printf.sprintf "run[%d].event[%d].operation" run event
  | Argument_position { run; event; argument } ->
      Printf.sprintf "run[%d].event[%d].argument[%d]" run event argument
  | Result_position { run; event } -> Printf.sprintf "run[%d].event[%d].result" run event
  | Output_position { run; event } -> Printf.sprintf "run[%d].event[%d].output" run event

let render_field ~redact = function
  | Data bytes -> Printf.sprintf "%S" (redact bytes)
  | Truncated { total; prefix } ->
      Printf.sprintf "%S (truncated from %d bytes)" (redact prefix) total
  | Unsupported kind -> Printf.sprintf "<unsupported %s>" kind
  | Failure code -> Printf.sprintf "failure %s" code
  | Missing -> "<missing>"
  | Unfinished -> "<unfinished>"

let render_side ~redact = function
  | Field_side field -> render_field ~redact field
  | Status_side (Complete _) -> "complete"
  | Status_side (Failed code) -> "failed " ^ code
  | Status_side (Incomplete code) -> "incomplete " ^ code
  | Operation_side operation -> "operation=" ^ Hash.to_hex operation
  | Missing_side -> "<absent>"

let render_redacted ~redact difference =
  Printf.sprintf "  at %s:\n    - %s\n    + %s"
    (position_path difference.position)
    (render_side ~redact difference.left)
    (render_side ~redact difference.right)

let render difference = render_redacted ~redact:Fun.id difference
