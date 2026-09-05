open Jacquard
module Host = Host_protocol_v0
module Session = Host.Session
module P = Test_host_invoke_preflight
open P

let get name json = Yojson.Safe.Util.member name json
let text json = Yojson.Safe.Util.to_string json
let items json = Yojson.Safe.Util.to_list json

let check_json label expected actual =
  Alcotest.(check string) label (Yojson.Safe.to_string expected) (Yojson.Safe.to_string actual)

let fixture () = Lazy.force P.fixture

let entry f =
  operation_json ~effect_identity:f.world_effect ~mode:"once" ~operation:f.send_operation

let start ?(limits = Host.hard_limits) () =
  let f = fixture () in
  expect_ok "start"
    (Session.start ~limits ~checker:f.checker (effectful_invoke ~operations:[ entry f ] f))

let request session =
  Session.request session ~operation:(fixture ()).send_operation
    ~arguments:[ Value.VInt 2; Value.VText "private argument" ]

let pending ?(limits = Host.hard_limits) () =
  let session = start ~limits () in
  (match expect_ok "request" (request session) with
  | Session.Request _ -> ()
  | _ -> Alcotest.fail "expected a request");
  session

let response ?(ordinal = 1) kind fields =
  `Assoc
    ([
       ("invocation_id", `String "0000000000000000");
       ("kind", `String kind);
       ("protocol", `String Host.protocol);
       ("request_id", `String (Printf.sprintf "%016x" ordinal));
     ]
    @ fields)

let success ?ordinal value = response ?ordinal "effect_ok" [ ("value", encode_value value) ]

let finished result =
  match expect_ok "terminal action" result with
  | Session.Finished json -> json
  | _ -> Alcotest.fail "expected one terminal"

let core json = get "core" (get "evidence" json)
let observations json = get "responses" (get "host_observations" (get "evidence" json)) |> items
let requests json = get "effect_requests" (core json) |> items
let diagnostics json = get "diagnostics" (get "result" json) |> items

let check_code code json =
  Alcotest.(check string)
    "terminal diagnostic" code
    (text (get "code" (List.hd (diagnostics json))))

let check_terminal expected json =
  Alcotest.(check string) "terminal classification" expected (text (get "terminal" (core json)))

let check_closed session =
  expect_code "finish after terminal" "E1608" (Session.finish session (Value.VText "later"));
  expect_code "request after terminal" "E1608" (request session);
  expect_code "response after terminal" "E1608"
    (Session.respond session (success (Value.VText "later")));
  expect_code "abort after terminal" "E1608" (Session.abort session [])

let test_pure () =
  let f = fixture () in
  let invoke = pure_invoke f in
  let session =
    expect_ok "pure start" (Session.start ~limits:Host.hard_limits ~checker:f.checker invoke)
  in
  let target, args = Session.call session in
  Alcotest.(check bool) "checked target" true (Hash.equal target f.pure_target);
  Alcotest.(check int) "arguments" 2 (List.length args);
  let json = finished (Session.finish session (Value.VText "private result")) in
  check_terminal "ok" json;
  List.iter
    (fun name -> check_json name (get name invoke) (get name (core json)))
    [ "target"; "interface"; "capabilities" ];
  check_json "result"
    (encode_value (Value.VText "private result"))
    (get "value" (get "result" json));
  check_json "no requests" (`List []) (get "effect_requests" (core json));
  Alcotest.(check int) "no observations" 0 (List.length (observations json));
  let core_fields = match core json with `Assoc fields -> List.map fst fields | _ -> [] in
  Alcotest.(check (list string))
    "exact evidence fields"
    [
      "capabilities";
      "effect_requests";
      "interface";
      "invocation_id";
      "schema";
      "target";
      "terminal";
    ]
    core_fields;
  check_closed session

let test_exchange () =
  let session = start () in
  for ordinal = 1 to 3 do
    let json =
      match expect_ok "request" (request session) with
      | Session.Request json -> json
      | _ -> Alcotest.fail "no request"
    in
    check_json "request id" (`String (Printf.sprintf "%016x" ordinal)) (get "request_id" json);
    check_json "request arguments"
      (`List [ encode_value (Value.VInt 2); encode_value (Value.VText "private argument") ])
      (get "arguments" json);
    check_json "operation" (hash_json (fixture ()).send_operation) (get "operation" json);
    match
      expect_ok "accepted response"
        (Session.respond session (success ~ordinal (Value.VText "private response")))
    with
    | Session.Resume (Value.VText value) ->
        Alcotest.(check string) "typed resume" "private response" value
    | _ -> Alcotest.fail "no typed resume"
  done;
  let json = finished (Session.finish session (Value.VText "done")) in
  Alcotest.(check int) "three requests" 3 (List.length (requests json));
  Alcotest.(check int) "three responses" 3 (List.length (observations json));
  List.iteri
    (fun i obs ->
      check_json "observation"
        (`Assoc
           [
             ("category", `String "ok");
             ("completion", `String "completed");
             ("ordinal", `Int (i + 1));
           ])
        obs)
    (observations json);
  check_closed session

let test_failure_mappings () =
  List.iter
    (fun (category, completion, code, terminal) ->
      let session = pending () in
      let message = "redacted é\nsecond line" in
      let json =
        finished
          (Session.respond session
             (response "effect_failure"
                [
                  ("category", `String category);
                  ("completion", `String completion);
                  ("message", `String message);
                ]))
      in
      check_code code json;
      check_terminal terminal json;
      let cause = text (get "cause" (List.hd (diagnostics json))) in
      Alcotest.(check bool) "exact host message suffix" true (Filename.check_suffix cause message);
      check_json "accepted observation"
        (`Assoc
           [
             ("category", `String category); ("completion", `String completion); ("ordinal", `Int 1);
           ])
        (List.hd (observations json));
      check_closed session)
    [
      ("unsupported_operation", "not_started", "E1606", "host_failure");
      ("refused_authority", "not_started", "E1607", "host_failure");
      ("outside_failure", "failed", "E1613", "host_failure");
      ("completion_unknown", "unknown", "E1612", "completion_unknown");
    ]

