open Yojson.Safe

let vector_file = "../spec/host-protocol-v0/vectors.json"
let spec_file = "../spec/host-protocol-v0.md"
let fail context message = Alcotest.failf "%s: %s" context message
let assoc context = function `Assoc fields -> fields | _ -> fail context "expected an object"
let list context = function `List items -> items | _ -> fail context "expected an array"
let string context = function `String value -> value | _ -> fail context "expected a string"
let int context = function `Int value -> value | _ -> fail context "expected an integer"
let bool context = function `Bool value -> value | _ -> fail context "expected a boolean"

let field context name fields =
  match List.assoc_opt name fields with
  | Some value -> value
  | None -> fail context (Printf.sprintf "missing field %S" name)

let sorted_strings values = List.sort String.compare values

let check_fields context expected fields =
  let actual = fields |> List.map fst |> sorted_strings in
  Alcotest.(check (list string)) context (sorted_strings expected) actual

let check_unique context values =
  let unique = List.sort_uniq String.compare values in
  Alcotest.(check int) (context ^ " unique count") (List.length values) (List.length unique)

let load () = from_file vector_file |> assoc "vector document"

let hard_limits =
  [
    ("max_arguments", 64);
    ("max_collection_items", 1024);
    ("max_diagnostic_bytes", 65536);
    ("max_diagnostics", 32);
    ("max_effect_requests", 1024);
    ("max_effects", 64);
    ("max_frame_bytes", 1048576);
    ("max_host_message_bytes", 4096);
    ("max_json_depth", 64);
    ("max_operations", 256);
    ("max_stderr_bytes", 65536);
    ("max_text_bytes", 262144);
    ("max_value_nodes", 4096);
  ]

let test_document_and_limits () =
  let document = load () in
  check_fields "document fields"
    [ "schema"; "hard_limits"; "templates"; "positive"; "terminal_mappings"; "hostile" ]
    document;
  Alcotest.(check string)
    "schema" "jacquard-host-vectors-v0"
    (field "document" "schema" document |> string "schema");
  let limits = field "document" "hard_limits" document |> assoc "hard limits" in
  check_fields "hard limit fields" (List.map fst hard_limits) limits;
  List.iter
    (fun (name, expected) ->
      Alcotest.(check int) name expected (field "hard limits" name limits |> int name))
    hard_limits

type state = Start | Hello | Selected | Running | Waiting | Shutting_down | Finished of string

let template_info templates name =
  let fields = field "templates" name templates |> assoc ("template " ^ name) in
  check_fields ("template " ^ name) [ "direction"; "message" ] fields;
  let direction = field name "direction" fields |> string (name ^ " direction") in
  let message = field name "message" fields |> assoc (name ^ " message") in
  let kind = field name "kind" message |> string (name ^ " kind") in
  (direction, kind, message)

let outcome_terminal name message =
  let evidence = field name "evidence" message |> assoc (name ^ " evidence") in
  let core = field name "core" evidence |> assoc (name ^ " core evidence") in
  field name "terminal" core |> string (name ^ " terminal")

let step_state name templates state =
  let direction, kind, message = template_info templates name in
  let expected_direction =
    match kind with
    | "core_hello" | "effect_request" | "outcome" | "fatal" | "shutdown_ack" -> "core_to_host"
    | "host_select" | "invoke" | "effect_ok" | "effect_failure" | "cancel" | "shutdown" ->
        "host_to_core"
    | other -> fail name ("unknown message kind " ^ other)
  in
  Alcotest.(check string) (name ^ " direction") expected_direction direction;
  match (state, kind) with
  | Start, "core_hello" -> Hello
  | Hello, "host_select" -> Selected
  | Selected, "invoke" -> Running
  | Selected, "shutdown" -> Shutting_down
  | Running, "effect_request" -> Waiting
  | Waiting, "effect_ok" | Waiting, "effect_failure" | Waiting, "cancel" -> Running
  | Running, "outcome" -> Finished (outcome_terminal name message)
  | Shutting_down, "shutdown_ack" -> Finished "shutdown"
  | _ -> fail name ("invalid state transition for " ^ kind)

let check_evidence_echo name templates sequence =
  let messages = List.map (fun item -> template_info templates (string name item)) sequence in
  let by_kind expected =
    List.filter_map
      (fun (_, kind, message) -> if String.equal kind expected then Some message else None)
      messages
  in
  match (by_kind "invoke", by_kind "outcome") with
  | [ invoke ], [ outcome ] ->
      let evidence = field name "evidence" outcome |> assoc (name ^ " evidence") in
      let core = field name "core" evidence |> assoc (name ^ " core evidence") in
      List.iter
        (fun key ->
          Alcotest.(check bool)
            (name ^ " evidence echoes " ^ key)
            true
            (field name key invoke = field name key core))
        [ "target"; "interface"; "capabilities" ]
  | [], [] -> ()
  | _ -> fail name "expected exactly one invoke/outcome pair or a shutdown transcript"

let test_positive_sequences () =
  let document = load () in
  let templates = field "document" "templates" document |> assoc "templates" in
  let positives = field "document" "positive" document |> list "positive" in
  let names =
    List.map
      (fun item ->
        let fields = assoc "positive case" item in
        check_fields "positive case" [ "name"; "sequence"; "terminal" ] fields;
        let name = field "positive case" "name" fields |> string "positive name" in
        let sequence = field name "sequence" fields |> list (name ^ " sequence") in
        check_evidence_echo name templates sequence;
        let final =
          List.fold_left
            (fun state item -> step_state (string (name ^ " template") item) templates state)
            Start sequence
        in
        let actual_terminal =
          match final with
          | Finished terminal -> terminal
          | _ -> fail name "positive transcript did not finish exactly once"
        in
        Alcotest.(check string)
          (name ^ " terminal")
          (field name "terminal" fields |> string (name ^ " terminal"))
          actual_terminal;
        name)
      positives
  in
  check_unique "positive names" names

let is_lower_hex value =
  String.length value mod 2 = 0
  && String.for_all (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false) value

let rec check_template_hashes context = function
  | `String value when String.length value = 64 ->
      Alcotest.(check bool) (context ^ " canonical hash") true (is_lower_hex value)
  | `Assoc fields ->
      List.iter (fun (name, value) -> check_template_hashes (context ^ "/" ^ name) value) fields
  | `List items ->
      List.iteri
        (fun index value -> check_template_hashes (context ^ "/" ^ string_of_int index) value)
        items
  | _ -> ()

