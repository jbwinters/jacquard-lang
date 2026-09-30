(* OBS.1: versioned observation policies and policy-bound observation transcripts. *)

open Jacquard

let prelude_dir = "../prelude"
let fail_diagnostics diagnostics = String.concat "\n" (List.map Diag.to_string diagnostics)

let expect_ok label = function
  | Ok value -> value
  | Error diagnostics -> Alcotest.failf "%s failed:\n%s" label (fail_diagnostics diagnostics)

let expect_code label code = function
  | Ok _ -> Alcotest.failf "%s: expected %s" label code
  | Error diagnostics ->
      Alcotest.(check (list string))
        label [ code ]
        (List.sort_uniq String.compare (List.map Diag.code_or_uncoded diagnostics))

let rec remove_tree path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
      Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path
  | _ -> Unix.unlink path

let fresh_root =
  let serial = ref 0 in
  fun label ->
    incr serial;
    let root =
      Filename.concat (Filename.get_temp_dir_name ())
        (Printf.sprintf "jacquard-obs1-%s-%d-%d" label (Unix.getpid ()) !serial)
    in
    at_exit (fun () -> try remove_tree root with Unix.Unix_error _ | Sys_error _ -> ());
    root

let program =
  "once effect Probe where { probe.send : (Text, Text) -> Int }\nspin(n) = spin(add(n, 1))\n"

let prepared label =
  let store, ctx =
    expect_ok "open session" (Frontend.open_session ~prelude_dir ~root:(fresh_root label))
  in
  expect_ok "declarations" (Frontend.walk ~syntax:Frontend.Auto ~file:"program.jac" store program);
  (store, ctx)

let expression store source =
  let tops, _ =
    expect_ok "parse"
      (Frontend.parse_tops ~syntax:Frontend.Auto ~names:(Store.names_view store) ~file:"e.jac"
         source)
  in
  match List.map (fun top -> expect_ok "validate" (Frontend.validate_parsed_top top)) tops with
  | [ Kernel.Expr expr ] -> (
      match expect_ok "resolve" (Resolve.resolve (Store.names_view store) (Kernel.Expr expr)) with
      | Kernel.Expr resolved -> resolved
      | Kernel.Decl _ -> Alcotest.fail "expected an expression")
  | _ -> Alcotest.fail "expected one expression"

(* the identity of probe.send, learned by observing one ungranted call *)
let probe_send store ctx =
  let recorder = Observation_transcript.create Observation_policy.default in
  ignore
    (Eval.with_invocation ctx (fun _ ->
         Observation_transcript.record recorder ctx (fun () ->
             Eval.run_expr ctx (expression store "probe.send(\"a\", \"b\")"))));
  match Observation_transcript.runs (Observation_transcript.transcript recorder) with
  | [ { events = [ event ]; _ } ] -> event.operation
  | _ -> Alcotest.fail "probe.send was not observed"

(* record [sources] under [policy], each in its own invocation with probe.send granted *)
let record ?fuel ?(handler = fun _ -> Ok (Value.VInt 7)) store ctx policy sources =
  let recorder = Observation_transcript.create policy in
  let send = probe_send store ctx in
  List.iter
    (fun source ->
      ignore
        (Eval.with_invocation ?fuel ctx (fun _ ->
             Eval.register_root_handler ctx send handler;
             Observation_transcript.record recorder ctx (fun () ->
                 Eval.run_expr ctx (expression store source)))))
    sources;
  Observation_transcript.transcript recorder

let rule ?(arguments = Observation_policy.All_arguments) ?(result = Observation_policy.Compare)
    ?(output = Observation_policy.Ignore) () =
  { Observation_policy.arguments; result; output }

let policy ?(result = Observation_policy.Compare) ?(field_bytes = 4096) ?unlisted ?interface
    operations =
  expect_ok "policy" (Observation_policy.make ~result ~field_bytes ~unlisted ~interface operations)