let test_cancellation_mappings () =
  List.iter
    (fun (reason, known_code) ->
      List.iter
        (fun completion ->
          let session = pending () in
          let json =
            finished
              (Session.respond session
                 (response "cancel"
                    [ ("reason", `String reason); ("completion", `String completion) ]))
          in
          check_code (if completion = "unknown" then "E1612" else known_code) json;
          check_terminal (if completion = "unknown" then "completion_unknown" else "cancelled") json;
          check_json "cancel observation"
            (`Assoc
               [
                 ("category", `String reason);
                 ("completion", `String completion);
                 ("ordinal", `Int 1);
               ])
            (List.hd (observations json));
          check_closed session)
        [ "not_started"; "failed"; "unknown" ])
    [ ("cancelled", "E1614"); ("timeout", "E1609"); ("host_shutdown", "E1610") ]

let test_rejected_responses () =
  let valid = success (Value.VText "ok") in
  let failure category completion =
    response "effect_failure"
      [
        ("category", `String category);
        ("completion", `String completion);
        ("message", `String "detail");
      ]
  in
  List.iter
    (fun json ->
      let session = pending () in
      let terminal = finished (Session.respond session json) in
      check_code "E1608" terminal;
      Alcotest.(check int) "rejected response not observed" 0 (List.length (observations terminal));
      Alcotest.(check int) "original request retained" 1 (List.length (requests terminal));
      check_closed session)
    [
      replace_field "protocol" (`String "future") valid;
      replace_field "request_id" (`String "0000000000000002") valid;
      replace_field "request_id" (`String "1") valid;
      replace_field "invocation_id" (`String "0000000000000001") valid;
      append_field "extra" `Null valid;
      append_field "kind" (`String "effect_ok") valid;
      replace_field "value" (`Assoc [ ("kind", `String "unknown") ]) valid;
      success (Value.VInt 1);
      success (Value.VTuple []);
      replace_field "value" (`Assoc [ ("kind", `String "text"); ("value", `String "\255") ]) valid;
      replace_field "kind" (`String "shutdown") valid;
      failure "outside_failure" "unknown";
      failure "refused_authority" "failed";
      response "cancel" [ ("reason", `String "bad"); ("completion", `String "unknown") ];
      response "cancel" [ ("reason", `String "timeout"); ("completion", `String "completed") ];
      `List [];
      `Assoc [];
    ]

let test_state_violations () =
  List.iter
    (fun act ->
      let session = pending () in
      let json = finished (act session) in
      check_code "E1608" json;
      Alcotest.(check int) "only one request" 1 (List.length (requests json));
      check_closed session)
    [ request; (fun session -> Session.finish session (Value.VText "early")) ];
  let session = start () in
  check_code "E1608" (finished (Session.respond session (success (Value.VText "unsolicited"))));
  let session = pending () in
  ignore (expect_ok "first response" (Session.respond session (success (Value.VText "first"))));
  check_code "E1608" (finished (Session.respond session (success (Value.VText "duplicate"))));
  let session = pending () in
  ignore (expect_ok "first response" (Session.respond session (success (Value.VText "first"))));
  ignore (expect_ok "next request" (request session));
  let json = finished (Session.respond session (success (Value.VText "stale"))) in
  check_code "E1608" json;
  Alcotest.(check int) "only prior response observed" 1 (List.length (observations json))

let test_outgoing_types () =
  let f = fixture () in
  let session =
    expect_ok "empty registry"
      (Session.start ~limits:Host.hard_limits ~checker:f.checker (effectful_invoke f))
  in
  let json = finished (request session) in
  check_code "E1606" json;
  Alcotest.(check int) "no request emitted" 0 (List.length (requests json));
  List.iter
    (fun arguments ->
      let session = start () in
      let json = finished (Session.request session ~operation:f.send_operation ~arguments) in
      check_code "E1603" json;
      Alcotest.(check int) "bad arguments not emitted" 0 (List.length (requests json)))
    [ []; [ Value.VText "wrong"; Value.VText "body" ] ];
  check_code "E1603" (finished (Session.finish (start ()) (Value.VInt 7)));
  let opaque =
    Value.VCode (expect_ok "quoted fixture" (Reader.parse_one ~file:"fixture" "(lit 7)"))
  in
  check_code "E1604" (finished (Session.finish (start ()) opaque));
  check_code "E1604"
    (finished
       (Session.request (start ()) ~operation:f.send_operation ~arguments:[ Value.VInt 2; opaque ]))

let test_request_limit () =
  let limits = { Host.hard_limits with max_effect_requests = 1 } in
  let session = pending ~limits () in
  ignore (expect_ok "first response" (Session.respond session (success (Value.VText "first"))));
  let json = finished (request session) in
  check_code "E1602" json;
  Alcotest.(check int) "limit stops second request" 1 (List.length (requests json));
  Alcotest.(check int) "accepted observation retained" 1 (List.length (observations json))

let test_response_limits () =
  List.iter
    (fun (limits, message) ->
      let session = pending ~limits () in
      let json = finished (Session.respond session message) in
      check_code "E1602" json;
      Alcotest.(check int) "over-limit response not observed" 0 (List.length (observations json)))
    [
      ({ Host.hard_limits with max_text_bytes = 16 }, success (Value.VText (String.make 17 'x')));
      ( { Host.hard_limits with max_host_message_bytes = 3 },
        response "effect_failure"
          [
            ("category", `String "outside_failure");
            ("completion", `String "failed");
            ("message", `String "éé");
          ] );
    ]

let test_terminal_reservation () =
  let limits = { Host.hard_limits with max_frame_bytes = 1000 } in
  let f = fixture () in
  ignore
    (expect_ok "selection fits fatal"
       (Host.parse_host_select
          (`Assoc
             [
               ("kind", `String "host_select");
               ("protocol", `String Host.protocol);
               ("limits", Host.limits_to_yojson limits);
             ])));
  expect_code "evidence cannot fit" "E1602"
    (Session.start ~limits ~checker:f.checker (effectful_invoke ~operations:[ entry f ] f));
  (* A growing transcript is stopped before its next request, retaining the
     previous successful observations and enough room for the refusal. *)
  let limits = { Host.hard_limits with max_frame_bytes = 3000 } in
  let session = start ~limits () in
  let rec loop ordinal =
    if ordinal > 20 then Alcotest.fail "evidence limit never reached";
    match expect_ok "bounded request" (request session) with
    | Session.Request _ ->
        ignore
          (expect_ok "response" (Session.respond session (success ~ordinal (Value.VText "ok"))));
        loop (ordinal + 1)
    | Session.Finished json ->
        check_code "E1602" json;
        Alcotest.(check int) "refused ordinal absent" (ordinal - 1) (List.length (requests json));
        Alcotest.(check int) "observations retained" (ordinal - 1) (List.length (observations json));
        ignore (expect_ok "terminal fits" (Host.encode_frame_bytes ~limits json))
    | _ -> Alcotest.fail "request returned Resume"
  in
  loop 1

let test_diagnostic_budget () =
  let limits = { Host.hard_limits with max_diagnostic_bytes = 500 } in
  let session = pending ~limits () in
  let json =
    finished
      (Session.respond session
         (response "effect_failure"
            [
              ("category", `String "completion_unknown");
              ("completion", `String "unknown");
              ("message", `String (String.make 600 'x'));
            ]))
  in
  check_code "E1602" json;
  check_terminal "completion_unknown" json;
  Alcotest.(check int) "accepted ambiguity retained" 1 (List.length (observations json));
  let diagnostic =
    Diag.error ~domain:Runtime ~code:"E0001" ~summary:"Runtime failure." ~cause:"detail"
      ~next_step:"Inspect the computation." ~contrast:None ()
  in
  let json = finished (Session.abort (start ()) [ diagnostic ]) in
  check_json "diagnostic preserved" (Diag.to_yojson diagnostic) (List.hd (diagnostics json));
  let json = finished (Session.abort (start ()) []) in
  check_code "E1602" json;
  let fatal = expect_ok "bounded fatal" (Session.fatal ~limits []) in
  Alcotest.(check string) "fatal kind" "fatal" (text (get "kind" fatal));
  Alcotest.(check string)
    "fatal fallback" "E1602"
    (text (get "code" (List.hd (items (get "diagnostics" fatal)))));
  expect_code "cannot fit even fatal" "E1602"
    (Session.fatal ~limits:{ limits with max_frame_bytes = 1 } [ diagnostic ])

