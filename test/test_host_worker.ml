(* HB.2c: the opt-in serial worker over scripted host input and captured Core output. *)

open Jacquard
module Host = Host_protocol_v0

let fail_diagnostics diagnostics = String.concat "\n" (List.map Diag.to_string diagnostics)

let expect_ok label = function
  | Ok value -> value
  | Error diagnostics -> Alcotest.failf "%s failed:\n%s" label (fail_diagnostics diagnostics)

let fresh_path =
  let serial = ref 0 in
  fun label ->
    incr serial;
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "jacquard-host-worker-%s-%d-%d" label (Unix.getpid ()) !serial)

let read_file path =
  let channel = open_in_bin path in
  let contents = really_input_string channel (in_channel_length channel) in
  close_in channel;
  contents

let write_file path contents =
  let channel = open_out_bin path in
  output_string channel contents;
  close_out channel

let put_src store source =
  let form =
    expect_ok "parse fixture declaration" (Reader.parse_one ~file:"host-worker.jqd" source)
  in
  let declaration = expect_ok "validate fixture declaration" (Kernel.decl_of_form form) in
  let declaration =
    expect_ok "resolve fixture declaration"
      (Resolve.resolve_decl (Store.names_view store) declaration)
  in
  expect_ok "store fixture declaration" (Store.put_decl store declaration)

let named name hashes = List.assoc name hashes.Canon.named

type fixture = {
  store_dir : string;
  prepared : Host_worker.prepared;
  int_type : Hash.t;
  text_type : Hash.t;
  world_effect : Hash.t;
  send_operation : Hash.t;
  double : Hash.t;
  echo : Hash.t;
  twice : Hash.t;
  crash : Hash.t;
}

(* Populate a store with the real prelude, then reopen it without reloading the prelude: this is
   exactly the startup path of [jacquard host worker --store DIR]. *)
let make_fixture () =
  let dir = fresh_path "store" in
  let store = expect_ok "open fixture store" (Store.open_store dir) in
  ignore (expect_ok "load prelude" (Prelude.load ~dir:"../prelude" store));
  let world =
    put_src store "(defeffect worker-world () (op worker.send once ((tref text)) (tref text)))"
  in
  let double =
    put_src store
      "(defterm ((binding worker.double ((tarrow ((tref int)) (row) (tref int))) (lam ((pvar n)) \
       (app (var mul) (var n) (lit 2))))))"
  in
  let echo =
    put_src store
      "(defterm ((binding worker.echo ((tarrow ((tref text)) (row (eref worker-world)) (tref \
       text))) (lam ((pvar body)) (app (var worker.send) (var body))))))"
  in
  let twice =
    put_src store
      "(defterm ((binding worker.twice ((tarrow ((tref text)) (row (eref worker-world)) (tref \
       text))) (lam ((pvar body)) (app (var worker.send) (app (var worker.send) (var body)))))))"
  in
  let crash =
    put_src store
      "(defterm ((binding worker.crash ((tarrow ((tref int)) (row) (tref int))) (lam ((pvar n)) \
       (app (var div) (var n) (lit 0))))))"
  in
  let reopened = expect_ok "reopen fixture store" (Store.open_store dir) in
  let prepared = expect_ok "prepare reopened store" (Host_worker.prepare reopened) in
  let checker = expect_ok "fixture checker" (Check.make_ctx reopened) in
  let primitives = Check.primitive_types checker in
  {
    store_dir = dir;
    prepared;
    int_type = primitives.Check.int_type;
    text_type = primitives.Check.text_type;
    world_effect = named "worker-world" world;
    send_operation = named "worker.send" world;
    double = named "worker.double" double;
    echo = named "worker.echo" echo;
    twice = named "worker.twice" twice;
    crash = named "worker.crash" crash;
  }

let fixture = lazy (make_fixture ())
let fixture () = Lazy.force fixture

(* --- wire helpers --- *)

let encode json =
  expect_ok "encode host frame" (Host.encode_frame_bytes ~limits:Host.hard_limits json)

let script frames = String.concat "" (List.map encode frames)

let bytes_of_hex hex =
  String.init
    (String.length hex / 2)
    (fun i -> Char.chr (int_of_string ("0x" ^ String.sub hex (2 * i) 2)))