let verdict label = function
  | Ok Observation_transcript.Equal -> "equal"
  | Ok (Observation_transcript.Divergent difference) ->
      "divergent " ^ Observation_transcript.position_path difference.position
  | Ok (Observation_transcript.Inconclusive difference) ->
      "inconclusive " ^ Observation_transcript.position_path difference.position
  | Error diagnostics -> Alcotest.failf "%s: %s" label (fail_diagnostics diagnostics)

let compare left right = verdict "compare" (Observation_transcript.compare left right)

let test_policy_encoding () =
  let operation = Hash.of_string "some operation" and other = Hash.of_string "another operation" in
  let selected =
    policy
      ~unlisted:
        (rule ~arguments:Observation_policy.No_arguments ~result:Observation_policy.Ignore ())
      [
        (other, rule ~arguments:(Observation_policy.Selected_arguments [ 0; 2 ]) ());
        (operation, rule ~output:Observation_policy.Compare ());
      ]
  in
  let bytes = Observation_policy.serialize selected in
  let reparsed = expect_ok "round trip" (Observation_policy.parse bytes) in
  Alcotest.(check string) "canonical" bytes (Observation_policy.serialize reparsed);
  Alcotest.(check bool)
    "identity is the canonical bytes'" true
    (Hash.equal (Observation_policy.identity selected) (Observation_policy.identity reparsed));
  Alcotest.(check bool)
    "different selections differ" false
    (Hash.equal
       (Observation_policy.identity selected)
       (Observation_policy.identity Observation_policy.default));
  let default_bytes = Observation_policy.serialize Observation_policy.default in
  Alcotest.(check string)
    "the default policy"
    "jacquard-observation-policy format=1\n\
     result=compare field-bytes=4096 interface=none\n\
     unlisted=record arguments=all result=ignore output=compare\n\
     operations=0\n"
    default_bytes;
  let refuse label bytes = expect_code label "E1005" (Observation_policy.parse bytes) in
  refuse "unknown version"
    (Str.global_replace (Str.regexp_string "format=1") "format=2" default_bytes);
  refuse "trailing bytes" (default_bytes ^ "\n");
  refuse "unknown clause" (default_bytes ^ "redact=all\n");
  refuse "descending positions"
    (Str.global_replace (Str.regexp_string "arguments=0,2") "arguments=2,0" bytes);
  (* swapping the two operation lines leaves them unsorted *)
  let lines = String.split_on_char '\n' bytes in
  let swapped =
    match lines with
    | [ a; b; c; d; first; second; "" ] -> String.concat "\n" [ a; b; c; d; second; first; "" ]
    | _ -> Alcotest.fail "unexpected policy shape"
  in
  refuse "unsorted operations" swapped;
  expect_code "a repeated operation" "E1005"
    (Observation_policy.make ~result:Observation_policy.Compare ~field_bytes:10 ~unlisted:None
       ~interface:None
       [ (operation, rule ()); (operation, rule ()) ]);
  expect_code "a zero limit" "E1005"
    (Observation_policy.make ~result:Observation_policy.Compare ~field_bytes:0 ~unlisted:None
       ~interface:None [])

let test_selected_arguments () =
  let store, ctx = prepared "select" in
  let send = probe_send store ctx in
  let run policy source = record store ctx policy [ source ] in
  let second =
    policy [ (send, rule ~arguments:(Observation_policy.Selected_arguments [ 1 ]) ()) ]
  in
  let first = policy [ (send, rule ~arguments:(Observation_policy.Selected_arguments [ 0 ]) ()) ] in
  let left = "probe.send(\"a\", \"one\")" and right = "probe.send(\"a\", \"two\")" in
  Alcotest.(check string)
    "a selected argument distinguishes the calls" "divergent run[0].event[0].argument[1]"
    (compare (run second left) (run second right));
  Alcotest.(check string)
    "an ignored argument agrees" "equal"
    (compare (run first left) (run first right));
  (* results: the same arguments, different handler results *)
  let results = policy [ (send, rule ~arguments:Observation_policy.No_arguments ()) ] in
  let returning value =
    record
      ~handler:(fun _ -> Ok (Value.VInt value))
      store ctx results
      [ "{ probe.send(\"a\", \"b\"); 0 }" ]
  in
  Alcotest.(check string)
    "a compared result distinguishes handlers" "divergent run[0].event[0].result"
    (compare (returning 1) (returning 2));
  let unlisted_only =
    policy
      ~unlisted:
        (rule ~arguments:Observation_policy.No_arguments ~result:Observation_policy.Ignore ())
      []
  in
  Alcotest.(check string)
    "identity-only observation agrees" "equal"
    (compare (run unlisted_only left) (run unlisted_only right));
  let not_recorded = policy [] in
  Alcotest.(check int)
    "an unlisted operation is not recorded" 0
    (List.length
       (List.hd (Observation_transcript.runs (run not_recorded left))).Observation_transcript.events)

