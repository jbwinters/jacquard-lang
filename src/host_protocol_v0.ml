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

type boundary_budget = { limits : limits; mutable nodes : int }

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

let create_boundary_budget limits = { limits; nodes = 0 }

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
  | "E1603" ->
      ( "The selected Jacquard target or pinned interface is invalid.",
        "Select one complete checked store-term closure and use its exact first-order interface." )
  | "E1604" ->
      ( "A Jacquard type or value is unsupported at the v0 host boundary.",
        "Use only the frozen closed first-order type and lossless value descriptor subset." )
  | "E1605" ->
      ( "The selected host capability or operation registry is invalid.",
        "Use the exact checked effect set and a sorted unique registry of its public once \
         operations." )
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

let consume_boundary_node budget =
  if budget.limits.max_value_nodes <= 0 || budget.nodes >= budget.limits.max_value_nodes then
    error ~code:"E1602" "The frame exceeds max_value_nodes across its type and value descriptors."
  else (
    budget.nodes <- budget.nodes + 1;
    Ok ())

let boundary_kind fields =
  match field "kind" fields with
  | Some (`String kind) -> Ok kind
  | Some _ | None -> error ~code:"E1601" "A boundary descriptor kind must be one string."

let boundary_hash context = function
  | `String spelling -> (
      match Hash.of_canonical_hex spelling with
      | Some hash -> Ok hash
      | None ->
          error ~code:"E1601"
            (Printf.sprintf "The %s must be exactly 64 lowercase hexadecimal digits." context))
  | _ -> error ~code:"E1601" (Printf.sprintf "The %s must be one HASH_V0 string." context)

let validate_boundary_count ~budget ~context ~arguments count =
  if budget.limits.max_collection_items <= 0 || count > budget.limits.max_collection_items then
    error ~code:"E1602" (Printf.sprintf "The %s exceeds max_collection_items." context)
  else if arguments && (budget.limits.max_arguments <= 0 || count > budget.limits.max_arguments)
  then error ~code:"E1602" (Printf.sprintf "The %s exceeds max_arguments." context)
  else Ok ()

let boundary_list ~budget ~context ~arguments = function
  | `List items ->
      let* () = validate_boundary_count ~budget ~context ~arguments (List.length items) in
      Ok items
  | _ -> error ~code:"E1601" (Printf.sprintf "The %s must be one JSON array." context)

let rec map_result f = function
  | [] -> Ok []
  | item :: rest ->
      let* item = f item in
      let* rest = map_result f rest in
      Ok (item :: rest)

let decode_boundary_type ~budget json =
  let rec decode = function
    | `Assoc fields ->
        let* kind = boundary_kind fields in
        let* () =
          match kind with
          | "nominal" -> exact_fields [ "arguments"; "identity"; "kind" ] fields
          | "tuple" -> exact_fields [ "items"; "kind" ] fields
          | _ ->
              error ~code:"E1604"
                (Printf.sprintf "Boundary type kind %S is not supported in jacquard-host-v0." kind)
        in
        let* () = consume_boundary_node budget in
        if String.equal kind "nominal" then
          let* identity =
            match field "identity" fields with
            | Some value -> boundary_hash "nominal type identity" value
            | None -> error ~code:"E1601" "The nominal type identity is missing."
          in
          let* arguments =
            match field "arguments" fields with
            | Some value ->
                boundary_list ~budget ~context:"nominal type arguments" ~arguments:false value
            | None -> error ~code:"E1601" "The nominal type arguments are missing."
          in
          let* arguments = map_result decode arguments in
          Ok (Types.TCon (identity, arguments))
        else
          let* items =
            match field "items" fields with
            | Some value -> boundary_list ~budget ~context:"tuple type items" ~arguments:false value
            | None -> error ~code:"E1601" "The tuple type items are missing."
          in
          let* items = map_result decode items in
          Ok (Types.TTuple items)
    | _ -> error ~code:"E1601" "A boundary type must be one exact JSON object."
  in
  let* () = validate_json ~limits:budget.limits json in
  decode json

let encode_boundary_type ~budget ty =
  let rec encode ty =
    match Types.repr ty with
    | Types.TCon (identity, arguments) ->
        let* () = consume_boundary_node budget in
        let* () =
          validate_boundary_count ~budget ~context:"nominal type arguments" ~arguments:false
            (List.length arguments)
        in
        let* arguments = map_result encode arguments in
        Ok
          (`Assoc
             [
               ("arguments", `List arguments);
               ("identity", `String (Hash.to_hex identity));
               ("kind", `String "nominal");
             ])
    | Types.TTuple items ->
        let* () = consume_boundary_node budget in
        let* () =
          validate_boundary_count ~budget ~context:"tuple type items" ~arguments:false
            (List.length items)
        in
        let* items = map_result encode items in
        Ok (`Assoc [ ("items", `List items); ("kind", `String "tuple") ])
    | Types.TArrow _ | Types.TResume _ | Types.TVariadicArrow _ | Types.TExactThunk _ | Types.TVar _
    | Types.TSkolem _ ->
        error ~code:"E1604"
          "The Core type contains an arrow, resumption, exact thunk, or unresolved variable."
  in
  let* json = encode ty in
  let* () = validate_json ~limits:budget.limits json in
  Ok json

let canonical_int = function
  | `String spelling -> (
      match int_of_string_opt spelling with
      | Some value when String.equal spelling (string_of_int value) -> Ok value
      | Some _ | None ->
          error ~code:"E1601"
            "A boundary Int must use canonical decimal text in the released OCaml 63-bit range.")
  | _ -> error ~code:"E1601" "A boundary Int value must be one canonical decimal string."

let lowercase_hex_16 spelling =
  String.length spelling = 16
  && String.for_all (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false) spelling

let real_of_bits = function
  | `String spelling when lowercase_hex_16 spelling -> (
      match Int64.of_string_opt ("0x" ^ spelling) with
      | Some bits -> Ok (Int64.float_of_bits bits)
      | None -> error ~code:"E1601" "A boundary Real bit string is not valid binary64 data.")
  | `String _ ->
      error ~code:"E1601" "A boundary Real must use exactly 16 lowercase hexadecimal digits."
  | _ -> error ~code:"E1601" "A boundary Real bits field must be one string."

let validate_boundary_text limits text =
  if not (valid_utf8 text) then
    error ~code:"E1601" "A boundary Text value is not Unicode scalar UTF-8."
  else if limits.max_text_bytes <= 0 || String.length text > limits.max_text_bytes then
    error ~code:"E1602" "A boundary Text value exceeds max_text_bytes."
  else Ok text

let decode_boundary_value ~budget ~constructor_info json =
  let rec decode = function
    | `Assoc fields -> (
        let* kind = boundary_kind fields in
        let* () =
          match kind with
          | "int" | "text" | "hash" -> exact_fields [ "kind"; "value" ] fields
          | "real" -> exact_fields [ "bits"; "kind" ] fields
          | "tuple" -> exact_fields [ "items"; "kind" ] fields
          | "constructor" -> exact_fields [ "arguments"; "identity"; "kind" ] fields
          | _ ->
              error ~code:"E1604"
                (Printf.sprintf "Boundary value kind %S is not supported in jacquard-host-v0." kind)
        in
        let* () = consume_boundary_node budget in
        let field_or_missing name cause =
          match field name fields with Some value -> Ok value | None -> error ~code:"E1601" cause
        in
        match kind with
        | "int" ->
            let* value = field_or_missing "value" "The boundary Int value is missing." in
            let* value = canonical_int value in
            Ok (Value.VInt value)
        | "real" ->
            let* bits = field_or_missing "bits" "The boundary Real bits are missing." in
            let* value = real_of_bits bits in
            Ok (Value.VReal value)
        | "text" ->
            let* value = field_or_missing "value" "The boundary Text value is missing." in
            let* value =
              match value with
              | `String text -> validate_boundary_text budget.limits text
              | _ -> error ~code:"E1601" "A boundary Text value must be one string."
            in
            Ok (Value.VText value)
        | "hash" ->
            let* value = field_or_missing "value" "The boundary Hash value is missing." in
            let* value = boundary_hash "boundary Hash value" value in
            Ok (Value.VHash value)
        | "tuple" ->
            let* items = field_or_missing "items" "The boundary tuple items are missing." in
            let* items =
              boundary_list ~budget ~context:"tuple value items" ~arguments:false items
            in
            let* items = map_result decode items in
            Ok (Value.VTuple items)
        | "constructor" ->
            let* identity =
              field_or_missing "identity" "The boundary constructor identity is missing."
            in
            let* identity = boundary_hash "constructor identity" identity in
            let* arguments =
              field_or_missing "arguments" "The boundary constructor arguments are missing."
            in
            let* arguments =
              boundary_list ~budget ~context:"constructor arguments" ~arguments:true arguments
            in
            let* arguments = map_result decode arguments in
            let* name, arity = constructor_info identity in
            if arity <> List.length arguments then
              error ~code:"E1604"
                (Printf.sprintf
                   "The constructor value has %d argument(s), but the resolved constructor \
                    requires %d."
                   (List.length arguments) arity)
            else Ok (Value.VCon { con = identity; name; args = arguments })
        | _ ->
            error ~code:"E1604"
              (Printf.sprintf "Boundary value kind %S is not supported in jacquard-host-v0." kind))
    | _ -> error ~code:"E1601" "A boundary value must be one exact JSON object."
  in
  let* () = validate_json ~limits:budget.limits json in
  decode json

