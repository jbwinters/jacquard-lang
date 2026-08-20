open Jacquard
module Host = Host_protocol_v0

let fail_diagnostics diagnostics = String.concat "\n" (List.map Diag.to_string diagnostics)

let expect_ok label = function
  | Ok value -> value
  | Error diagnostics -> Alcotest.failf "%s failed:\n%s" label (fail_diagnostics diagnostics)

let expect_code label expected = function
  | Error (diagnostic :: _) ->
      Alcotest.(check string) label expected (Diag.code_or_uncoded diagnostic)
  | Error [] -> Alcotest.failf "%s returned an empty diagnostic list" label
  | Ok _ -> Alcotest.failf "%s unexpectedly succeeded" label

let byte value = String.make 1 (Char.chr value)

let prefix length =
  byte ((length lsr 24) land 0xff)
  ^ byte ((length lsr 16) land 0xff)
  ^ byte ((length lsr 8) land 0xff)
  ^ byte (length land 0xff)

let raw_frame payload = prefix (String.length payload) ^ payload

let select limits =
  `Assoc
    [
      ("kind", `String "host_select");
      ("limits", Host.limits_to_yojson limits);
      ("protocol", `String Host.protocol);
    ]

let member name json = Yojson.Safe.Util.member name json

let test_hello_exact () =
  let hello = Host.core_hello () in
  Alcotest.(check string)
    "carrier" Host.carrier
    Yojson.Safe.Util.(hello |> member "carrier" |> to_string);
  Alcotest.(check (list string))
    "versions" [ Host.protocol ]
    Yojson.Safe.Util.(hello |> member "versions" |> to_list |> filter_string);
  let expected_limits =
    [
      ("max_arguments", 64);
      ("max_collection_items", 1_024);
      ("max_diagnostic_bytes", 65_536);
      ("max_diagnostics", 32);
      ("max_effect_requests", 1_024);
      ("max_effects", 64);
      ("max_frame_bytes", 1_048_576);
      ("max_host_message_bytes", 4_096);
      ("max_json_depth", 64);
      ("max_operations", 256);
      ("max_stderr_bytes", 65_536);
      ("max_text_bytes", 262_144);
      ("max_value_nodes", 4_096);
    ]
  in
  let limits = member "limits" hello in
  List.iter
    (fun (name, expected) ->
      Alcotest.(check int) name expected Yojson.Safe.Util.(limits |> member name |> to_int))
    expected_limits;
  Alcotest.(check (list string))
    "exact limit fields" (List.map fst expected_limits)
    (match limits with `Assoc fields -> List.map fst fields | _ -> []);
  Alcotest.(check (list string))
    "exact hello fields"
    [ "carrier"; "kind"; "limits"; "versions" ]
    (match hello with `Assoc fields -> List.map fst fields |> List.sort String.compare | _ -> [])

let test_u32_frame_is_deterministic () =
  let json = `Assoc [ ("kind", `String "probe") ] in
  let first = expect_ok "first encode" (Host.encode_frame_bytes ~limits:Host.hard_limits json) in
  let second = expect_ok "second encode" (Host.encode_frame_bytes ~limits:Host.hard_limits json) in
  let payload = Yojson.Safe.to_string json in
  Alcotest.(check string) "deterministic bytes" first second;
  Alcotest.(check string)
    "big-endian prefix"
    (prefix (String.length payload))
    (String.sub first 0 4);
  Alcotest.(check string) "payload bytes" payload (String.sub first 4 (String.length first - 4))

let prop_frame_round_trip =
  QCheck.Test.make ~count:300 ~name:"bounded u32 JSON frames round-trip semantically"
    QCheck.(make Gen.(string_size ~gen:printable (int_bound 512)))
    (fun value ->
      let json = `Assoc [ ("kind", `String "probe"); ("value", `String value) ] in
      match Host.encode_frame_bytes ~limits:Host.hard_limits json with
      | Error _ -> false
      | Ok bytes -> (
          match Host.decode_frame_bytes ~limits:Host.hard_limits bytes with
          | Ok decoded -> Yojson.Safe.equal json decoded
          | Error _ -> false))

let test_stream_round_trip () =
  let path = Filename.temp_file "jacquard-host-frame-" ".bin" in
  Fun.protect
    ~finally:(fun () -> try Sys.remove path with Sys_error _ -> ())
    (fun () ->
      let json = `Assoc [ ("kind", `String "probe"); ("value", `String "stream") ] in
      let output = open_out_bin path in
      Fun.protect
        ~finally:(fun () -> close_out_noerr output)
        (fun () -> expect_ok "stream write" (Host.write_frame ~limits:Host.hard_limits output json));
      let input = open_in_bin path in
      let decoded =
        Fun.protect
          ~finally:(fun () -> close_in_noerr input)
          (fun () -> expect_ok "stream read" (Host.read_frame ~limits:Host.hard_limits input))
      in
      Alcotest.(check bool) "semantic stream value" true (Yojson.Safe.equal json decoded);
      let closed_input = open_in_bin path in
      close_in closed_input;
      expect_code "closed input carrier" "E1611"
        (Host.read_frame ~limits:Host.hard_limits closed_input);
      let closed_output = open_out_bin path in
      close_out closed_output;
      expect_code "closed output carrier" "E1611"
        (Host.write_frame ~limits:Host.hard_limits closed_output json))

let test_zero_and_oversized_prefixes () =
  expect_code "zero frame" "E1601" (Host.decode_frame_bytes ~limits:Host.hard_limits (prefix 0));
  let oversized = Host.hard_limits.max_frame_bytes + 1 in
  expect_code "oversized frame" "E1602"
    (Host.decode_frame_bytes ~limits:Host.hard_limits (prefix oversized))

let test_truncated_frame_parts () =
  List.iter
    (fun bytes ->
      expect_code "truncated prefix" "E1611"
        (Host.decode_frame_bytes ~limits:Host.hard_limits bytes))
    [ ""; "\x00"; "\x00\x00"; "\x00\x00\x00" ];
  expect_code "truncated payload" "E1611"
    (Host.decode_frame_bytes ~limits:Host.hard_limits (prefix 4 ^ "{}"))

let test_extra_bytes_and_trailing_json () =
  expect_code "bytes after frame" "E1601"
    (Host.decode_frame_bytes ~limits:Host.hard_limits (raw_frame "{}" ^ "x"));
  expect_code "second JSON value in payload" "E1601"
    (Host.decode_frame_bytes ~limits:Host.hard_limits (raw_frame "{}{}"))

let test_utf8_and_surrogate_rejection () =
  let invalid_utf8 = "{\"value\":\"" ^ byte 0x80 ^ "\"}" in
  expect_code "invalid raw UTF-8" "E1601"
    (Host.decode_frame_bytes ~limits:Host.hard_limits (raw_frame invalid_utf8));
  expect_code "escaped lone surrogate" "E1601"
    (Host.decode_frame_bytes ~limits:Host.hard_limits (raw_frame "{\"value\":\"\\ud800\"}"));
  let pair =
    expect_ok "escaped surrogate pair"
      (Host.decode_frame_bytes ~limits:Host.hard_limits
         (raw_frame "{\"value\":\"\\ud83d\\ude00\"}"))
  in
  Alcotest.(check string)
    "surrogate pair becomes one scalar" "😀"
    Yojson.Safe.Util.(pair |> member "value" |> to_string)

let test_duplicate_keys_rejected_recursively () =
  expect_code "duplicate root key" "E1601"
    (Host.decode_frame_bytes ~limits:Host.hard_limits (raw_frame "{\"a\":1,\"a\":2}"));
  expect_code "duplicate nested key" "E1601"
    (Host.decode_frame_bytes ~limits:Host.hard_limits (raw_frame "{\"outer\":{\"a\":1,\"a\":2}}"))

let test_object_depth_and_collection_limits () =
  expect_code "non-object payload" "E1601"
    (Host.decode_frame_bytes ~limits:Host.hard_limits (raw_frame "[]"));
  let shallow = { Host.hard_limits with max_json_depth = 2 } in
  expect_code "JSON depth" "E1602"
    (Host.decode_frame_bytes ~limits:shallow (raw_frame "{\"a\":{\"b\":{}}}"));
  let exact_depth = { Host.hard_limits with max_json_depth = 3 } in
  ignore
    (expect_ok "exact JSON depth"
       (Host.decode_frame_bytes ~limits:exact_depth (raw_frame "{\"a\":{\"b\":{}}}")));
  let one_item = { Host.hard_limits with max_collection_items = 1 } in
  expect_code "collection items" "E1602"
    (Host.decode_frame_bytes ~limits:one_item (raw_frame "{\"a\":[1,2]}"));
  ignore
    (expect_ok "exact collection items"
       (Host.decode_frame_bytes ~limits:one_item (raw_frame "{\"a\":[1]}")))

let test_select_accepts_exact_limits_and_key_reordering () =
  let accepted = expect_ok "exact selection" (Host.parse_host_select (select Host.hard_limits)) in
  Alcotest.(check int)
    "selected frame limit" Host.hard_limits.max_frame_bytes accepted.max_frame_bytes;
  let reordered =
    `Assoc
      [
        ("protocol", `String Host.protocol);
        ("limits", Host.limits_to_yojson Host.hard_limits);
        ("kind", `String "host_select");
      ]
  in
  let reordered = expect_ok "reordered selection" (Host.parse_host_select reordered) in
  Alcotest.(check bool) "key order is insignificant" true (reordered = accepted)

let test_select_unknown_version () =
  let unknown =
    `Assoc
      [
        ("kind", `String "host_select");
        ("limits", Host.limits_to_yojson Host.hard_limits);
        ("protocol", `String "jacquard-host-v9");
      ]
  in
  expect_code "unknown version" "E1600" (Host.parse_host_select unknown)

let test_select_shape_failures () =
  let missing = `Assoc [ ("kind", `String "host_select"); ("protocol", `String Host.protocol) ] in
  let extra =
    match select Host.hard_limits with
    | `Assoc fields -> `Assoc (("extra", `Null) :: fields)
    | _ -> assert false
  in
  let wrong_scalar =
    `Assoc
      [
        ("kind", `String "host_select");
        ("limits", `String "large");
        ("protocol", `String Host.protocol);
      ]
  in
  let missing_limit =
    match Host.limits_to_yojson Host.hard_limits with
    | `Assoc (_ :: fields) ->
        `Assoc
          [
            ("kind", `String "host_select");
            ("limits", `Assoc fields);
            ("protocol", `String Host.protocol);
          ]
    | _ -> assert false
  in
  let extra_limit =
    match Host.limits_to_yojson Host.hard_limits with
    | `Assoc fields ->
        `Assoc
          [
            ("kind", `String "host_select");
            ("limits", `Assoc (("extra", `Int 1) :: fields));
            ("protocol", `String Host.protocol);
          ]
    | _ -> assert false
  in
  let noninteger_limit =
    match Host.limits_to_yojson Host.hard_limits with
    | `Assoc fields ->
        let fields =
          List.map
            (fun (name, value) ->
              if name = "max_arguments" then (name, `String "64") else (name, value))
            fields
        in
        `Assoc
          [
            ("kind", `String "host_select");
            ("limits", `Assoc fields);
            ("protocol", `String Host.protocol);
          ]
    | _ -> assert false
  in
  List.iter
    (fun (label, value) -> expect_code label "E1601" (Host.parse_host_select value))
    [
      ("missing limits", missing);
      ("extra selection field", extra);
      ("wrong limits scalar", wrong_scalar);
      ("missing limit field", missing_limit);
      ("extra limit field", extra_limit);
      ("noninteger limit field", noninteger_limit);
    ]

let test_select_limit_bounds () =
  let nonpositive = { Host.hard_limits with max_arguments = 0 } in
  let excessive =
    { Host.hard_limits with max_effect_requests = Host.hard_limits.max_effect_requests + 1 }
  in
  expect_code "nonpositive limit" "E1602" (Host.parse_host_select (select nonpositive));
  expect_code "excessive limit" "E1602" (Host.parse_host_select (select excessive))

let test_select_mandatory_terminal_capacity () =
  let too_shallow = { Host.hard_limits with max_json_depth = 2 } in
  let no_fatal_frame = { Host.hard_limits with max_frame_bytes = 1 } in
  let no_diagnostic = { Host.hard_limits with max_diagnostic_bytes = 1 } in
  expect_code "fatal depth capacity" "E1602" (Host.parse_host_select (select too_shallow));
  expect_code "fatal frame capacity" "E1602" (Host.parse_host_select (select no_fatal_frame));
  expect_code "fatal diagnostic capacity" "E1602" (Host.parse_host_select (select no_diagnostic))

let test_shutdown_exact () =
  let shutdown = `Assoc [ ("kind", `String "shutdown"); ("protocol", `String Host.protocol) ] in
  expect_ok "shutdown" (Host.parse_shutdown ~limits:Host.hard_limits shutdown);
  Alcotest.(check bool)
    "deterministic ack" true
    (Yojson.Safe.equal
       (`Assoc [ ("kind", `String "shutdown_ack"); ("protocol", `String Host.protocol) ])
       (Host.shutdown_ack ()))

let test_shutdown_shape_failure () =
  let extra =
    `Assoc [ ("extra", `Null); ("kind", `String "shutdown"); ("protocol", `String Host.protocol) ]
  in
  expect_code "extra shutdown field" "E1601" (Host.parse_shutdown ~limits:Host.hard_limits extra)

