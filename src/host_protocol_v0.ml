let protocol = "jacquard-host-v0"
let carrier = "stdio-u32-json-v0"

type limits = {
  max_frame_bytes : int;
  max_json_depth : int;
  max_value_nodes : int;
  max_text_bytes : int;
  max_collection_items : int;
  max_arguments : int;
  max_effects : int;
  max_operations : int;
  max_effect_requests : int;
  max_diagnostics : int;
  max_diagnostic_bytes : int;
  max_host_message_bytes : int;
  max_stderr_bytes : int;
}

let hard_limits =
  {
    max_frame_bytes = 1_048_576;
    max_json_depth = 64;
    max_value_nodes = 4_096;
    max_text_bytes = 262_144;
    max_collection_items = 1_024;
    max_arguments = 64;
    max_effects = 64;
    max_operations = 256;
    max_effect_requests = 1_024;
    max_diagnostics = 32;
    max_diagnostic_bytes = 65_536;
    max_host_message_bytes = 4_096;
    max_stderr_bytes = 65_536;
  }

let diagnostic_spec = function
  | "E1600" ->
      ( "The host selected an unsupported protocol version.",
        "Select jacquard-host-v0 with the advertised stdio-u32-json-v0 carrier." )
  | "E1601" ->
      ( "The host protocol frame is malformed.",
        "Send one exact UTF-8 JSON object using the frozen jacquard-host-v0 envelope." )
  | "E1602" ->
      ( "The host protocol limit was exceeded or cannot represent a mandatory result.",
        "Choose positive advertised limits and keep the frame within the selected ceilings." )
  | "E1608" ->
      ( "The host protocol message is invalid in the current state.",
        "Send only the next message permitted by the serial jacquard-host-v0 state machine." )
  | "E1611" ->
      ( "The host carrier was lost before a trustworthy frame completed.",
        "Treat the missing terminal exchange as host-owned carrier-failure evidence." )
  | code -> raise (Diag.Bug_invalid_diagnostic ("unknown host protocol diagnostic code " ^ code))

let diagnostic ~code cause =
  let summary, next_step = diagnostic_spec code in
  Diag.error ~domain:Process ~code ~summary ~cause ~next_step ~contrast:None ()

let error ~code cause = Error [ diagnostic ~code cause ]

let limit_fields =
  [
    "max_arguments";
    "max_collection_items";
    "max_diagnostic_bytes";
    "max_diagnostics";
    "max_effect_requests";
    "max_effects";
    "max_frame_bytes";
    "max_host_message_bytes";
    "max_json_depth";
    "max_operations";
    "max_stderr_bytes";
    "max_text_bytes";
    "max_value_nodes";
  ]

let limits_to_yojson limits =
  `Assoc
    [
      ("max_arguments", `Int limits.max_arguments);
      ("max_collection_items", `Int limits.max_collection_items);
      ("max_diagnostic_bytes", `Int limits.max_diagnostic_bytes);
      ("max_diagnostics", `Int limits.max_diagnostics);
      ("max_effect_requests", `Int limits.max_effect_requests);
      ("max_effects", `Int limits.max_effects);
      ("max_frame_bytes", `Int limits.max_frame_bytes);
      ("max_host_message_bytes", `Int limits.max_host_message_bytes);
      ("max_json_depth", `Int limits.max_json_depth);
      ("max_operations", `Int limits.max_operations);
      ("max_stderr_bytes", `Int limits.max_stderr_bytes);
      ("max_text_bytes", `Int limits.max_text_bytes);
      ("max_value_nodes", `Int limits.max_value_nodes);
    ]