let test_drift_is_refused () =
  let store, ctx = prepared "drift" in
  let send = probe_send store ctx in
  let one = policy [ (send, rule ()) ]
  and two = policy [ (send, rule ~arguments:Observation_policy.No_arguments ()) ] in
  let recorded = record store ctx one [ "probe.send(\"a\", \"b\")" ] in
  let bytes = Observation_transcript.serialize recorded in
  ignore (expect_ok "same policy" (Observation_transcript.parse ~policy:one bytes));
  expect_code "another policy's transcript" "E1006" (Observation_transcript.parse ~policy:two bytes);
  expect_code "comparing across policies" "E1006"
    (Observation_transcript.compare recorded (record store ctx two [ "probe.send(\"a\", \"b\")" ]));
  let is_operation operation = Hash.equal operation send in
  ignore (expect_ok "known operation" (Observation_policy.validate_operations one ~is_operation));
  expect_code "a stale operation identity" "E1005"
    (Observation_policy.validate_operations
       (policy [ (Hash.of_string "renamed away", rule ()) ])
       ~is_operation);
  let interface = Hash.of_string "interface-v1 of the program" in
  let pinned = policy ~interface [] in
  ignore
    (expect_ok "same interface" (Observation_policy.check_interface pinned ~identity:interface));
  expect_code "a stale interface" "E1005"
    (Observation_policy.check_interface pinned ~identity:(Hash.of_string "a later interface"));
  let refuse label bytes =
    expect_code label "E1006" (Observation_transcript.parse ~policy:one bytes)
  in
  refuse "trailing bytes" (bytes ^ "x");
  refuse "a truncated payload" (String.sub bytes 0 (String.length bytes - 3));
  refuse "an unknown version" (Str.global_replace (Str.regexp_string "format=1") "format=9" bytes)

let contains haystack needle =
  match Str.search_forward (Str.regexp_string needle) haystack 0 with
  | _ -> true
  | exception Not_found -> false

let test_redaction () =
  let store, ctx = prepared "redact" in
  let send = probe_send store ctx in
  let sensitive = "hunter2-SENSITIVE" in
  (* the second argument is excluded; the first differs so there is a divergence to render *)
  let excluded =
    policy [ (send, rule ~arguments:(Observation_policy.Selected_arguments [ 0 ]) ()) ]
  in
  let left = record store ctx excluded [ Printf.sprintf "probe.send(\"a\", %S)" sensitive ] in
  let right = record store ctx excluded [ Printf.sprintf "probe.send(\"z\", %S)" sensitive ] in
  let rendered =
    match Observation_transcript.compare left right with
    | Ok (Observation_transcript.Divergent difference) -> Observation_transcript.render difference
    | _ -> Alcotest.fail "expected a divergence"
  in
  List.iter
    (fun (label, text) ->
      Alcotest.(check bool) (label ^ " omits the excluded value") false (contains text sensitive))
    [
      ("the transcript", Observation_transcript.serialize left);
      ("the policy", Observation_policy.serialize excluded);
      ("the divergence", rendered);
    ];
  (* a secret result is unsupported, never rendered and never hashed *)
  let secret = Value.VSecret (Secret.of_string sensitive) in
  let with_secret =
    record
      ~handler:(fun _ -> Ok secret)
      store ctx
      (policy [ (send, rule ()) ])
      [ "{ probe.send(\"a\", \"b\"); 0 }" ]
  in
  let bytes = Observation_transcript.serialize with_secret in
  Alcotest.(check bool) "no secret bytes" false (contains bytes sensitive);
  Alcotest.(check bool) "recorded as unsupported" true (contains bytes "unsupported kind=secret");
  Alcotest.(check string)
    "two secret results cannot be called equal" "inconclusive run[0].event[0].result"
    (compare with_secret with_secret)

