(** Explicit, interpreter-only recording plus strict parsing and semantic comparison for the frozen
    [run-transcript-v1] observation format. *)

let format_version = 1

type event = { operation : Hash.t; output : string }
type observation = { value : string; trace : event list }
type transcript = Transcript of observation list

type position =
  | Observation_position of int
  | Value_position of int
  | Trace_position of { observation_index : int; trace_index : int }

type divergence_kind = Value_divergence | Trace_divergence | Length_divergence

type side =
  | Value_side of string
  | Trace_side of event
  | Observation_side of observation
  | Missing_side

type divergence = { position : position; kind : divergence_kind; left : side; right : side }
type verdict = Equal | Divergence of divergence
type pending_event = { operation : Hash.t; output : string option }

type recorder = {
  mutable completed_rev : observation list;
  mutable current_rev : pending_event list;
  mutable active : bool;
}

exception Bug_run_transcript of string

let bug format = Printf.ksprintf (fun message -> raise (Bug_run_transcript message)) format

(* [run-transcript-v1] admits output bytes only on the frozen Console.print member. This identity is
   already pinned by the 0.1 prelude goldens and by schedule/transcript evidence; keeping it beside
   the versioned decoder lets parsing remain pure while rejecting forged output attribution. *)
let console_print_operation =
  match
    Hash.of_canonical_hex "28570e6bcdeb8646a90b31971204be7007f658bee65154b96e587c47a6585d5e"
  with
  | Some operation -> operation
  | None -> bug "the frozen Console.print operation hash is malformed"

(** [create ()] starts an empty, non-reentrant transcript builder. *)
let create () = { completed_rev = []; current_rev = []; active = false }

let on_operation recorder operation =
  if not recorder.active then bug "root operation arrived outside an active recording";
  recorder.current_rev <- { operation; output = None } :: recorder.current_rev

let on_output recorder operation output =
  if not recorder.active then bug "root output arrived outside an active recording";
  let rec attach seen = function
    | [] -> bug "root output for %s has no pending root operation" (Hash.to_hex operation)
    | ({ operation = current; output = None } as event) :: rest when Hash.equal current operation ->
        List.rev_append seen ({ event with output = Some output } :: rest)
    | event :: rest -> attach (event :: seen) rest
  in
  recorder.current_rev <- attach [] recorder.current_rev

(** [record_expression recorder ctx run] observes one caller-supplied evaluator or scheduler run.
    The original result is preserved exactly; only a successful [Value.t] adds an observation. *)
let record_expression recorder ctx run =
  if recorder.active then bug "a recorder cannot record overlapping expressions";
  recorder.active <- true;
  recorder.current_rev <- [];
  Fun.protect
    ~finally:(fun () ->
      recorder.current_rev <- [];
      recorder.active <- false)
    (fun () ->
      Eval.with_root_observer ctx ~on_operation:(on_operation recorder)
        ~on_output:(on_output recorder) (fun () ->
          match run () with
          | Ok value as result ->
              let observation =
                {
                  value = Value.show value ^ "\n";
                  trace =
                    List.rev_map
                      (fun (pending : pending_event) ->
                        let output = Option.value ~default:"" pending.output in
                        ({ operation = pending.operation; output } : event))
                      recorder.current_rev;
                }
              in
              recorder.completed_rev <- observation :: recorder.completed_rev;
              result
          | Error _ as result -> result))

(** [transcript recorder] snapshots completed observations. In-progress observations are never
    exposed because they are discarded on a failed or abandoned expression. *)
let transcript recorder =
  if recorder.active then bug "cannot inspect a recorder while an expression is active";
  Transcript (List.rev recorder.completed_rev)

let observations (Transcript observations) = observations

let decimal value =
  if value < 0 then bug "negative canonical count or byte length";
  string_of_int value

let add_header buffer index observation =
  Buffer.add_string buffer "observation index=";
  Buffer.add_string buffer (decimal index);
  Buffer.add_string buffer " value-bytes=";
  Buffer.add_string buffer (decimal (String.length observation.value));
  Buffer.add_string buffer " trace-events=";
  Buffer.add_string buffer (decimal (List.length observation.trace));
  Buffer.add_char buffer '\n';
  Buffer.add_string buffer observation.value

let add_event buffer index (event : event) =
  Buffer.add_string buffer "trace index=";
  Buffer.add_string buffer (decimal index);
  Buffer.add_string buffer " operation=";
  Buffer.add_string buffer (Hash.to_hex event.operation);
  Buffer.add_string buffer " output-bytes=";
  Buffer.add_string buffer (decimal (String.length event.output));
  Buffer.add_char buffer '\n';
  Buffer.add_string buffer event.output

(** [serialize] writes one header and length-framed raw result/output payloads. All indices are
    generated from immutable list order, so callers cannot construct noncontiguous encodings. *)