let test_template_identities () =
  let document = load () in
  field "document" "templates" document |> check_template_hashes "templates"

let expected_codes = List.init 15 (fun index -> Printf.sprintf "E%04d" (1600 + index))

let terminal_mapping item =
  let fields = assoc "terminal mapping" item in
  let kind = field "terminal mapping" "kind" fields |> string "mapping kind" in
  let expected =
    match kind with
    | "effect_failure" -> [ "category"; "completion"; "kind"; "primary_code"; "terminal" ]
    | "cancel" -> [ "completion"; "kind"; "primary_code"; "reason"; "terminal" ]
    | other -> fail "terminal mapping" ("unknown kind " ^ other)
  in
  check_fields "terminal mapping fields" expected fields;
  let category_field = if String.equal kind "effect_failure" then "category" else "reason" in
  let category = field "terminal mapping" category_field fields |> string "mapping category" in
  let completion = field "terminal mapping" "completion" fields |> string "mapping completion" in
  let code = field "terminal mapping" "primary_code" fields |> string "mapping code" in
  let terminal = field "terminal mapping" "terminal" fields |> string "mapping terminal" in
  (Printf.sprintf "%s/%s/%s=%s/%s" kind category completion code terminal, code)

let expected_terminal_mappings =
  [
    "effect_failure/unsupported_operation/not_started=E1606/host_failure";
    "effect_failure/refused_authority/not_started=E1607/host_failure";
    "effect_failure/outside_failure/failed=E1613/host_failure";
    "effect_failure/completion_unknown/unknown=E1612/completion_unknown";
    "cancel/cancelled/not_started=E1614/cancelled";
    "cancel/cancelled/failed=E1614/cancelled";
    "cancel/cancelled/unknown=E1612/completion_unknown";
    "cancel/timeout/not_started=E1609/cancelled";
    "cancel/timeout/failed=E1609/cancelled";
    "cancel/timeout/unknown=E1612/completion_unknown";
    "cancel/host_shutdown/not_started=E1610/cancelled";
    "cancel/host_shutdown/failed=E1610/cancelled";
    "cancel/host_shutdown/unknown=E1612/completion_unknown";
  ]