let test_failures_and_truncation () =
  let store, ctx = prepared "failure" in
  let send = probe_send store ctx in
  let observed = policy [ (send, rule ()) ] in
  let failing =
    record
      ~handler:(fun _ -> Error (Runtime_err.Eval_error "refused"))
      store ctx observed [ "probe.send(\"a\", \"b\")" ]
  in
  let spinning =
    record ~fuel:1_000 store ctx observed [ "{ probe.send(\"a\", \"b\"); spin(0) }" ]
  in
  let status transcript =
    match Observation_transcript.runs transcript with
    | [ { status = Observation_transcript.Failed code; events } ] ->
        Printf.sprintf "failed %s/%d" code (List.length events)
    | [ { status = Observation_transcript.Incomplete code; events } ] ->
        Printf.sprintf "incomplete %s/%d" code (List.length events)
    | [ { status = Observation_transcript.Complete _; _ } ] -> "complete"
    | _ -> "other"
  in
  Alcotest.(check bool)
    "a failed run keeps its events" true
    (String.length (status failing) > 7 && String.sub (status failing) 0 7 = "failed ");
  Alcotest.(check string) "a fuel-stopped run is incomplete" "incomplete E0919/1" (status spinning);
  Alcotest.(check string)
    "failure and exhaustion differ" "divergent run[0].status" (compare failing spinning);
  List.iter
    (fun transcript ->
      let bytes = Observation_transcript.serialize transcript in
      let reparsed = expect_ok "round trip" (Observation_transcript.parse ~policy:observed bytes) in
      Alcotest.(check string) "canonical" bytes (Observation_transcript.serialize reparsed))
    [ failing; spinning ];
  (* truncation: equal prefixes are inconclusive, different lengths diverge *)
  let small = policy ~field_bytes:4 [ (send, rule ~result:Observation_policy.Ignore ()) ] in
  let long suffix =
    record store ctx small [ Printf.sprintf "probe.send(\"abcdefgh%s\", \"b\")" suffix ]
  in
  Alcotest.(check string)
    "same prefix and length" "inconclusive run[0].event[0].argument[0]"
    (compare (long "x") (long "y"));
  Alcotest.(check string)
    "different lengths" "divergent run[0].event[0].argument[0]"
    (compare (long "x") (long "xy"))

let test_v1_unchanged () =
  let store, ctx = prepared "v1" in
  let recorder = Run_transcript.create () in
  let sink = Buffer.create 16 in
  ignore
    (Eval.with_invocation ctx (fun _ ->
         expect_ok "grant console"
           (Prelude.grant ctx "console" ~infer_cache:None ~out:(Buffer.add_string sink) ~seed:0);
         Run_transcript.record_expression recorder ctx (fun () ->
             Eval.run_expr ctx (expression store "{ print(\"hi\"); 1 }"))));
  Alcotest.(check string)
    "run-transcript-v1 bytes"
    "jacquard-run-transcript format=1 observations=1\n\
     observation index=0 value-bytes=2 trace-events=1\n\
     1\n\
     trace index=0 operation=28570e6bcdeb8646a90b31971204be7007f658bee65154b96e587c47a6585d5e \
     output-bytes=2\n\
     hi"
    (Run_transcript.serialize_recorder recorder);
  (* the same run twice records identical bytes *)
  let twice () =
    Observation_transcript.serialize
      (record store ctx Observation_policy.default [ "probe.send(\"a\", \"b\")"; "add(1, 2)" ])
  in
  Alcotest.(check string) "deterministic" (twice ()) (twice ())