let encode_boundary_value ~budget value =
  let rec encode value =
    match value with
    | Value.VInt value ->
        let* () = consume_boundary_node budget in
        Ok (`Assoc [ ("kind", `String "int"); ("value", `String (string_of_int value)) ])
    | Value.VReal value ->
        let* () = consume_boundary_node budget in
        let bits = Printf.sprintf "%016Lx" (Int64.bits_of_float value) in
        Ok (`Assoc [ ("bits", `String bits); ("kind", `String "real") ])
    | Value.VText value ->
        let* () = consume_boundary_node budget in
        let* value = validate_boundary_text budget.limits value in
        Ok (`Assoc [ ("kind", `String "text"); ("value", `String value) ])
    | Value.VHash value ->
        let* () = consume_boundary_node budget in
        Ok (`Assoc [ ("kind", `String "hash"); ("value", `String (Hash.to_hex value)) ])
    | Value.VTuple items ->
        let* () = consume_boundary_node budget in
        let* () =
          validate_boundary_count ~budget ~context:"tuple value items" ~arguments:false
            (List.length items)
        in
        let* items = map_result encode items in
        Ok (`Assoc [ ("items", `List items); ("kind", `String "tuple") ])
    | Value.VCon { con; args; _ } ->
        let* () = consume_boundary_node budget in
        let* () =
          validate_boundary_count ~budget ~context:"constructor arguments" ~arguments:true
            (List.length args)
        in
        let* arguments = map_result encode args in
        Ok
          (`Assoc
             [
               ("arguments", `List arguments);
               ("identity", `String (Hash.to_hex con));
               ("kind", `String "constructor");
             ])
    | Value.VSecret _ | Value.VConstructor _ | Value.VOp _ | Value.VClosure _ | Value.VBuiltin _
    | Value.VTrustedBuiltin _ | Value.VCode _ | Value.VTask _ | Value.VChannel _ | Value.VResume _
    | Value.VOnceResume _ ->
        error ~code:"E1604"
          "The Core value is opaque, callable, or owned by one evaluator run and cannot cross v0."
  in
  let* json = encode value in
  let* () = validate_json ~limits:budget.limits json in
  Ok json

type operation_binding = {
  effect_identity : Hash.t;
  operation : Hash.t;
  parameters : Types.ty list;
  result : Types.ty;
}

type invocation = {
  invocation_id : string;
  callable : Hash.t;
  parameters : Types.ty list;
  effects : Hash.t list;
  result : Types.ty;
  arguments : Value.t list;
  operations : operation_binding list;
}

let equal_hashes left right =
  List.length left = List.length right && List.for_all2 Hash.equal left right

let rec equal_boundary_types left right =
  match (Types.repr left, Types.repr right) with
  | Types.TCon (left_identity, left_arguments), Types.TCon (right_identity, right_arguments) ->
      Hash.equal left_identity right_identity
      && List.length left_arguments = List.length right_arguments
      && List.for_all2 equal_boundary_types left_arguments right_arguments
  | Types.TTuple left_items, Types.TTuple right_items ->
      List.length left_items = List.length right_items
      && List.for_all2 equal_boundary_types left_items right_items
  | _ -> false

let boundary_type_supported ty =
  let rec check = function
    | Types.TCon (_, arguments) -> check_all arguments
    | Types.TTuple items -> check_all items
    | Types.TArrow _ | Types.TResume _ | Types.TVariadicArrow _ | Types.TExactThunk _ | Types.TVar _
    | Types.TSkolem _ ->
        error ~code:"E1604"
          "A checked boundary contract contains a nested callable or unresolved type."
  and check_all = function
    | [] -> Ok ()
    | ty :: rest ->
        let* () = check (Types.repr ty) in
        check_all rest
  in
  check (Types.repr ty)

let map_error ~code cause = function Ok value -> Ok value | Error _ -> error ~code cause

let validate_complete_closure store root =
  let rec visit seen = function
    | [] -> Ok ()
    | hash :: rest when List.exists (Hash.equal hash) seen -> visit seen rest
    | hash :: rest -> (
        match Store.locate_internal store hash with
        | Error _ ->
            error ~code:"E1603"
              "The selected target's reachable immutable store closure is incomplete or corrupt."
        | Ok { Store.decl; _ } -> visit (hash :: seen) (Store.decl_refs decl @ rest))
  in
  visit [] [ root ]

let validate_target checker callable =
  let store = Check.store checker in
  let* () =
    match Store.locate store callable with
    | Ok { Store.decl = { Kernel.it = Kernel.DefTerm _; _ }; role = Store.Member _; _ } -> Ok ()
    | Ok _ | Error _ ->
        error ~code:"E1603" "The invoke target is not one exact public stored term-member identity."
  in
  let* () = validate_complete_closure store callable in
  let* scheme =
    map_error ~code:"E1603" "The selected target closure does not pass strict checking."
      (Check.force_term checker callable)
  in
  let quantified_types, quantified_rows = Types.quantified scheme in
  if quantified_types <> [] || quantified_rows <> [] then
    error ~code:"E1603" "The selected target is polymorphic rather than one closed invocation."
  else
    match Types.repr scheme.Types.ty with
    | Types.TArrow (parameters, row, result) ->
        let row = Types.repr_row row in
        let* () =
          match row.Types.tail with
          | Types.RClosed -> Ok ()
          | Types.RVar _ | Types.RSkolem _ ->
              error ~code:"E1603" "The selected target has an open effect row."
        in
        let* () = map_result boundary_type_supported parameters |> Result.map (fun _ -> ()) in
        let* () = boundary_type_supported result in
        Ok (parameters, row.Types.effects, result)
    | Types.TCon _ | Types.TTuple _ | Types.TResume _ | Types.TVariadicArrow _ | Types.TExactThunk _
    | Types.TVar _ | Types.TSkolem _ ->
        error ~code:"E1603" "The selected stored term is not one callable arrow."

let parse_hash_list ~budget ~context ~maximum json =
  let* items = boundary_list ~budget ~context ~arguments:false json in
  if maximum <= 0 || List.length items > maximum then
    error ~code:"E1602" (Printf.sprintf "The %s exceeds its selected protocol limit." context)
  else map_result (boundary_hash context) items

let parse_interface ~budget = function
  | `Assoc fields ->
      let* () = exact_fields [ "effects"; "parameters"; "result" ] fields in
      let* parameters_json =
        match field "parameters" fields with
        | Some value -> boundary_list ~budget ~context:"interface parameters" ~arguments:true value
        | None -> error ~code:"E1601" "The interface parameters are missing."
      in
      let* parameters = map_result (decode_boundary_type ~budget) parameters_json in
      let* effects =
        match field "effects" fields with
        | Some value ->
            parse_hash_list ~budget ~context:"interface effects" ~maximum:budget.limits.max_effects
              value
        | None -> error ~code:"E1601" "The interface effects are missing."
      in
      let* result =
        match field "result" fields with
        | Some value -> decode_boundary_type ~budget value
        | None -> error ~code:"E1601" "The interface result is missing."
      in
      Ok (parameters, effects, result)
  | _ -> error ~code:"E1601" "The interface must be one exact JSON object."

let constructor_info checker identity =
  let store = Check.store checker in
  match Store.locate store identity with
  | Ok
      {
        Store.decl = { Kernel.it = Kernel.DefType { cons; _ }; _ };
        role = Store.Constructor index;
        _;
      } -> (
      match List.nth_opt cons index with
      | None -> error ~code:"E1603" "The constructor identity has invalid store metadata."
      | Some constructor ->
          let* _ =
            map_error ~code:"E1603" "The constructor declaration does not pass strict checking."
              (Check.force_constructor checker identity)
          in
          Ok (constructor.Kernel.con_name, List.length constructor.Kernel.fields))
  | Ok _ | Error _ ->
      error ~code:"E1603" "A boundary value names an absent or non-constructor store identity."

let validate_argument_value checker ~expected value =
  let primitives = Check.primitive_types checker in
  let mismatch cause = error ~code:"E1603" cause in
  let scalar identity expected cause =
    if equal_boundary_types (Types.TCon (identity, [])) expected then Ok () else mismatch cause
  in
  let rec validate expected = function
    | Value.VInt _ ->
        scalar primitives.Check.int_type expected "An Int argument disagrees with its parameter."
    | Value.VReal _ ->
        scalar primitives.Check.real_type expected "A Real argument disagrees with its parameter."
    | Value.VText _ ->
        scalar primitives.Check.text_type expected "A Text argument disagrees with its parameter."
    | Value.VHash _ ->
        scalar primitives.Check.hash_type expected "A Hash argument disagrees with its parameter."
    | Value.VTuple items -> (
        match Types.repr expected with
        | Types.TTuple item_types when List.length items = List.length item_types ->
            validate_all item_types items
        | Types.TTuple _ -> mismatch "A tuple argument has the wrong number of items."
        | _ -> mismatch "A tuple argument disagrees with its parameter type.")
    | Value.VCon { con; args; _ } ->
        let* scheme =
          map_error ~code:"E1603" "A constructor argument cannot be checked in this store."
            (Check.force_constructor checker con)
        in
        let constructor_type = Types.instantiate ~level:0 scheme in
        let fields, result =
          match Types.repr constructor_type with
          | Types.TArrow (fields, row, result)
            when (Types.repr_row row).Types.effects = []
                 && match (Types.repr_row row).Types.tail with Types.RClosed -> true | _ -> false ->
              (fields, result)
          | ty -> ([], ty)
        in
        if List.length fields <> List.length args then
          error ~code:"E1604" "A constructor value is not saturated at the boundary."
        else
          let* () =
            match Types.unify result expected with
            | () -> Ok ()
            | exception Types.Unify_error _ ->
                mismatch "A constructor argument disagrees with its nominal parameter type."
          in
          let* () = map_result boundary_type_supported fields |> Result.map (fun _ -> ()) in
          validate_all fields args
    | Value.VSecret _ | Value.VConstructor _ | Value.VOp _ | Value.VClosure _ | Value.VBuiltin _
    | Value.VTrustedBuiltin _ | Value.VCode _ | Value.VTask _ | Value.VChannel _ | Value.VResume _
    | Value.VOnceResume _ ->
        error ~code:"E1604" "A run-owned or callable value cannot be an invoke argument."
  and validate_all expected values =
    match (expected, values) with
    | [], [] -> Ok ()
    | expected :: expected_rest, value :: value_rest ->
        let* () = validate expected value in
        validate_all expected_rest value_rest
    | _ -> mismatch "An aggregate argument has the wrong number of fields."
  in
  validate expected value

type parsed_operation = { claimed_effect : Hash.t; claimed_operation : Hash.t }

let parse_operation_entry = function
  | `Assoc fields ->
      let* () = exact_fields [ "effect"; "mode"; "operation" ] fields in
      let* claimed_effect =
        match field "effect" fields with
        | Some value -> boundary_hash "operation registry effect" value
        | None -> error ~code:"E1601" "The operation registry effect is missing."
      in
      let* claimed_operation =
        match field "operation" fields with
        | Some value -> boundary_hash "operation registry identity" value
        | None -> error ~code:"E1601" "The operation registry identity is missing."
      in
      let* () =
        match field "mode" fields with
        | Some (`String "once") -> Ok ()
        | Some (`String _) -> error ~code:"E1605" "A registry entry does not select mode once."
        | Some _ | None -> error ~code:"E1601" "The operation registry mode must be one string."
      in
      Ok { claimed_effect; claimed_operation }
  | _ -> error ~code:"E1601" "Each operation registry entry must be one exact JSON object."

let operation_compare left right =
  match Hash.compare left.claimed_effect right.claimed_effect with
  | 0 -> Hash.compare left.claimed_operation right.claimed_operation
  | order -> order

let strictly_sorted ~compare ~code cause items =
  let rec check = function
    | left :: (right :: _ as rest) ->
        if compare left right < 0 then check rest else error ~code cause
    | [ _ ] | [] -> Ok ()
  in
  check items

let validate_operation checker ~effects entry =
  if not (List.exists (Hash.equal entry.claimed_effect) effects) then
    error ~code:"E1605" "An operation registry entry introduces an ungranted effect."
  else
    let* contract =
      map_error ~code:"E1605" "An operation registry identity is absent or is not an operation."
        (Check.force_operation checker entry.claimed_operation)
    in
    if not (Hash.equal entry.claimed_effect contract.Check.effect_identity) then
      error ~code:"E1605" "An operation registry entry names the wrong owning effect."
    else if contract.Check.mode <> Kernel.Once then
      error ~code:"E1605" "An operation registry entry names a non-once operation."
    else
      let quantified_types, quantified_rows = Types.quantified contract.Check.scheme in
      if quantified_types <> [] || quantified_rows <> [] then
        error ~code:"E1604" "A configured operation has a polymorphic boundary signature."
      else
        match Types.repr contract.Check.scheme.Types.ty with
        | Types.TArrow (parameters, _, result) ->
            let* () = map_result boundary_type_supported parameters |> Result.map (fun _ -> ()) in
            let* () = boundary_type_supported result in
            Ok
              {
                effect_identity = contract.Check.effect_identity;
                operation = entry.claimed_operation;
                parameters;
                result;
              }
        | Types.TCon _ | Types.TTuple _ | Types.TResume _ | Types.TVariadicArrow _
        | Types.TExactThunk _ | Types.TVar _ | Types.TSkolem _ ->
            error ~code:"E1604" "A configured operation does not have one first-order arrow."

let parse_capabilities ~budget checker ~interface_effects = function
  | `Assoc fields ->
      let* () = exact_fields [ "effects"; "operations" ] fields in
      let* effects =
        match field "effects" fields with
        | Some value ->
            parse_hash_list ~budget ~context:"capability effects" ~maximum:budget.limits.max_effects
              value
        | None -> error ~code:"E1601" "The capability effects are missing."
      in
      let* () =
        strictly_sorted ~compare:Hash.compare ~code:"E1605"
          "Capability effects must be strictly sorted and unique." effects
      in
      if not (equal_hashes effects interface_effects) then
        error ~code:"E1605" "Capability effects do not exactly equal the pinned interface row."
      else
        let* operation_json =
          match field "operations" fields with
          | Some value ->
              boundary_list ~budget ~context:"capability operations" ~arguments:false value
          | None -> error ~code:"E1601" "The capability operations are missing."
        in
        if
          budget.limits.max_operations <= 0
          || List.length operation_json > budget.limits.max_operations
        then error ~code:"E1602" "The operation registry exceeds max_operations."
        else
          let* parsed = map_result parse_operation_entry operation_json in
          let* () =
            strictly_sorted ~compare:operation_compare ~code:"E1605"
              "Operation registry entries must be strictly sorted and unique." parsed
          in
          map_result (validate_operation checker ~effects) parsed
  | _ -> error ~code:"E1601" "The capabilities field must be one exact JSON object."

let parse_invoke ~limits ~checker json =
  let* () = validate_json ~limits json in
  match json with
  | `Assoc fields ->
      let* () =
        exact_fields
          [
            "arguments"; "capabilities"; "interface"; "invocation_id"; "kind"; "protocol"; "target";
          ]
          fields
      in
      let* () = parse_protocol fields in
      let* () = parse_kind "invoke" fields in
      let* invocation_id =
        match field "invocation_id" fields with
        | Some (`String "0000000000000000") -> Ok "0000000000000000"
        | Some (`String _) -> error ~code:"E1608" "The invoke ID is not the fixed v0 invocation ID."
        | Some _ | None -> error ~code:"E1601" "The invocation ID must be one string."
      in
      let* callable =
        match field "target" fields with
        | Some (`Assoc target_fields) -> (
            let* () = exact_fields [ "callable"; "kind" ] target_fields in
            let* () =
              match field "kind" target_fields with
              | Some (`String "store-term-v0") -> Ok ()
              | Some (`String _) -> error ~code:"E1603" "The target is not a store-term-v0 target."
              | Some _ | None -> error ~code:"E1601" "The target kind must be one string."
            in
            match field "callable" target_fields with
            | Some value -> boundary_hash "target callable identity" value
            | None -> error ~code:"E1601" "The target callable identity is missing.")
        | Some _ | None -> error ~code:"E1601" "The target must be one exact JSON object."
      in
      let* parameters, effects, result = validate_target checker callable in
      let budget = create_boundary_budget limits in
      let* interface_parameters, interface_effects, interface_result =
        match field "interface" fields with
        | Some value -> parse_interface ~budget value
        | None -> error ~code:"E1601" "The interface is missing."
      in
      if
        List.length parameters <> List.length interface_parameters
        || (not (List.for_all2 equal_boundary_types parameters interface_parameters))
        || (not (equal_hashes effects interface_effects))
        || not (equal_boundary_types result interface_result)
      then error ~code:"E1603" "The pinned interface disagrees with the checked target arrow."
      else
        let* argument_json =
          match field "arguments" fields with
          | Some value -> boundary_list ~budget ~context:"invoke arguments" ~arguments:true value
          | None -> error ~code:"E1601" "The invoke arguments are missing."
        in
        if List.length argument_json <> List.length parameters then
          error ~code:"E1603" "The invoke argument count disagrees with the checked target arrow."
        else
          let* arguments =
            map_result
              (decode_boundary_value ~budget ~constructor_info:(constructor_info checker))
              argument_json
          in
          let rec validate_arguments expected values =
            match (expected, values) with
            | [], [] -> Ok ()
            | expected :: expected_rest, value :: value_rest ->
                let* () = validate_argument_value checker ~expected value in
                validate_arguments expected_rest value_rest
            | _ -> error ~code:"E1603" "The invoke argument count changed during preflight."
          in
          let* () = validate_arguments parameters arguments in
          let* operations =
            match field "capabilities" fields with
            | Some value -> parse_capabilities ~budget checker ~interface_effects value
            | None -> error ~code:"E1601" "The capabilities field is missing."
          in
          Ok { invocation_id; callable; parameters; effects; result; arguments; operations }
  | _ -> error ~code:"E1601" "The invoke message must be one JSON object."