let check_raw_hex context wire_hex =
  Alcotest.(check bool) (context ^ " nonempty") true (String.length wire_hex > 0);
  Alcotest.(check bool) (context ^ " lowercase even hex") true (is_lower_hex wire_hex)

let rec expand_refs hard_limits = function
  | `Assoc [ ("$ref", `String "hard_limits") ] -> hard_limits
  | `Assoc fields ->
      `Assoc (List.map (fun (name, value) -> (name, expand_refs hard_limits value)) fields)
  | `List items -> `List (List.map (expand_refs hard_limits) items)
  | value -> value

let pointer_tokens context path =
  match String.split_on_char '/' path with
  | "" :: tokens when tokens <> [] ->
      List.iter
        (fun token ->
          if String.contains token '~' then
            fail context "fixture pointers use no escaped JSON-pointer token")
        tokens;
      tokens
  | _ -> fail context "expected a non-root JSON pointer"

let pointer_index context token =
  match int_of_string_opt token with
  | Some index when index >= 0 && String.equal token (string_of_int index) -> index
  | _ -> fail context (Printf.sprintf "invalid array index %S" token)

let check_mutation_pointer context op message path =
  let rec parent value = function
    | [ final ] -> (value, final)
    | token :: rest -> (
        match value with
        | `Assoc fields -> (
            match List.assoc_opt token fields with
            | Some child -> parent child rest
            | None -> fail context (Printf.sprintf "pointer member %S does not exist" token))
        | `List items -> (
            match List.nth_opt items (pointer_index context token) with
            | Some child -> parent child rest
            | None -> fail context (Printf.sprintf "pointer index %S does not exist" token))
        | _ -> fail context "pointer traverses a scalar")
    | [] -> fail context "expected a non-root mutation pointer"
  in
  let container, final = parent message (pointer_tokens context path) in
  match container with
  | `Assoc fields ->
      if (not (String.equal op "add")) && not (List.mem_assoc final fields) then
        fail context (Printf.sprintf "pointer member %S does not exist" final)
  | `List items ->
      let index = pointer_index context final in
      let maximum = if String.equal op "add" then List.length items else List.length items - 1 in
      if index > maximum then fail context (Printf.sprintf "pointer index %d does not exist" index)
  | _ -> fail context "mutation pointer parent is a scalar"