let test_constructor_identity () =
  let field identity =
    Observation_transcript.field_of_value Observation_policy.default
      (Observation.Constructor
         { identity = Hash.of_string identity; name = "Ready"; arguments = [] })
  in
  Alcotest.(check bool) "same constructor" true (field "a" = field "a");
  Alcotest.(check bool) "same name, other constructor" false (field "a" = field "b")

let run_events transcript =
  match Observation_transcript.runs transcript with
  | [ run ] -> run.Observation_transcript.events
  | _ -> Alcotest.fail "expected one run"

let console_transcript store ctx policy source =
  let recorder = Observation_transcript.create policy in
  let sink = Buffer.create 16 in
  ignore
    (Eval.with_invocation ctx (fun _ ->
         expect_ok "grant console"
           (Prelude.grant ctx "console" ~infer_cache:None ~out:(Buffer.add_string sink) ~seed:0);
         Observation_transcript.record recorder ctx (fun () ->
             Eval.run_expr ctx (expression store source))));
  Observation_transcript.transcript recorder

let test_pairing () =
  let store, ctx = prepared "pairing" in
  let send = probe_send store ctx in
  (* the outer call's handler captures an inner call to the same operation and handles it itself:
     the outer result must stay with the outer call *)
  let nested =
    record
      ~handler:(fun _ ->
        (match
           Eval.run_state_capturing_once_routed ctx
             (Eval.expr_state (expression store "probe.send(\"inner\", \"x\")"))
         with
        | Ok (Eval.OCOp _) -> ()
        | Ok (Eval.OCValue _) | Error _ -> Alcotest.fail "the inner call was not captured");
        Ok (Value.VInt 1))
      store ctx
      (policy [ (send, rule ()) ])
      [ "probe.send(\"outer\", \"y\")" ]
  in
  Alcotest.(check (list (option string)))
    "each result stays with its call" [ Some "1"; Some "<missing>" ]
    (List.map
       (fun (event : Observation_transcript.event) ->
         Option.map
           (function
             | Observation_transcript.Data bytes -> bytes
             | Observation_transcript.Missing -> "<missing>"
             | _ -> "other")
           event.result)
       (run_events nested));
  (* Console output pairs with its print call, and is excluded when the policy ignores it *)
  let outputs policy source =
    List.map
      (fun (event : Observation_transcript.event) -> event.output)
      (run_events (console_transcript store ctx policy source))
  in
  Alcotest.(check bool)
    "compared output" true
    (outputs Observation_policy.default "print(\"hi\")"
    = [ Some (Observation_transcript.Data "hi") ]);
  let quiet =
    policy
      ~unlisted:
        (rule ~arguments:Observation_policy.No_arguments ~result:Observation_policy.Ignore ())
      []
  in
  Alcotest.(check bool) "ignored output" true (outputs quiet "print(\"hi\")" = [ None ]);
  Alcotest.(check string)
    "differing output diverges" "divergent run[0].event[0].output"
    (compare
       (console_transcript store ctx
          (policy
             ~unlisted:
               (rule ~arguments:Observation_policy.No_arguments ~result:Observation_policy.Ignore
                  ~output:Observation_policy.Compare ())
             [])
          "print(\"hi\")")
       (console_transcript store ctx
          (policy
             ~unlisted:
               (rule ~arguments:Observation_policy.No_arguments ~result:Observation_policy.Ignore
                  ~output:Observation_policy.Compare ())
             [])
          "print(\"ho\")"));
  Alcotest.(check string)
    "ignored output agrees" "equal"
    (compare
       (console_transcript store ctx quiet "print(\"hi\")")
       (console_transcript store ctx quiet "print(\"ho\")"))