let serialize (Transcript completed) =
  let buffer = Buffer.create 256 in
  Buffer.add_string buffer "jacquard-run-transcript format=";
  Buffer.add_string buffer (decimal format_version);
  Buffer.add_string buffer " observations=";
  Buffer.add_string buffer (decimal (List.length completed));
  Buffer.add_char buffer '\n';
  List.iteri
    (fun observation_index observation ->
      add_header buffer observation_index observation;
      List.iteri (add_event buffer) observation.trace)
    completed;
  Buffer.contents buffer

let serialize_recorder recorder = serialize (transcript recorder)

type cursor = { bytes : string; mutable offset : int }

let invalid_at offset detail =
  Error
    [
      Diag.error ~domain:Warp ~code:"E1004" ~summary:"The run transcript is invalid."
        ~cause:(Printf.sprintf "Invalid run transcript at byte offset %d: %s" offset detail)
        ~next_step:"Use canonical run-transcript-v1 bytes recorded by this Jacquard version."
        ~contrast:None ();
    ]

let expect_literal cursor literal =
  let input_length = String.length cursor.bytes in
  let literal_length = String.length literal in
  let rec check index =
    if index = literal_length then (
      cursor.offset <- cursor.offset + literal_length;
      Ok ())
    else
      let input_index = cursor.offset + index in
      if input_index >= input_length then invalid_at input_index "a structural field is truncated"
      else if cursor.bytes.[input_index] <> literal.[index] then
        invalid_at input_index "a structural field is misspelled, reordered, or incorrectly spaced"
      else check (index + 1)
  in
  check 0

let parse_unsigned cursor =
  let input_length = String.length cursor.bytes in
  let start = cursor.offset in
  let digit_at index =
    if index >= input_length then None
    else
      match cursor.bytes.[index] with
      | '0' .. '9' as char -> Some (Char.code char - Char.code '0')
      | _ -> None
  in
  match digit_at start with
  | None -> invalid_at start "an unsigned decimal field has no digits"
  | Some _ ->
      let rec scan index value =
        match digit_at index with
        | None -> Ok (index, value)
        | Some digit ->
            if value > (max_int - digit) / 10 then
              invalid_at index "an unsigned decimal field exceeds the supported range"
            else scan (index + 1) ((value * 10) + digit)
      in
      let ( let* ) = Result.bind in
      let* stop, value = scan start 0 in
      if cursor.bytes.[start] = '0' && stop - start > 1 then
        invalid_at start "an unsigned decimal field has a leading zero"
      else (
        cursor.offset <- stop;
        Ok value)

let read_payload cursor byte_length =
  let available = String.length cursor.bytes - cursor.offset in
  if byte_length > available then invalid_at cursor.offset "a declared payload is truncated"
  else
    let payload = String.sub cursor.bytes cursor.offset byte_length in
    cursor.offset <- cursor.offset + byte_length;
    Ok payload

let parse_hash cursor =
  let hash_length = 2 * Hash.digest_size in
  let available = String.length cursor.bytes - cursor.offset in
  if hash_length > available then invalid_at cursor.offset "an operation hash is truncated"
  else
    let raw = String.sub cursor.bytes cursor.offset hash_length in
    match Hash.of_canonical_hex raw with
    | None -> invalid_at cursor.offset "an operation hash is not canonical lowercase HASH_V0"
    | Some hash ->
        cursor.offset <- cursor.offset + hash_length;
        Ok hash

let parse_event cursor ~expected_index =
  let ( let* ) = Result.bind in
  let* () = expect_literal cursor "trace index=" in
  let* index = parse_unsigned cursor in
  let* () =
    if index = expected_index then Ok ()
    else invalid_at cursor.offset "trace indices are not contiguous from zero"
  in
  let* () = expect_literal cursor " operation=" in
  let* operation = parse_hash cursor in
  let* () = expect_literal cursor " output-bytes=" in
  let* output_length = parse_unsigned cursor in
  let* () =
    if output_length = 0 || Hash.equal operation console_print_operation then Ok ()
    else invalid_at cursor.offset "a non-Console operation declares output bytes"
  in
  let* () = expect_literal cursor "\n" in
  let* output = read_payload cursor output_length in
  Ok ({ operation; output } : event)

let parse_observation cursor ~expected_index =
  let ( let* ) = Result.bind in
  let* () = expect_literal cursor "observation index=" in
  let* index = parse_unsigned cursor in
  let* () =
    if index = expected_index then Ok ()
    else invalid_at cursor.offset "observation indices are not contiguous from zero"
  in
  let* () = expect_literal cursor " value-bytes=" in
  let* value_length = parse_unsigned cursor in
  let* () = expect_literal cursor " trace-events=" in
  let* trace_length = parse_unsigned cursor in
  let* () = expect_literal cursor "\n" in
  let* value = read_payload cursor value_length in
  let* () =
    if String.length value > 0 && value.[String.length value - 1] = '\n' then Ok ()
    else invalid_at cursor.offset "a value payload does not end in its required LF"
  in
  let rec events index remaining reversed =
    if remaining = 0 then Ok (List.rev reversed)
    else
      let* event = parse_event cursor ~expected_index:index in
      events (index + 1) (remaining - 1) (event :: reversed)
  in
  let* trace = events 0 trace_length [] in
  Ok { value; trace }