let test_shared_node_budget () =
  let f = fixture () in
  let stored =
    put_src f.store
      "(defterm ((binding boundary.session-pure ((tarrow () (row) (tref text))) (lam () (lit \
       \"ok\")))))"
  in
  let invoke =
    invoke_json
      ~target:(named "boundary.session-pure" stored)
      ~parameters:[] ~effects:[] ~result:(text_type f) ~arguments:[] ~operations:[]
  in
  let start nodes =
    expect_ok "minimal invocation"
      (Session.start
         ~limits:{ Host.hard_limits with max_value_nodes = nodes }
         ~checker:f.checker invoke)
  in
  (* One interface descriptor fits preflight/failure; a success needs its own
     value node in addition to the repeated interface descriptor. *)
  check_code "E1602" (finished (Session.finish (start 1) (Value.VText "ok")));
  check_terminal "ok" (finished (Session.finish (start 2) (Value.VText "ok")))

let test_nominal_fields () =
  let f = fixture () in
  let effect_hashes =
    put_src f.store
      "(defeffect boundary.session-packet () (op boundary.exchange once ((tapp (tref \
       boundary-packet) (tref int))) (tapp (tref boundary-packet) (tref int))))"
  in
  let target =
    put_src f.store
      "(defterm ((binding boundary.packet-call ((tarrow ((tapp (tref boundary-packet) (tref int))) \
       (row (eref boundary.session-packet)) (tapp (tref boundary-packet) (tref int)))) (lam ((pvar \
       value)) (app (var boundary.exchange) (var value))))))"
  in
  let effect_identity = named "boundary.session-packet" effect_hashes in
  let operation = named "boundary.exchange" effect_hashes in
  let packet value =
    Value.VCon
      { con = f.packet_constructor; name = "ignored"; args = [ value; Value.VText "body" ] }
  in
  let valid = packet (Value.VInt 4) in
  let invoke =
    invoke_json
      ~target:(named "boundary.packet-call" target)
      ~parameters:[ packet_int f ]
      ~effects:[ effect_identity ] ~result:(packet_int f) ~arguments:[ valid ]
      ~operations:[ operation_json ~effect_identity ~operation ~mode:"once" ]
  in
  let start () =
    expect_ok "nominal session" (Session.start ~limits:Host.hard_limits ~checker:f.checker invoke)
  in
  let pending () =
    let session = start () in
    ignore (expect_ok "nominal request" (Session.request session ~operation ~arguments:[ valid ]));
    session
  in
  let session = pending () in
  (match expect_ok "nominal response" (Session.respond session (success valid)) with
  | Session.Resume value -> check_json "lossless nominal" (encode_value valid) (encode_value value)
  | _ -> Alcotest.fail "missing nominal resume");
  check_terminal "ok" (finished (Session.finish session valid));
  check_code "E1608"
    (finished (Session.respond (pending ()) (success (packet (Value.VText "wrong field")))));
  check_code "E1603"
    (finished
       (Session.request (start ()) ~operation ~arguments:[ packet (Value.VText "wrong field") ]));
  check_code "E1603" (finished (Session.finish (start ()) (packet (Value.VText "wrong field"))))