let test_hostile_cases () =
  let document = load () in
  let hard_limits = field "document" "hard_limits" document in
  let templates = field "document" "templates" document |> assoc "templates" in
  let positives = field "document" "positive" document |> list "positive" in
  let positive_sequences =
    List.map
      (fun item ->
        let fields = assoc "positive" item in
        ( field "positive" "name" fields |> string "positive name",
          field "positive" "sequence" fields |> list "positive sequence" ))
      positives
  in
  let hostile = field "document" "hostile" document |> list "hostile" in
  let names, hostile_codes =
    List.split
      (List.map
         (fun item ->
           let fields = assoc "hostile case" item in
           check_fields "hostile case fields"
             [ "base"; "expect"; "mutation"; "name"; "phase" ]
             fields;
           let name = field "hostile" "name" fields |> string "hostile name" in
           let base = field name "base" fields |> string (name ^ " base") in
           let sequence =
             match List.assoc_opt base positive_sequences with
             | Some value -> value
             | None -> fail name ("unknown positive base " ^ base)
           in
           let phase = field name "phase" fields |> string (name ^ " phase") in
           (match phase with
           | "framing" | "host_select" | "invoke" | "evaluation" | "effect_response" | "terminal" ->
               ()
           | other -> fail name ("unknown rejection phase " ^ other));
           let expectation = field name "expect" fields |> assoc (name ^ " expectation") in
           check_fields (name ^ " expectation fields")
             [
               "code";
               "effect_requests_before_failure";
               "forbid_outside_action";
               "terminal_frames_max";
             ]
             expectation;
           let code = field name "code" expectation |> string (name ^ " code") in
           ignore (field name "effect_requests_before_failure" expectation |> int name);
           ignore (field name "forbid_outside_action" expectation |> bool name);
           let terminal_max = field name "terminal_frames_max" expectation |> int name in
           Alcotest.(check int) (name ^ " one terminal frame") 1 terminal_max;
           let mutation = field name "mutation" fields |> assoc (name ^ " mutation") in
           let op = field name "op" mutation |> string (name ^ " mutation op") in
           (match op with
           | "replace" | "add" ->
               check_fields (name ^ " mutation fields") [ "frame"; "op"; "path"; "value" ] mutation;
               let frame = field name "frame" mutation |> int name in
               Alcotest.(check bool)
                 (name ^ " frame exists") true
                 (frame >= 0 && frame < List.length sequence);
               let path = field name "path" mutation |> string name in
               Alcotest.(check bool)
                 (name ^ " JSON pointer") true
                 (String.starts_with ~prefix:"/" path);
               let template = List.nth sequence frame |> string name in
               let _, _, message = template_info templates template in
               check_mutation_pointer name op (expand_refs hard_limits (`Assoc message)) path
           | "remove" ->
               check_fields (name ^ " mutation fields") [ "frame"; "op"; "path" ] mutation;
               let frame = field name "frame" mutation |> int name in
               Alcotest.(check bool)
                 (name ^ " frame exists") true
                 (frame >= 0 && frame < List.length sequence);
               let path = field name "path" mutation |> string name in
               let template = List.nth sequence frame |> string name in
               let _, _, message = template_info templates template in
               check_mutation_pointer name op (expand_refs hard_limits (`Assoc message)) path
           | "append" ->
               check_fields (name ^ " mutation fields") [ "op"; "template" ] mutation;
               let template = field name "template" mutation |> string name in
               ignore (template_info templates template)
           | "raw_wire" ->
               check_fields (name ^ " mutation fields") [ "frame"; "op"; "wire_hex" ] mutation;
               let frame = field name "frame" mutation |> int name in
               Alcotest.(check bool)
                 (name ^ " frame exists") true
                 (frame >= 0 && frame < List.length sequence);
               field name "wire_hex" mutation |> string name |> check_raw_hex name
           | other -> fail name ("unknown mutation op " ^ other));
           (name, code))
         hostile)
  in
  check_unique "hostile names" names;
  let mappings =
    field "document" "terminal_mappings" document
    |> list "terminal mappings" |> List.map terminal_mapping
  in
  let mapping_names, mapping_codes = List.split mappings in
  Alcotest.(check (list string))
    "complete terminal mapping matrix"
    (List.sort String.compare expected_terminal_mappings)
    (List.sort String.compare mapping_names);
  Alcotest.(check (list string))
    "complete E1600-E1614 coverage" expected_codes
    (List.sort_uniq String.compare (hostile_codes @ mapping_codes))

let read_file path =
  let channel = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr channel)
    (fun () -> really_input_string channel (in_channel_length channel))

let test_spec_lists_codes () =
  let source = read_file spec_file in
  List.iter
    (fun code ->
      Alcotest.(check bool)
        (code ^ " is documented") true
        (String.split_on_char ' ' source
        |> List.exists (fun token -> String.starts_with ~prefix:code token)))
    expected_codes

let suite =
  [
    Alcotest.test_case "document and hard limits" `Quick test_document_and_limits;
    Alcotest.test_case "positive state sequences" `Quick test_positive_sequences;
    Alcotest.test_case "template identities" `Quick test_template_identities;
    Alcotest.test_case "hostile cases and code coverage" `Quick test_hostile_cases;
    Alcotest.test_case "stable codes are documented" `Quick test_spec_lists_codes;
  ]