(** [parse bytes] advances a byte cursor through exact structural literals and length-framed raw
    payloads. Every failed branch reports only its structural location, never attacker-controlled
    transcript bytes. *)
let parse bytes =
  let ( let* ) = Result.bind in
  let cursor = { bytes; offset = 0 } in
  let* () = expect_literal cursor "jacquard-run-transcript format=" in
  let* version = parse_unsigned cursor in
  let* () =
    if version = format_version then Ok ()
    else invalid_at cursor.offset "the format version is unsupported"
  in
  let* () = expect_literal cursor " observations=" in
  let* observation_count = parse_unsigned cursor in
  let* () = expect_literal cursor "\n" in
  let rec observations index remaining reversed =
    if remaining = 0 then Ok (List.rev reversed)
    else
      let* observation = parse_observation cursor ~expected_index:index in
      observations (index + 1) (remaining - 1) (observation :: reversed)
  in
  let* completed = observations 0 observation_count [] in
  if cursor.offset <> String.length bytes then
    invalid_at cursor.offset "bytes remain after the final declared payload"
  else
    let transcript = Transcript completed in
    if String.equal (serialize transcript) bytes then Ok transcript
    else invalid_at cursor.offset "the decoded bytes are not canonical run-transcript-v1"

let first_divergence position kind left right = Divergence { position; kind; left; right }

let rec compare_trace observation_index trace_index (left : event list) (right : event list) =
  match (left, right) with
  | [], [] -> None
  | left_event :: left_rest, right_event :: right_rest ->
      if
        (not (Hash.equal left_event.operation right_event.operation))
        || not (String.equal left_event.output right_event.output)
      then
        Some
          (first_divergence
             (Trace_position { observation_index; trace_index })
             Trace_divergence (Trace_side left_event) (Trace_side right_event))
      else compare_trace observation_index (trace_index + 1) left_rest right_rest
  | left_event :: _, [] ->
      Some
        (first_divergence
           (Trace_position { observation_index; trace_index })
           Length_divergence (Trace_side left_event) Missing_side)
  | [], right_event :: _ ->
      Some
        (first_divergence
           (Trace_position { observation_index; trace_index })
           Length_divergence Missing_side (Trace_side right_event))

(** [compare] walks decoded logical structure rather than serialized byte offsets. Complete field
    comparison establishes the same equality relation as canonical serialization. *)
let compare (Transcript left) (Transcript right) =
  let rec observations index left right =
    match (left, right) with
    | [], [] -> Equal
    | left_observation :: left_rest, right_observation :: right_rest -> (
        if not (String.equal left_observation.value right_observation.value) then
          first_divergence (Value_position index) Value_divergence
            (Value_side left_observation.value) (Value_side right_observation.value)
        else
          match compare_trace index 0 left_observation.trace right_observation.trace with
          | Some divergence -> divergence
          | None -> observations (index + 1) left_rest right_rest)
    | left_observation :: _, [] ->
        first_divergence (Observation_position index) Length_divergence
          (Observation_side left_observation) Missing_side
    | [], right_observation :: _ ->
        first_divergence (Observation_position index) Length_divergence Missing_side
          (Observation_side right_observation)
  in
  observations 0 left right

let position_path = function
  | Observation_position index -> Printf.sprintf "observation[%d]" index
  | Value_position index -> Printf.sprintf "observation[%d].value" index
  | Trace_position { observation_index; trace_index } ->
      Printf.sprintf "observation[%d].trace[%d]" observation_index trace_index

let divergence_kind_name = function
  | Value_divergence -> "value-divergence"
  | Trace_divergence -> "trace-divergence"
  | Length_divergence -> "length-divergence"

let render_side ~redact = function
  | Value_side value -> Printf.sprintf "%S" (redact value)
  | Trace_side event ->
      Printf.sprintf "operation=%s output=%S" (Hash.to_hex event.operation) (redact event.output)
  | Observation_side observation ->
      Printf.sprintf "observation value=%S value-bytes=%d trace-events=%d"
        (redact observation.value) (String.length observation.value) (List.length observation.trace)
  | Missing_side -> "<missing>"

(** [render_redacted ~redact divergence] applies [redact] to raw result and Console bytes before
    escaping them into the canonical frame. Structural paths, hashes, and byte counts are not
    rewritten. *)
let render_redacted ~redact divergence =
  Printf.sprintf "  at %s:\n    - %s\n    + %s"
    (position_path divergence.position)
    (render_side ~redact divergence.left)
    (render_side ~redact divergence.right)

(** [render divergence] is the identity-redactor specialization retained for every ordinary caller.
*)
let render divergence = render_redacted ~redact:Fun.id divergence