let rec string_bytes = function
  | `String s -> String.length s
  | `Assoc fields -> List.fold_left (fun n (_, v) -> n + string_bytes v) 0 fields
  | `List values -> List.fold_left (fun n v -> n + string_bytes v) 0 values
  | _ -> 0

let test_exact_diagnostic_bytes () =
  let cause = String.concat "" (List.init 300 (fun _ -> "é")) in
  let contrast =
    Diag.contrast ~mistaken:"Supposed a result was available." ~intended:"The computation failed."
  in
  let diagnostic =
    Diag.error ~domain:Runtime ~code:"E0001" ~summary:"Runtime failure." ~cause
      ~next_step:"Inspect the computation." ~contrast:(Some contrast) ()
  in
  let bytes = string_bytes (Diag.to_yojson diagnostic) in
  let limits = { Host.hard_limits with max_diagnostic_bytes = bytes } in
  let exact = finished (Session.abort (start ~limits ()) [ diagnostic ]) in
  check_json "all UTF-8 diagnostic strings fit exactly" (Diag.to_yojson diagnostic)
    (List.hd (diagnostics exact));
  let smaller = { limits with max_diagnostic_bytes = bytes - 1 } in
  check_code "E1602" (finished (Session.abort (start ~limits:smaller ()) [ diagnostic ]));
  let count = { Host.hard_limits with max_diagnostics = 1 } in
  check_code "E1602" (finished (Session.abort (start ~limits:count ()) [ diagnostic; diagnostic ]))

let test_preflight_terminal_capacity () =
  let f = fixture () in
  let invoke = effectful_invoke ~operations:[ entry f ] f in
  let minimal = finished (Session.abort (start ()) []) in
  (* Reservation uses the longest terminal label (18 bytes), eight bytes
     longer than this diagnostic terminal. Fail on precisely its final byte. *)
  let bytes = String.length (Yojson.Safe.to_string minimal) + 8 in
  let limits = { Host.hard_limits with max_frame_bytes = bytes - 1 } in
  ignore (expect_ok "invoke itself fits" (Host.encode_frame_bytes ~limits invoke));
  ignore (expect_ok "checked invoke fits" (Host.parse_invoke ~limits ~checker:f.checker invoke));
  expect_code "terminal cannot fit" "E1602" (Session.start ~limits ~checker:f.checker invoke);
  ignore
    (expect_ok "terminal exact capacity"
       (Session.start ~limits:{ limits with max_frame_bytes = bytes } ~checker:f.checker invoke))

let suite =
  List.map
    (fun (label, test) -> Alcotest.test_case label `Quick test)
    [
      ("pure result and exact evidence", test_pure);
      ("nominal fields in both directions", test_nominal_fields);
      ("exact UTF-8 diagnostic accounting", test_exact_diagnostic_bytes);
      ("invoke fits but terminal does not", test_preflight_terminal_capacity);
      ("serial typed exchange", test_exchange);
      ("four host failure mappings", test_failure_mappings);
      ("nine cancellation mappings", test_cancellation_mappings);
      ("rejected responses have no observation", test_rejected_responses);
      ("state violations and stale replies", test_state_violations);
      ("outgoing type and registry checks", test_outgoing_types);
      ("cumulative request limit", test_request_limit);
      ("decoded response byte limits", test_response_limits);
      ("reserve growing terminal evidence", test_terminal_reservation);
      ("bounded diagnostics preserve ambiguity", test_diagnostic_budget);
      ("result shares evidence node budget", test_shared_node_budget);
    ]