let decode_frames bytes =
  let length = String.length bytes in
  let rec go offset acc =
    if offset = length then List.rev acc
    else if offset + 4 > length then Alcotest.fail "truncated Core frame prefix"
    else
      let size =
        (Char.code bytes.[offset] lsl 24)
        lor (Char.code bytes.[offset + 1] lsl 16)
        lor (Char.code bytes.[offset + 2] lsl 8)
        lor Char.code bytes.[offset + 3]
      in
      if offset + 4 + size > length then Alcotest.fail "truncated Core frame payload"
      else
        let payload = String.sub bytes (offset + 4) size in
        go (offset + 4 + size) (Yojson.Safe.from_string payload :: acc)
  in
  go 0 []

type run = { status : Host_worker.exit_status; frames : Yojson.Safe.t list; operator : string }

let run ?(prepared = (fixture ()).prepared) host_bytes =
  let base = fresh_path "io" in
  let input_path = base ^ ".in" and output_path = base ^ ".out" and operator_path = base ^ ".err" in
  write_file input_path host_bytes;
  let input = open_in_bin input_path in
  let output = open_out_bin output_path in
  let operator = open_out_bin operator_path in
  let status = Host_worker.serve prepared ~input ~output ~operator in
  close_in input;
  close_out output;
  close_out operator;
  let frames = decode_frames (read_file output_path) in
  let operator = read_file operator_path in
  List.iter Sys.remove [ input_path; output_path; operator_path ];
  { status; frames; operator }

(* --- envelope builders --- *)

let hash_json hash = `String (Hash.to_hex hash)

let nominal hash =
  `Assoc [ ("arguments", `List []); ("identity", hash_json hash); ("kind", `String "nominal") ]