let test_fuel_keeps_observations () =
  let store, ctx = prepared "fuel" in
  let send = probe_send store ctx in
  (* the final result walk runs out: the run is incomplete, not lost *)
  let recorder = Observation_transcript.create Observation_policy.default in
  let pair = expression store "(1, 2)" in
  let outcome =
    Eval.with_invocation ~fuel:1_000_000 ctx (fun _ ->
        Observation_transcript.record recorder ctx (fun () ->
            let result = Eval.run_expr ctx pair in
            Fuel_meter.trip ();
            result))
  in
  Alcotest.(check bool) "the result is returned unchanged" true (Result.is_ok outcome);
  (match Observation_transcript.runs (Observation_transcript.transcript recorder) with
  | [ { status = Observation_transcript.Incomplete "E0919"; _ } ] -> ()
  | _ -> Alcotest.fail "the exhausted result walk was not recorded as incomplete");
  (* projecting a large argument runs out: the operation is kept, its arguments unfinished *)
  let big = String.make 60_000 'a' in
  let projected =
    record ~fuel:300 store ctx Observation_policy.default
      [ Printf.sprintf "probe.send(%S, \"b\")" big ]
  in
  (match Observation_transcript.runs projected with
  | [ { status = Observation_transcript.Incomplete "E0919"; events = [ event ] } ] ->
      Alcotest.(check bool) "the operation is kept" true (Hash.equal event.operation send);
      Alcotest.(check bool)
        "its arguments are unfinished" true
        (event.arguments = [ (0, Observation_transcript.Unfinished) ])
  | _ -> Alcotest.fail "the operation observed before exhaustion was lost");
  let bytes = Observation_transcript.serialize projected in
  ignore
    (expect_ok "unfinished round trip"
       (Observation_transcript.parse ~policy:Observation_policy.default bytes));
  Alcotest.(check string)
    "unfinished arguments cannot be called equal" "inconclusive run[0].event[0].argument[0]"
    (compare projected projected)

let replace_once text needle replacement =
  let index = Str.search_forward (Str.regexp_string needle) text 0 in
  String.sub text 0 index ^ replacement
  ^ String.sub text
      (index + String.length needle)
      (String.length text - index - String.length needle)

let test_impossible_transcripts () =
  let store, ctx = prepared "impossible" in
  let send = probe_send store ctx in
  let observed = policy [ (send, rule ()) ] in
  let spinning =
    Observation_transcript.serialize
      (record ~fuel:1_000 store ctx observed [ "{ probe.send(\"a\", \"b\"); spin(0) }" ])
  in
  let refuse label policy bytes =
    expect_code label "E1006" (Observation_transcript.parse ~policy bytes)
  in
  refuse "incomplete for another reason" observed
    (replace_once spinning "status=incomplete code=E0919" "status=incomplete code=E0601");
  refuse "failed by fuel" observed
    (replace_once spinning "status=incomplete code=E0919" "status=failed code=E0919");
  let all =
    Observation_transcript.serialize
      (record store ctx Observation_policy.default [ "probe.send(\"a\", \"b\")" ])
  in
  refuse "a missing argument under all-arguments" Observation_policy.default
    (replace_once all "argument index=1 data bytes=3\n\"b\"\n" "argument index=1 missing\n");
  let printed =
    Observation_transcript.serialize
      (console_transcript store ctx Observation_policy.default "print(\"hi\")")
  in
  refuse "unsupported raw output" Observation_policy.default
    (replace_once printed "output data bytes=2\nhi\n" "output unsupported kind=secret\n");
  (* a selected position the call does not have is missing *)
  let beyond =
    record store ctx
      (policy [ (send, rule ~arguments:(Observation_policy.Selected_arguments [ 0; 5 ]) ()) ])
      [ "probe.send(\"a\", \"b\")" ]
  in
  Alcotest.(check bool)
    "position 5 is missing" true
    (match run_events beyond with
    | [ { arguments = [ _; (5, Observation_transcript.Missing) ]; _ } ] -> true
    | _ -> false);
  (* diagnostics about a transcript never quote it *)
  let sensitive = "hunter2-SENSITIVE" in
  let quoted =
    Observation_transcript.serialize
      (record store ctx observed [ Printf.sprintf "probe.send(%S, \"b\")" sensitive ])
  in
  (match Observation_transcript.parse ~policy:observed (quoted ^ "x") with
  | Ok _ -> Alcotest.fail "a corrupted transcript parsed"
  | Error diagnostics ->
      Alcotest.(check bool)
        "the diagnostic omits the payload" false
        (contains (fail_diagnostics diagnostics) sensitive));
  (* two failures without a diagnostic code cannot be called equal *)
  let failing message =
    record
      ~handler:(fun _ -> Error (Runtime_err.Eval_error message))
      store ctx observed [ "probe.send(\"a\", \"b\")" ]
  in
  Alcotest.(check string)
    "uncoded failures are inconclusive" "inconclusive run[0].status"
    (compare (failing "one") (failing "two"))