let core_hello () =
  `Assoc
    [
      ("carrier", `String carrier);
      ("kind", `String "core_hello");
      ("limits", limits_to_yojson hard_limits);
      ("versions", `List [ `String protocol ]);
    ]

let shutdown_ack () = `Assoc [ ("kind", `String "shutdown_ack"); ("protocol", `String protocol) ]
let continuation byte = byte land 0xc0 = 0x80

(** [valid_utf8 bytes] recognizes scalar-value UTF-8, excluding overlong forms, surrogate code
    points, and values above U+10FFFF. *)
let valid_utf8 bytes =
  let length = String.length bytes in
  let byte index = Char.code bytes.[index] in
  let rec scan index =
    if index = length then true
    else
      let first = byte index in
      if first <= 0x7f then scan (index + 1)
      else if first >= 0xc2 && first <= 0xdf then
        index + 1 < length && continuation (byte (index + 1)) && scan (index + 2)
      else if first = 0xe0 then
        index + 2 < length
        && byte (index + 1) >= 0xa0
        && byte (index + 1) <= 0xbf
        && continuation (byte (index + 2))
        && scan (index + 3)
      else if (first >= 0xe1 && first <= 0xec) || (first >= 0xee && first <= 0xef) then
        index + 2 < length
        && continuation (byte (index + 1))
        && continuation (byte (index + 2))
        && scan (index + 3)
      else if first = 0xed then
        index + 2 < length
        && byte (index + 1) >= 0x80
        && byte (index + 1) <= 0x9f
        && continuation (byte (index + 2))
        && scan (index + 3)
      else if first = 0xf0 then
        index + 3 < length
        && byte (index + 1) >= 0x90
        && byte (index + 1) <= 0xbf
        && continuation (byte (index + 2))
        && continuation (byte (index + 3))
        && scan (index + 4)
      else if first >= 0xf1 && first <= 0xf3 then
        index + 3 < length
        && continuation (byte (index + 1))
        && continuation (byte (index + 2))
        && continuation (byte (index + 3))
        && scan (index + 4)
      else if first = 0xf4 then
        index + 3 < length
        && byte (index + 1) >= 0x80
        && byte (index + 1) <= 0x8f
        && continuation (byte (index + 2))
        && continuation (byte (index + 3))
        && scan (index + 4)
      else false
  in
  scan 0

let duplicate_field fields =
  let sorted = List.map fst fields |> List.sort String.compare in
  let rec find = function
    | left :: right :: _ when String.equal left right -> Some left
    | _ :: rest -> find rest
    | [] -> None
  in
  find sorted

(** [validate_json ~limits json] enforces carrier-wide JSON invariants after decoding. It does not
    validate a message-specific envelope or count boundary-value nodes. *)
let validate_json ~limits json =
  let rec walk depth = function
    | `Assoc fields -> (
        if depth > limits.max_json_depth then
          error ~code:"E1602" "The JSON object nesting exceeds max_json_depth."
        else
          match duplicate_field fields with
          | Some _ -> error ~code:"E1601" "A JSON object contains a duplicate field name."
          | None ->
              let rec fields_valid = function
                | [] -> Ok ()
                | (key, value) :: rest ->
                    if not (valid_utf8 key) then
                      error ~code:"E1601" "A decoded JSON field name is not Unicode scalar UTF-8."
                    else Result.bind (walk (depth + 1) value) (fun () -> fields_valid rest)
              in
              fields_valid fields)
    | `List items ->
        if depth > limits.max_json_depth then
          error ~code:"E1602" "The JSON array nesting exceeds max_json_depth."
        else if List.length items > limits.max_collection_items then
          error ~code:"E1602" "A JSON array exceeds max_collection_items."
        else
          let rec items_valid = function
            | [] -> Ok ()
            | item :: rest -> Result.bind (walk (depth + 1) item) (fun () -> items_valid rest)
          in
          items_valid items
    | `String value when not (valid_utf8 value) ->
        error ~code:"E1601" "A decoded JSON string is not Unicode scalar UTF-8."
    | `Float _ | `Intlit _ ->
        error ~code:"E1601" "The protocol does not accept an unbounded or floating JSON number."
    | `String _ | `Int _ | `Bool _ | `Null -> Ok ()
    | `Tuple _ | `Variant _ ->
        error ~code:"E1601" "The payload contains a non-JSON Yojson extension value."
  in
  if limits.max_json_depth <= 0 || limits.max_collection_items <= 0 then
    error ~code:"E1602" "The active structural limits are not positive."
  else
    match json with
    | `Assoc _ -> walk 1 json
    | _ -> error ~code:"E1601" "A frame payload must contain one JSON object."

let decode_payload ~limits payload =
  if not (valid_utf8 payload) then
    error ~code:"E1601" "The frame payload is not valid Unicode scalar UTF-8."
  else
    match Yojson.Safe.from_string payload with
    | exception Yojson.Json_error _ ->
        error ~code:"E1601" "The frame payload is not exactly one valid JSON value."
    | json -> Result.map (fun () -> json) (validate_json ~limits json)

let encode_length length =
  let bytes = Bytes.create 4 in
  Bytes.set bytes 0 (Char.chr ((length lsr 24) land 0xff));
  Bytes.set bytes 1 (Char.chr ((length lsr 16) land 0xff));
  Bytes.set bytes 2 (Char.chr ((length lsr 8) land 0xff));
  Bytes.set bytes 3 (Char.chr (length land 0xff));
  Bytes.unsafe_to_string bytes

let decode_length bytes offset =
  let byte index = Char.code bytes.[offset + index] in
  (byte 0 lsl 24) lor (byte 1 lsl 16) lor (byte 2 lsl 8) lor byte 3

let validate_frame_length ~limits length =
  if length = 0 then error ~code:"E1601" "A frame payload length must be at least one byte."
  else if limits.max_frame_bytes <= 0 || length > limits.max_frame_bytes then
    error ~code:"E1602" "The frame payload length exceeds max_frame_bytes."
  else Ok ()

let encode_frame_bytes ~limits json =
  Result.bind (validate_json ~limits json) (fun () ->
      let payload = Yojson.Safe.to_string json in
      Result.bind
        (validate_frame_length ~limits (String.length payload))
        (fun () -> Ok (encode_length (String.length payload) ^ payload)))

let decode_frame_bytes ~limits bytes =
  if String.length bytes < 4 then
    error ~code:"E1611" "The carrier ended before the four-byte frame length completed."
  else
    let length = decode_length bytes 0 in
    Result.bind (validate_frame_length ~limits length) (fun () ->
        let available = String.length bytes - 4 in
        if available < length then
          error ~code:"E1611" "The carrier ended before the declared frame payload completed."
        else if available > length then
          error ~code:"E1601" "Bytes remain after the one declared frame payload."
        else decode_payload ~limits (String.sub bytes 4 length))

let read_exact input length =
  let buffer = Bytes.create length in
  let rec loop offset =
    if offset = length then Ok (Bytes.unsafe_to_string buffer)
    else
      match Stdlib.input input buffer offset (length - offset) with
      | 0 -> error ~code:"E1611" "The carrier ended before the declared frame completed."
      | count -> loop (offset + count)
      | (exception Sys_error _) | (exception Unix.Unix_error _) ->
          error ~code:"E1611" "The carrier failed while Core was reading a frame."
  in
  loop 0

let read_frame ~limits input =
  Result.bind (read_exact input 4) (fun prefix ->
      let length = decode_length prefix 0 in
      Result.bind (validate_frame_length ~limits length) (fun () ->
          Result.bind (read_exact input length) (decode_payload ~limits)))

let write_frame ~limits output json =
  Result.bind (encode_frame_bytes ~limits json) (fun frame ->
      match
        output_string output frame;
        flush output
      with
      | () -> Ok ()
      | (exception Sys_error _) | (exception Unix.Unix_error _) ->
          error ~code:"E1611" "The carrier failed while Core was writing a frame.")

let exact_fields expected fields =
  let actual = List.map fst fields |> List.sort String.compare in
  let expected = List.sort String.compare expected in
  if actual = expected then Ok ()
  else error ~code:"E1601" "The protocol envelope has a missing or unknown field."

let field name fields = List.assoc_opt name fields

let parse_protocol fields =
  match field "protocol" fields with
  | Some (`String version) when String.equal version protocol -> Ok ()
  | Some (`String _) -> error ~code:"E1600" "The selected protocol version is not advertised."
  | Some _ | None -> error ~code:"E1601" "The protocol field must be one version string."

let parse_kind expected fields =
  match field "kind" fields with
  | Some (`String kind) when String.equal kind expected -> Ok ()
  | Some (`String _) -> error ~code:"E1608" "The message kind is not valid in this protocol state."
  | Some _ | None -> error ~code:"E1601" "The kind field must be one message string."

let parse_limit_field name hard fields =
  match field name fields with
  | Some (`Int value) when value > 0 && value <= hard -> Ok value
  | Some (`Int _) ->
      error ~code:"E1602" (Printf.sprintf "The selected %s is not positive and advertised." name)
  | Some _ | None ->
      error ~code:"E1601" (Printf.sprintf "The selected %s is missing or not an integer." name)

let ( let* ) result continuation = Result.bind result continuation

let parse_limits = function
  | `Assoc fields ->
      let* () = exact_fields limit_fields fields in
      let* max_arguments = parse_limit_field "max_arguments" hard_limits.max_arguments fields in
      let* max_collection_items =
        parse_limit_field "max_collection_items" hard_limits.max_collection_items fields
      in
      let* max_diagnostic_bytes =
        parse_limit_field "max_diagnostic_bytes" hard_limits.max_diagnostic_bytes fields
      in
      let* max_diagnostics =
        parse_limit_field "max_diagnostics" hard_limits.max_diagnostics fields
      in
      let* max_effect_requests =
        parse_limit_field "max_effect_requests" hard_limits.max_effect_requests fields
      in
      let* max_effects = parse_limit_field "max_effects" hard_limits.max_effects fields in
      let* max_frame_bytes =
        parse_limit_field "max_frame_bytes" hard_limits.max_frame_bytes fields
      in
      let* max_host_message_bytes =
        parse_limit_field "max_host_message_bytes" hard_limits.max_host_message_bytes fields
      in
      let* max_json_depth = parse_limit_field "max_json_depth" hard_limits.max_json_depth fields in
      let* max_operations = parse_limit_field "max_operations" hard_limits.max_operations fields in
      let* max_stderr_bytes =
        parse_limit_field "max_stderr_bytes" hard_limits.max_stderr_bytes fields
      in
      let* max_text_bytes = parse_limit_field "max_text_bytes" hard_limits.max_text_bytes fields in
      let* max_value_nodes =
        parse_limit_field "max_value_nodes" hard_limits.max_value_nodes fields
      in
      Ok
        {
          max_frame_bytes;
          max_json_depth;
          max_value_nodes;
          max_text_bytes;
          max_collection_items;
          max_arguments;
          max_effects;
          max_operations;
          max_effect_requests;
          max_diagnostics;
          max_diagnostic_bytes;
          max_host_message_bytes;
          max_stderr_bytes;
        }
  | _ -> error ~code:"E1601" "The limits field must be one exact JSON object."

let rec json_depth = function
  | `Assoc fields ->
      1 + List.fold_left (fun depth (_, value) -> max depth (json_depth value)) 0 fields
  | `List items -> 1 + List.fold_left (fun depth value -> max depth (json_depth value)) 0 items
  | `String _ | `Int _ | `Float _ | `Intlit _ | `Bool _ | `Null -> 0
  | `Tuple _ | `Variant _ -> 0

let rec json_string_bytes = function
  | `String value -> String.length value
  | `Assoc fields ->
      List.fold_left (fun total (_, value) -> total + json_string_bytes value) 0 fields
  | `List items -> List.fold_left (fun total value -> total + json_string_bytes value) 0 items
  | `Int _ | `Float _ | `Intlit _ | `Bool _ | `Null | `Tuple _ | `Variant _ -> 0

let capacity_diagnostic =
  diagnostic ~code:"E1602" "The selected limits cannot represent a mandatory terminal frame."

let minimum_fatal =
  `Assoc
    [
      ("diagnostics", `List [ Diag.to_yojson capacity_diagnostic ]);
      ("kind", `String "fatal");
      ("protocol", `String protocol);
    ]

let validate_terminal_capacity limits =
  let fatal_bytes = String.length (Yojson.Safe.to_string minimum_fatal) in
  let ack_bytes = String.length (Yojson.Safe.to_string (shutdown_ack ())) in
  let diagnostic_bytes = json_string_bytes (Diag.to_yojson capacity_diagnostic) in
  if limits.max_diagnostics < 1 || limits.max_collection_items < 1 then
    error ~code:"E1602" "The selected limits cannot carry one mandatory diagnostic."
  else if limits.max_json_depth < json_depth minimum_fatal then
    error ~code:"E1602" "The selected max_json_depth cannot carry a mandatory fatal frame."
  else if limits.max_diagnostic_bytes < diagnostic_bytes then
    error ~code:"E1602" "The selected diagnostic byte limit cannot carry a mandatory diagnostic."
  else if limits.max_frame_bytes < max fatal_bytes ack_bytes then
    error ~code:"E1602" "The selected frame byte limit cannot carry a mandatory terminal frame."
  else Ok ()

let parse_host_select json =
  Result.bind (validate_json ~limits:hard_limits json) (fun () ->
      match json with
      | `Assoc fields ->
          Result.bind
            (exact_fields [ "kind"; "limits"; "protocol" ] fields)
            (fun () ->
              Result.bind (parse_protocol fields) (fun () ->
                  Result.bind (parse_kind "host_select" fields) (fun () ->
                      match field "limits" fields with
                      | None -> error ~code:"E1601" "The limits field is missing."
                      | Some json ->
                          Result.bind (parse_limits json) (fun limits ->
                              Result.map (fun () -> limits) (validate_terminal_capacity limits)))))
      | _ -> error ~code:"E1601" "The host selection must be one JSON object.")

let parse_shutdown ~limits json =
  Result.bind (validate_json ~limits json) (fun () ->
      match json with
      | `Assoc fields ->
          Result.bind
            (exact_fields [ "kind"; "protocol" ] fields)
            (fun () -> Result.bind (parse_protocol fields) (fun () -> parse_kind "shutdown" fields))
      | _ -> error ~code:"E1601" "The shutdown message must be one JSON object.")