let test_shutdown_version_and_state_failures () =
  let unknown = `Assoc [ ("kind", `String "shutdown"); ("protocol", `String "jacquard-host-v9") ] in
  let wrong_kind = `Assoc [ ("kind", `String "invoke"); ("protocol", `String Host.protocol) ] in
  expect_code "shutdown unknown version" "E1600"
    (Host.parse_shutdown ~limits:Host.hard_limits unknown);
  expect_code "shutdown wrong state" "E1608"
    (Host.parse_shutdown ~limits:Host.hard_limits wrong_kind)

let suite =
  [
    Alcotest.test_case "hard-limit hello is exact" `Quick test_hello_exact;
    Alcotest.test_case "u32 frame bytes are deterministic" `Quick test_u32_frame_is_deterministic;
    QCheck_alcotest.to_alcotest prop_frame_round_trip;
    Alcotest.test_case "stream frame round-trip" `Quick test_stream_round_trip;
    Alcotest.test_case "zero and oversized prefixes fail closed" `Quick
      test_zero_and_oversized_prefixes;
    Alcotest.test_case "truncated frame parts are carrier loss" `Quick test_truncated_frame_parts;
    Alcotest.test_case "extra carrier and JSON bytes fail closed" `Quick
      test_extra_bytes_and_trailing_json;
    Alcotest.test_case "invalid UTF-8 and surrogates fail closed" `Quick
      test_utf8_and_surrogate_rejection;
    Alcotest.test_case "duplicate keys fail recursively" `Quick
      test_duplicate_keys_rejected_recursively;
    Alcotest.test_case "object, depth, and collection limits" `Quick
      test_object_depth_and_collection_limits;
    Alcotest.test_case "exact selection ignores key order" `Quick
      test_select_accepts_exact_limits_and_key_reordering;
    Alcotest.test_case "unknown selection version" `Quick test_select_unknown_version;
    Alcotest.test_case "selection shape failures" `Quick test_select_shape_failures;
    Alcotest.test_case "selection limit bounds" `Quick test_select_limit_bounds;
    Alcotest.test_case "mandatory terminal capacity" `Quick test_select_mandatory_terminal_capacity;
    Alcotest.test_case "shutdown and ack are exact" `Quick test_shutdown_exact;
    Alcotest.test_case "shutdown shape failure" `Quick test_shutdown_shape_failure;
    Alcotest.test_case "shutdown version and state failures" `Quick
      test_shutdown_version_and_state_failures;
  ]