let int_value n = `Assoc [ ("kind", `String "int"); ("value", `String (string_of_int n)) ]
let text_value text = `Assoc [ ("kind", `String "text"); ("value", `String text) ]

let select ?(limits = Host.hard_limits) () =
  `Assoc
    [
      ("kind", `String "host_select");
      ("limits", Host.limits_to_yojson limits);
      ("protocol", `String Host.protocol);
    ]

let shutdown = `Assoc [ ("kind", `String "shutdown"); ("protocol", `String Host.protocol) ]

let invoke ~target ~parameters ~result ~effects ~operations ~arguments =
  `Assoc
    [
      ("arguments", `List arguments);
      ( "capabilities",
        `Assoc [ ("effects", `List (List.map hash_json effects)); ("operations", `List operations) ]
      );
      ( "interface",
        `Assoc
          [
            ("effects", `List (List.map hash_json effects));
            ("parameters", `List parameters);
            ("result", result);
          ] );
      ("invocation_id", `String "0000000000000000");
      ("kind", `String "invoke");
      ("protocol", `String Host.protocol);
      ("target", `Assoc [ ("callable", hash_json target); ("kind", `String "store-term-v0") ]);
    ]

let send_entry ?(mode = "once") f =
  `Assoc
    [
      ("effect", hash_json f.world_effect);
      ("mode", `String mode);
      ("operation", hash_json f.send_operation);
    ]

let double_invoke f n =
  invoke ~target:f.double
    ~parameters:[ nominal f.int_type ]
    ~result:(nominal f.int_type) ~effects:[] ~operations:[]
    ~arguments:[ int_value n ]

let crash_invoke f n =
  invoke ~target:f.crash
    ~parameters:[ nominal f.int_type ]
    ~result:(nominal f.int_type) ~effects:[] ~operations:[]
    ~arguments:[ int_value n ]

let world_invoke ?(configured = true) f target body =
  invoke ~target
    ~parameters:[ nominal f.text_type ]
    ~result:(nominal f.text_type) ~effects:[ f.world_effect ]
    ~operations:(if configured then [ send_entry f ] else [])
    ~arguments:[ text_value body ]

let echo_invoke ?configured f body = world_invoke ?configured f f.echo body

let response ?(ordinal = 1) kind fields =
  `Assoc
    ([
       ("invocation_id", `String "0000000000000000");
       ("kind", `String kind);
       ("protocol", `String Host.protocol);
       ("request_id", `String (Printf.sprintf "%016x" ordinal));
     ]
    @ fields)

let effect_ok ?ordinal value = response ?ordinal "effect_ok" [ ("value", value) ]

let effect_failure category completion =
  response "effect_failure"
    [
      ("category", `String category);
      ("completion", `String completion);
      ("message", `String "redacted host detail");
    ]

let cancel reason completion =
  response "cancel" [ ("reason", `String reason); ("completion", `String completion) ]

let replace_field name value = function
  | `Assoc fields ->
      `Assoc (List.map (fun (k, v) -> if k = name then (k, value) else (k, v)) fields)
  | json -> json

let append_field name value = function
  | `Assoc fields -> `Assoc (fields @ [ (name, value) ])
  | json -> json

let update_path path f json =
  let rec go path json =
    match (path, json) with
    | [], json -> f json
    | key :: rest, `Assoc fields ->
        `Assoc (List.map (fun (k, v) -> if k = key then (k, go rest v) else (k, v)) fields)
    | key :: rest, `List items ->
        `List (List.mapi (fun i v -> if string_of_int i = key then go rest v else v) items)
    | _ -> json
  in
  go path json

(* --- accessors --- *)

let get name json = Yojson.Safe.Util.member name json
let text json = Yojson.Safe.Util.to_string json
let items json = Yojson.Safe.Util.to_list json
let kind json = text (get "kind" json)
let core json = get "core" (get "evidence" json)
let requests json = items (get "effect_requests" (core json))
let observations json = items (get "responses" (get "host_observations" (get "evidence" json)))
let diagnostics json = items (get "diagnostics" json)
let outcome_diagnostics json = diagnostics (get "result" json)
let first_code diagnostics = text (get "code" (List.hd diagnostics))

let check_json label expected actual =
  Alcotest.(check string) label (Yojson.Safe.to_string expected) (Yojson.Safe.to_string actual)

let check_status label expected actual =
  Alcotest.(check int) label (Host_worker.exit_code expected) (Host_worker.exit_code actual)

let check_hello json =
  Alcotest.(check string) "first frame" "core_hello" (kind json);
  Alcotest.(check string) "carrier" Host.carrier (text (get "carrier" json));
  check_json "hard limits" (Host.limits_to_yojson Host.hard_limits) (get "limits" json);
  check_json "versions" (`List [ `String Host.protocol ]) (get "versions" json)

(* Every run starts with core_hello and ends with exactly one terminal frame. *)
let terminal_after ?(requests = 0) label run =
  match run.frames with
  | hello :: rest ->
      check_hello hello;
      Alcotest.(check int) (label ^ " frame count") (requests + 1) (List.length rest);
      List.iteri
        (fun i frame ->
          if i < requests then
            Alcotest.(check string) (label ^ " request kind") "effect_request" (kind frame))
        rest;
      List.nth rest requests
  | [] -> Alcotest.fail (label ^ " produced no frames")

let check_fatal label ~code run =
  let terminal = terminal_after label run in
  Alcotest.(check string) (label ^ " terminal kind") "fatal" (kind terminal);
  Alcotest.(check string) (label ^ " code") code (first_code (diagnostics terminal));
  check_json (label ^ " protocol") (`String Host.protocol) (get "protocol" terminal);
  Alcotest.(check bool)
    (label ^ " carries no invocation")
    true
    (get "invocation_id" terminal = `Null && get "evidence" terminal = `Null)

let check_outcome ?requests label ~code ~terminal run =
  let frame = terminal_after ?requests label run in
  Alcotest.(check string) (label ^ " terminal kind") "outcome" (kind frame);
  Alcotest.(check string) (label ^ " result kind") "error" (kind (get "result" frame));
  Alcotest.(check string) (label ^ " code") code (first_code (outcome_diagnostics frame));
  Alcotest.(check string) (label ^ " terminal") terminal (text (get "terminal" (core frame)));
  frame

(* --- tests --- *)

let test_exit_codes () =
  Alcotest.(check (list int))
    "frozen exit statuses" [ 0; 64; 70; 74 ]
    (List.map Host_worker.exit_code
       Host_worker.[ Terminal_written; Protocol_failure; Internal_failure; Carrier_lost ])

let test_pure_success () =
  let f = fixture () in
  let run = run (script [ select (); double_invoke f 21 ]) in
  check_status "exit" Host_worker.Terminal_written run.status;
  let outcome = terminal_after "pure" run in
  Alcotest.(check string) "kind" "outcome" (kind outcome);
  check_json "result"
    (`Assoc [ ("kind", `String "ok"); ("value", int_value 42) ])
    (get "result" outcome);
  Alcotest.(check string) "terminal" "ok" (text (get "terminal" (core outcome)));
  check_json "target"
    (`Assoc [ ("callable", hash_json f.double); ("kind", `String "store-term-v0") ])
    (get "target" (core outcome));
  Alcotest.(check int) "no requests" 0 (List.length (requests outcome));
  Alcotest.(check int) "no observations" 0 (List.length (observations outcome));
  Alcotest.(check string) "quiet operator channel" "" run.operator

let test_effect_exchange () =
  let f = fixture () in
  let run = run (script [ select (); echo_invoke f "ping"; effect_ok (text_value "pong") ]) in
  check_status "exit" Host_worker.Terminal_written run.status;
  match run.frames with
  | [ hello; request; outcome ] ->
      check_hello hello;
      Alcotest.(check string) "request kind" "effect_request" (kind request);
      check_json "request id" (`String "0000000000000001") (get "request_id" request);
      check_json "request effect" (hash_json f.world_effect) (get "effect" request);
      check_json "request operation" (hash_json f.send_operation) (get "operation" request);
      check_json "request mode" (`String "once") (get "mode" request);
      check_json "request arguments" (`List [ text_value "ping" ]) (get "arguments" request);
      check_json "request protocol" (`String Host.protocol) (get "protocol" request);
      check_json "result"
        (`Assoc [ ("kind", `String "ok"); ("value", text_value "pong") ])
        (get "result" outcome);
      check_json "request evidence"
        (`List
           [
             `Assoc
               [
                 ("effect", hash_json f.world_effect);
                 ("operation", hash_json f.send_operation);
                 ("ordinal", `Int 1);
               ];
           ])
        (get "effect_requests" (core outcome));
      check_json "observation"
        (`List
           [
             `Assoc
               [
                 ("category", `String "ok"); ("completion", `String "completed"); ("ordinal", `Int 1);
               ];
           ])
        (`List (observations outcome))
  | frames -> Alcotest.failf "expected hello, request, outcome; got %d frames" (List.length frames)

let test_sequential_requests () =
  let f = fixture () in
  let run =
    run
      (script
         [
           select ();
           world_invoke f f.twice "first";
           effect_ok ~ordinal:1 (text_value "second");
           effect_ok ~ordinal:2 (text_value "third");
         ])
  in
  check_status "exit" Host_worker.Terminal_written run.status;
  match run.frames with
  | [ _; first; second; outcome ] ->
      check_json "first id" (`String "0000000000000001") (get "request_id" first);
      check_json "first argument" (`List [ text_value "first" ]) (get "arguments" first);
      check_json "second id" (`String "0000000000000002") (get "request_id" second);
      check_json "second argument carries the first response"
        (`List [ text_value "second" ])
        (get "arguments" second);
      check_json "final value" (text_value "third") (get "value" (get "result" outcome));
      Alcotest.(check int) "two requests" 2 (List.length (requests outcome));
      Alcotest.(check int) "two observations" 2 (List.length (observations outcome))
  | frames -> Alcotest.failf "expected four frames; got %d" (List.length frames)

let test_host_failures () =
  let f = fixture () in
  List.iter
    (fun (category, completion, code, terminal) ->
      let run =
        run (script [ select (); echo_invoke f "ping"; effect_failure category completion ])
      in
      check_status category Host_worker.Terminal_written run.status;
      let outcome = check_outcome ~requests:1 category ~code ~terminal run in
      check_json (category ^ " observation")
        (`Assoc
           [
             ("category", `String category); ("completion", `String completion); ("ordinal", `Int 1);
           ])
        (List.hd (observations outcome)))
    [
      ("unsupported_operation", "not_started", "E1606", "host_failure");
      ("refused_authority", "not_started", "E1607", "host_failure");
      ("outside_failure", "failed", "E1613", "host_failure");
      ("completion_unknown", "unknown", "E1612", "completion_unknown");
    ]

let test_cancellations () =
  let f = fixture () in
  List.iter
    (fun (reason, known_code) ->
      List.iter
        (fun completion ->
          let label = reason ^ "/" ^ completion in
          let run = run (script [ select (); echo_invoke f "ping"; cancel reason completion ]) in
          check_status label Host_worker.Terminal_written run.status;
          let code = if completion = "unknown" then "E1612" else known_code in
          let terminal = if completion = "unknown" then "completion_unknown" else "cancelled" in
          let outcome = check_outcome ~requests:1 label ~code ~terminal run in
          check_json (label ^ " observation")
            (`Assoc
               [
                 ("category", `String reason);
                 ("completion", `String completion);
                 ("ordinal", `Int 1);
               ])
            (List.hd (observations outcome)))
        [ "not_started"; "failed"; "unknown" ])
    [ ("cancelled", "E1614"); ("timeout", "E1609"); ("host_shutdown", "E1610") ]

let test_shutdown () =
  let run = run (script [ select (); shutdown ]) in
  check_status "exit" Host_worker.Terminal_written run.status;
  let ack = terminal_after "shutdown" run in
  check_json "acknowledgement" (Host.shutdown_ack ()) ack;
  Alcotest.(check string) "quiet operator channel" "" run.operator

let test_preflight_fatals () =
  let f = fixture () in
  let cases =
    [
      ( "unknown-version",
        [ replace_field "protocol" (`String "jacquard-host-v1") (select ()) ],
        "E1600" );
      ( "nonpositive-selected-limit",
        [ select ~limits:{ Host.hard_limits with max_frame_bytes = 0 } () ],
        "E1602" );
      ( "unknown-invoke-field",
        [ select (); append_field "display_name" (`String "mutable-name") (double_invoke f 1) ],
        "E1601" );
      ( "malformed-target-identity",
        [
          select ();
          update_path [ "target"; "callable" ]
            (fun _ -> `String (String.make 64 'A'))
            (double_invoke f 1);
        ],
        "E1601" );
      ( "absent-target",
        [
          select ();
          update_path [ "target"; "callable" ]
            (fun _ -> `String (String.make 64 'a'))
            (double_invoke f 1);
        ],
        "E1603" );
      ( "interface-mismatch",
        [
          select ();
          update_path
            [ "interface"; "parameters"; "0" ]
            (fun _ -> `Assoc [ ("items", `List []); ("kind", `String "tuple") ])
            (double_invoke f 1);
        ],
        "E1603" );
      ( "unsupported-secret-value",
        [
          select ();
          update_path [ "arguments"; "0" ]
            (fun _ -> `Assoc [ ("kind", `String "secret"); ("value", `String "must-not-cross") ])
            (double_invoke f 1);
        ],
        "E1604" );
      ( "extra-capability",
        [
          select ();
          update_path [ "capabilities"; "effects" ]
            (fun effects -> `List (items effects @ [ `String (String.make 64 'e') ]))
            (echo_invoke f "ping");
        ],
        "E1605" );
      ( "multi-operation-registry-entry",
        [
          select ();
          update_path
            [ "capabilities"; "operations"; "0" ]
            (fun _ -> send_entry ~mode:"multi" f)
            (echo_invoke f "ping");
        ],
        "E1605" );
      ("response-before-invoke", [ select (); effect_ok (text_value "early") ], "E1601");
      ("host-select-twice", [ select (); select () ], "E1601");
    ]
  in
  List.iter
    (fun (label, frames, code) ->
      let run = run (script frames) in
      check_status label Host_worker.Terminal_written run.status;
      check_fatal label ~code run)
    cases

let test_unconfigured_operation () =
  let f = fixture () in
  let run = run (script [ select (); echo_invoke ~configured:false f "ping" ]) in
  check_status "exit" Host_worker.Terminal_written run.status;
  let outcome = check_outcome "unconfigured" ~code:"E1606" ~terminal:"diagnostic" run in
  Alcotest.(check int) "no request left Core" 0 (List.length (requests outcome));
  check_json "empty registry retained" (`List [])
    (get "operations" (get "capabilities" (core outcome)))

let test_wrong_response_id () =
  let f = fixture () in
  let run =
    run (script [ select (); echo_invoke f "ping"; effect_ok ~ordinal:2 (text_value "pong") ])
  in
  check_status "exit" Host_worker.Terminal_written run.status;
  let outcome = check_outcome ~requests:1 "stale id" ~code:"E1608" ~terminal:"diagnostic" run in
  Alcotest.(check int) "request retained" 1 (List.length (requests outcome));
  Alcotest.(check int) "rejected response not observed" 0 (List.length (observations outcome))

let test_message_after_outcome () =
  let f = fixture () in
  let run =
    run
      (script
         [
           select ();
           echo_invoke f "ping";
           effect_ok (text_value "pong");
           effect_ok (text_value "late");
         ])
  in
  check_status "exit" Host_worker.Terminal_written run.status;
  let outcome = terminal_after ~requests:1 "late message" run in
  check_json "single terminal is the ok outcome"
    (`Assoc [ ("kind", `String "ok"); ("value", text_value "pong") ])
    (get "result" outcome)

let test_runtime_failure () =
  let f = fixture () in
  let run = run (script [ select (); crash_invoke f 7 ]) in
  check_status "exit" Host_worker.Terminal_written run.status;
  let outcome = terminal_after "runtime failure" run in
  Alcotest.(check string) "error result" "error" (kind (get "result" outcome));
  Alcotest.(check string) "terminal" "diagnostic" (text (get "terminal" (core outcome)));
  let diagnostic = List.hd (outcome_diagnostics outcome) in
  Alcotest.(check string)
    "runtime summary" "Arithmetic operation failed"
    (text (get "summary" diagnostic));
  Alcotest.(check string) "runtime domain" "runtime" (text (get "domain" diagnostic))

let test_malformed_response_frame () =
  let f = fixture () in
  let run = run (script [ select (); echo_invoke f "ping" ] ^ bytes_of_hex "000000037bff7d") in
  check_status "exit" Host_worker.Terminal_written run.status;
  let outcome =
    check_outcome ~requests:1 "malformed response" ~code:"E1608" ~terminal:"diagnostic" run
  in
  Alcotest.(check int) "no observation" 0 (List.length (observations outcome))

let test_oversized_response_frame () =
  let f = fixture () in
  let limits = { Host.hard_limits with max_frame_bytes = 4096 } in
  let run = run (script [ select ~limits (); echo_invoke f "ping" ] ^ bytes_of_hex "00002000") in
  check_status "exit" Host_worker.Terminal_written run.status;
  ignore (check_outcome ~requests:1 "oversized response" ~code:"E1602" ~terminal:"diagnostic" run)

let test_raw_framing () =
  List.iter
    (fun (label, hex, code) ->
      let run = run (bytes_of_hex hex) in
      check_status label Host_worker.Terminal_written run.status;
      check_fatal label ~code run)
    [
      ( "duplicate-json-key",
        "000000267b226b696e64223a22686f73745f73656c656374222c226b696e64223a22696e766f6b65227d",
        "E1601" );
      ("invalid-utf8", "000000037bff7d", "E1601");
      ("oversized-frame-prefix", "00100001", "E1602");
    ]

let test_carrier_loss_before_invocation () =
  List.iter
    (fun (label, hex) ->
      let run = run (bytes_of_hex hex) in
      check_status label Host_worker.Carrier_lost run.status;
      check_fatal label ~code:"E1611" run;
      Alcotest.(check bool)
        (label ^ " operator note") true
        (String.length run.operator > 0
        && String.length run.operator <= Host.hard_limits.max_stderr_bytes))
    [
      ("truncated-length-prefix", "0000");
      ("truncated-frame-payload", "000000057b7d");
      ("empty-input", "");
    ]

let test_carrier_loss_while_waiting () =
  let f = fixture () in
  let run = run (script [ select (); echo_invoke f "ping" ]) in
  check_status "exit" Host_worker.Carrier_lost run.status;
  let outcome =
    check_outcome ~requests:1 "lost while waiting" ~code:"E1611" ~terminal:"diagnostic" run
  in
  Alcotest.(check int) "request retained" 1 (List.length (requests outcome));
  Alcotest.(check int) "no observation" 0 (List.length (observations outcome))

let test_stderr_bound () =
  List.iter
    (fun ceiling ->
      let limits = { Host.hard_limits with max_stderr_bytes = ceiling } in
      let run = run (script [ select ~limits () ] ^ bytes_of_hex "0000") in
      check_status "exit" Host_worker.Carrier_lost run.status;
      Alcotest.(check bool)
        (Printf.sprintf "operator bytes within %d" ceiling)
        true
        (String.length run.operator <= ceiling))
    [ 1; 8; 40; 200 ]

let test_descriptors_and_channels () =
  let f = fixture () in
  let count_descriptors () =
    if Sys.file_exists "/proc/self/fd" then Some (Array.length (Sys.readdir "/proc/self/fd"))
    else None
  in
  let before = count_descriptors () in
  let base = fresh_path "channels" in
  let input_path = base ^ ".in" and output_path = base ^ ".out" and operator_path = base ^ ".err" in
  write_file input_path (script [ select (); double_invoke f 2 ]);
  let input = open_in_bin input_path in
  let output = open_out_bin output_path in
  let operator = open_out_bin operator_path in
  let status = Host_worker.serve f.prepared ~input ~output ~operator in
  check_status "exit" Host_worker.Terminal_written status;
  (* the worker closes none of the caller's channels *)
  output_string output "tail";
  output_string operator "tail";
  close_out output;
  close_out operator;
  close_in input;
  let after = count_descriptors () in
  Alcotest.(check (option int)) "no descriptor leak" before after;
  Alcotest.(check bool)
    "output channel still owned by the caller" true
    (Filename.check_suffix (read_file output_path) "tail");
  Alcotest.(check string)
    "operator channel still owned by the caller" "tail" (read_file operator_path);
  List.iter Sys.remove [ input_path; output_path; operator_path ]

(* The host closes its read end before Core writes: SIGPIPE must not kill the worker, and the
   failed frame must not be retried. *)
let test_output_pipe_closed_in_process () =
  let f = fixture () in
  let read_end, write_end = Unix.pipe ~cloexec:true () in
  Unix.close read_end;
  let base = fresh_path "epipe" in
  let input_path = base ^ ".in" and operator_path = base ^ ".err" in
  write_file input_path (script [ select (); double_invoke f 2 ]);
  let input = open_in_bin input_path in
  let output = Unix.out_channel_of_descr write_end in
  let operator = open_out_bin operator_path in
  (* keep SIGPIPE ignored around the whole exchange: closing the channel below retries the
     buffered write, and this test process must not die from the resulting EPIPE *)
  let previous = Sys.signal Sys.sigpipe Sys.Signal_ignore in
  let status = Host_worker.serve f.prepared ~input ~output ~operator in
  Alcotest.(check bool)
    "SIGPIPE disposition restored to the caller's setting" true
    (Sys.signal Sys.sigpipe Sys.Signal_ignore == Sys.Signal_ignore);
  close_in input;
  close_out_noerr output;
  close_out operator;
  Sys.set_signal Sys.sigpipe previous;
  check_status "exit" Host_worker.Carrier_lost status;
  let note = read_file operator_path in
  Alcotest.(check bool)
    "operator note names the lost hello" true
    (String.length note > 0
    && Str.string_match (Str.regexp ".*core_hello could not be written (E1611)") note 0);
  List.iter Sys.remove [ input_path; operator_path ]

(* Drive the installed binary with a dead standard output. Both cases must exit 74 with one
   operator note and without any exit-time retry or uncaught exception. *)
let worker_binary () =
  match Sys.getenv_opt "JACQUARD" with
  | Some binary -> binary
  | None ->
      let fallback = "../bin/main.exe" in
      if Sys.file_exists fallback then fallback
      else Alcotest.fail "set JACQUARD to the built jacquard binary"

let spawn_worker ~store_dir ~stdin_path ~stdout_fd =
  let binary = worker_binary () in
  let base = fresh_path "spawn" in
  let stderr_path = base ^ ".err" in
  let stdin_fd = Unix.openfile stdin_path [ Unix.O_RDONLY ] 0 in
  let stderr_fd = Unix.openfile stderr_path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ] 0o600 in
  let pid =
    Unix.create_process binary
      [| binary; "host"; "worker"; "--store"; store_dir |]
      stdin_fd stdout_fd stderr_fd
  in
  Unix.close stdin_fd;
  Unix.close stderr_fd;
  let _, status = Unix.waitpid [] pid in
  let stderr_text = read_file stderr_path in
  Sys.remove stderr_path;
  (status, stderr_text)

let check_spawned_loss label (status, stderr_text) =
  (match status with
  | Unix.WEXITED code -> Alcotest.(check int) (label ^ " exit status") 74 code
  | Unix.WSIGNALED signal -> Alcotest.failf "%s died from signal %d" label signal
  | Unix.WSTOPPED _ -> Alcotest.failf "%s stopped" label);
  Alcotest.(check bool)
    (label ^ " operator note present")
    true
    (Str.string_match (Str.regexp ".*could not be written (E1611)") stderr_text 0);
  Alcotest.(check bool)
    (label ^ " no uncaught exception")
    false
    (Str.string_match (Str.regexp ".*\\(Fatal error\\|internal error\\)") stderr_text 0)

let test_binary_output_lost () =
  let f = fixture () in
  let base = fresh_path "binary" in
  let stdin_path = base ^ ".in" in
  write_file stdin_path (script [ select (); double_invoke f 3 ]);
  (* a pipe whose reader is already gone: every write fails with EPIPE *)
  let read_end, write_end = Unix.pipe ~cloexec:true () in
  Unix.close read_end;
  let pipe_result = spawn_worker ~store_dir:f.store_dir ~stdin_path ~stdout_fd:write_end in
  Unix.close write_end;
  check_spawned_loss "closed pipe" pipe_result;
  (* a descriptor that cannot be written at all *)
  let unwritable = Unix.openfile Filename.null [ Unix.O_RDONLY ] 0 in
  let descriptor_result = spawn_worker ~store_dir:f.store_dir ~stdin_path ~stdout_fd:unwritable in
  Unix.close unwritable;
  check_spawned_loss "unwritable descriptor" descriptor_result;
  Sys.remove stdin_path

let test_prepare_requires_prelude () =
  let store = expect_ok "open empty store" (Store.open_store (fresh_path "empty")) in
  match Host_worker.prepare store with
  | Ok _ -> Alcotest.fail "an unpopulated store must not prepare"
  | Error (diagnostic :: _) ->
      Alcotest.(check string) "prelude diagnostic" "E0702" (Diag.code_or_uncoded diagnostic)
  | Error [] -> Alcotest.fail "prepare returned no diagnostic"

let prop_double_round_trip =
  QCheck.Test.make ~count:25 ~name:"prop_worker_doubles_every_bounded_int"
    QCheck.(int_range (-1_000_000) 1_000_000)
    (fun n ->
      let f = fixture () in
      let run = run (script [ select (); double_invoke f n ]) in
      run.status = Host_worker.Terminal_written
      &&
      match run.frames with
      | [ _; outcome ] ->
          Yojson.Safe.to_string (get "value" (get "result" outcome))
          = Yojson.Safe.to_string (int_value (2 * n))
      | _ -> false)

let suite =
  [
    Alcotest.test_case "exit codes are frozen" `Quick test_exit_codes;
    Alcotest.test_case "pure invocation succeeds on a reopened store" `Quick test_pure_success;
    Alcotest.test_case "one once operation round-trips through the host" `Quick test_effect_exchange;
    Alcotest.test_case "sequential requests use increasing ordinals" `Quick test_sequential_requests;
    Alcotest.test_case "host failures map to frozen terminals" `Quick test_host_failures;
    Alcotest.test_case "all nine cancellations map to frozen terminals" `Quick test_cancellations;
    Alcotest.test_case "selected shutdown is acknowledged" `Quick test_shutdown;
    Alcotest.test_case "preflight failures produce one fatal" `Quick test_preflight_fatals;
    Alcotest.test_case "unconfigured root operation finishes with E1606" `Quick
      test_unconfigured_operation;
    Alcotest.test_case "stale response id finishes with E1608" `Quick test_wrong_response_id;
    Alcotest.test_case "buffered message after outcome is ignored" `Quick test_message_after_outcome;
    Alcotest.test_case "runtime failure becomes a bounded diagnostic outcome" `Quick
      test_runtime_failure;
    Alcotest.test_case "malformed response frame finishes with E1608" `Quick
      test_malformed_response_frame;
    Alcotest.test_case "oversized response frame retains E1602" `Quick test_oversized_response_frame;
    Alcotest.test_case "raw framing defects produce one fatal" `Quick test_raw_framing;
    Alcotest.test_case "carrier loss before invocation reports E1611 and exit 74" `Quick
      test_carrier_loss_before_invocation;
    Alcotest.test_case "carrier loss while waiting keeps evidence and exits 74" `Quick
      test_carrier_loss_while_waiting;
    Alcotest.test_case "operator output honours the selected stderr ceiling" `Quick
      test_stderr_bound;
    Alcotest.test_case "worker leaks no descriptor and closes no caller channel" `Quick
      test_descriptors_and_channels;
    Alcotest.test_case "closed output pipe yields carrier loss without a signal" `Quick
      test_output_pipe_closed_in_process;
    Alcotest.test_case "installed binary exits 74 on a dead standard output" `Quick
      test_binary_output_lost;
    Alcotest.test_case "prepare fails closed without a prelude" `Quick test_prepare_requires_prelude;
    QCheck_alcotest.to_alcotest prop_double_round_trip;
  ]