exception Handler_boom

let results transcript =
  List.map
    (fun (event : Observation_transcript.event) ->
      match event.result with
      | Some (Observation_transcript.Data bytes) -> bytes
      | Some Observation_transcript.Missing -> "<missing>"
      | Some _ -> "other"
      | None -> "<none>")
    (run_events transcript)

let test_routed_nested_and_persisted () =
  let store, ctx = prepared "routed" in
  let send = probe_send store ctx in
  let observed = policy [ (send, rule ()) ] in
  (* a routed call: the scheduler captures it and dispatches it later with its correlation id *)
  let recorder = Observation_transcript.create observed in
  let expression_ = expression store "probe.send(\"a\", \"b\")" in
  ignore
    (Eval.with_invocation ctx (fun _ ->
         Eval.register_root_handler ctx send (fun _ -> Ok (Value.VInt 9));
         Observation_transcript.record recorder ctx (fun () ->
             Result.map
               (fun (scheduled : Round_robin.scheduled) -> scheduled.value)
               (Round_robin.run_expr_scheduled ctx
                  ~mode:(Round_robin.Seeded_schedule { seed = 0 })
                  expression_))));
  Alcotest.(check (list string))
    "a routed result pairs with its call" [ "9" ]
    (results (Observation_transcript.transcript recorder));
  (* a nested call that is dispatched: each result stays with its own call *)
  let nested =
    record
      ~handler:(fun arguments ->
        match arguments with
        | Value.VText "outer" :: _ -> (
            match Eval.run_expr ctx (expression store "probe.send(\"inner\", \"x\")") with
            | Ok _ -> Ok (Value.VInt 1)
            | Error error -> Error error)
        | _ -> Ok (Value.VInt 5))
      store ctx observed
      [ "probe.send(\"outer\", \"y\")" ]
  in
  Alcotest.(check (list string)) "outer and inner results" [ "1"; "5" ] (results nested);
  (* a handler that raises leaves no call behind: later output is attributed correctly *)
  (match
     record ~handler:(fun _ -> raise Handler_boom) store ctx observed [ "probe.send(\"a\", \"b\")" ]
   with
  | _ -> Alcotest.fail "the handler exception was swallowed"
  | exception Handler_boom -> ());
  Alcotest.(check bool)
    "output after a raising handler" true
    (List.map
       (fun (event : Observation_transcript.event) -> event.output)
       (run_events (console_transcript store ctx Observation_policy.default "print(\"hi\")"))
    = [ Some (Observation_transcript.Data "hi") ]);
  (* a persisted transcript holds neither excluded fields nor secrets, and reads back exactly *)
  let sensitive = "hunter2-SENSITIVE" in
  let excluded =
    policy [ (send, rule ~arguments:(Observation_policy.Selected_arguments [ 0 ]) ()) ]
  in
  let transcript =
    record
      ~handler:(fun _ -> Ok (Value.VSecret (Secret.of_string sensitive)))
      store ctx excluded
      [ Printf.sprintf "{ probe.send(\"a\", %S); 0 }" sensitive ]
  in
  let path = Filename.temp_file "jacquard-obs1-" ".transcript" in
  Fun.protect
    ~finally:(fun () -> try Sys.remove path with Sys_error _ -> ())
    (fun () ->
      Out_channel.with_open_bin path (fun channel ->
          Out_channel.output_string channel (Observation_transcript.serialize transcript));
      let stored = In_channel.with_open_bin path In_channel.input_all in
      Alcotest.(check bool) "the file omits the value" false (contains stored sensitive);
      let reread = expect_ok "reread" (Observation_transcript.parse ~policy:excluded stored) in
      Alcotest.(check string)
        "the file reads back exactly" stored
        (Observation_transcript.serialize reread))

let test_impossible_fields () =
  let store, ctx = prepared "impossible-fields" in
  let send = probe_send store ctx in
  let observed = policy [ (send, rule ()) ] in
  let refuse label policy bytes =
    expect_code label "E1006" (Observation_transcript.parse ~policy bytes)
  in
  let failing =
    Observation_transcript.serialize
      (record
         ~handler:(fun _ -> Error (Runtime_err.Eval_error "no"))
         store ctx observed [ "probe.send(\"a\", \"b\")" ])
  in
  refuse "a fuel-exhausted handler result in a failed run" observed
    (replace_once failing "result failure code=uncoded" "result failure code=E0919");
  let secret =
    Observation_transcript.serialize
      (record
         ~handler:(fun _ -> Ok (Value.VSecret (Secret.of_string "s")))
         store ctx observed
         [ "{ probe.send(\"a\", \"b\"); 0 }" ])
  in
  refuse "an unknown opaque kind" observed
    (replace_once secret "unsupported kind=secret" "unsupported kind=password");
  (* an unfinished event is always the last, with nothing after its arguments *)
  let big = String.make 60_000 'a' in
  let projected =
    Observation_transcript.serialize
      (record ~fuel:300 store ctx Observation_policy.default
         [ Printf.sprintf "probe.send(%S, \"b\")" big ])
  in
  refuse "an unfinished event with an output" Observation_policy.default
    (replace_once projected "output missing\n" "output data bytes=1\nx\n");
  (* an outer call's result can run out after its nested call finished: the unfinished result is
     not on the last event, and that is a shape the recorder produces *)
  let nested =
    Observation_transcript.serialize
      (record ~fuel:2_000
         ~handler:(fun arguments ->
           match arguments with
           | Value.VText "outer" :: _ -> (
               match Eval.run_expr ctx (expression store "probe.send(\"inner\", \"x\")") with
               | Ok _ -> Ok (Value.VInt 1)
               | Error error -> Error error)
           | _ -> Ok (Value.VInt 5))
         store ctx observed
         [ "{ probe.send(\"outer\", \"y\"); spin(0) }" ])
  in
  let outer_unfinished = replace_once nested "result data bytes=1\n1\n" "result unfinished\n" in
  ignore
    (expect_ok "an earlier unfinished result"
       (Observation_transcript.parse ~policy:observed outer_unfinished));
  refuse "two unfinished fields" observed
    (replace_once outer_unfinished "result data bytes=1\n5\n" "result unfinished\n")

let suite =
  [
    Alcotest.test_case "policies are canonical, identified, and strictly parsed" `Quick
      test_policy_encoding;
    Alcotest.test_case "selected arguments and results distinguish calls; ignored ones agree" `Quick
      test_selected_arguments;
    Alcotest.test_case "policy drift, stale operations and stale interfaces are refused" `Quick
      test_drift_is_refused;
    Alcotest.test_case "excluded fields and secrets never reach bytes or diagnostics" `Quick
      test_redaction;
    Alcotest.test_case "failed, incomplete and truncated observations" `Quick
      test_failures_and_truncation;
    Alcotest.test_case "run-transcript-v1 is unchanged and recording is deterministic" `Quick
      test_v1_unchanged;
    Alcotest.test_case "constructors are observed by identity, not display name" `Quick
      test_constructor_identity;
    Alcotest.test_case "results and output pair with their own call" `Quick test_pairing;
    Alcotest.test_case "running out of fuel keeps what was observed" `Quick
      test_fuel_keeps_observations;
    Alcotest.test_case "impossible transcripts are refused and uncoded failures are not equal"
      `Quick test_impossible_transcripts;
    Alcotest.test_case "routed, nested and raising calls pair; persisted files stay redacted" `Quick
      test_routed_nested_and_persisted;
    Alcotest.test_case "fields the recorder cannot produce are refused" `Quick
      test_impossible_fields;
  ]
