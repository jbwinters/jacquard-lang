open Jacquard

let fail_runtime label = function
  | Ok value -> Alcotest.failf "%s unexpectedly succeeded with %s" label (Value.show value)
  | Error _ -> ()

let expression store source =
  match Reader.parse_one ~file:"run-transcript.jqd" source with
  | Error diagnostics -> Eval_support.fail_diags "parse run-transcript fixture" diagnostics
  | Ok form -> (
      match Kernel.expr_of_form form with
      | Error diagnostics -> Eval_support.fail_diags "validate run-transcript fixture" diagnostics
      | Ok expression -> (
          match Resolve.resolve_expr (Store.names_view store) expression with
          | Ok expression -> expression
          | Error diagnostics ->
              Eval_support.fail_diags "resolve run-transcript fixture" diagnostics))

let recorded ?(install = fun _ -> ()) source run =
  let store, ctx = Eval_support.make_prelude_ctx () in
  install ctx;
  let recorder = Run_transcript.create () in
  let result =
    Run_transcript.record_expression recorder ctx (fun () -> run ctx (expression store source))
  in
  (result, Run_transcript.transcript recorder)

let direct ctx expression = Eval.run_expr ctx expression

let console ctx =
  let output = Buffer.create 16 in
  (match Prelude.install_console ctx ~out:(Buffer.add_string output) with
  | Ok () -> ()
  | Error diagnostics -> Eval_support.fail_diags "install console" diagnostics);
  output

let test_pure_is_canonical_and_deterministic () =
  let first, first_transcript = recorded "(lit 7)" direct in
  let second, second_transcript = recorded "(lit 7)" direct in
  (match (first, second) with Ok _, Ok _ -> () | _ -> Alcotest.fail "pure recording failed");
  let first_bytes = Run_transcript.serialize first_transcript in
  Alcotest.(check string)
    "fresh pure runs are byte-identical" first_bytes
    (Run_transcript.serialize second_transcript);
  Alcotest.(check string)
    "pure transcript exact bytes"
    "jacquard-run-transcript format=1 observations=1\n\
     observation index=0 value-bytes=2 trace-events=0\n\
     7\n"
    first_bytes;
  match Run_transcript.observations first_transcript with
  | [ { value; trace = [] } ] -> Alcotest.(check string) "rendered value" "7\n" value
  | _ -> Alcotest.fail "pure run should have one trace-free observation"

let test_console_output_is_attached_to_print () =
  let source = "(let nonrec (pwild) (app (var print) (lit \"hello\")) (lit 0))" in
  let result, transcript = recorded ~install:(fun ctx -> ignore (console ctx)) source direct in
  let second_result, second_transcript =
    recorded ~install:(fun ctx -> ignore (console ctx)) source direct
  in
  (match result with
  | Ok _ -> ()
  | Error error -> Alcotest.failf "console run failed: %s" (Runtime_err.to_string error));
  (match second_result with
  | Ok _ -> ()
  | Error error -> Alcotest.failf "second console run failed: %s" (Runtime_err.to_string error));
  Alcotest.(check string)
    "fresh Console runs are byte-identical"
    (Run_transcript.serialize transcript)
    (Run_transcript.serialize second_transcript);
  (match Run_transcript.parse (Run_transcript.serialize transcript) with
  | Ok parsed ->
      Alcotest.(check string)
        "recorded Console identity is accepted by strict parsing"
        (Run_transcript.serialize transcript)
        (Run_transcript.serialize parsed)
  | Error diagnostics ->
      Eval_support.fail_diags "parse recorder-produced Console transcript" diagnostics);
  let store, _ = Eval_support.make_prelude_ctx () in
  let print =
    match Store.lookup_kind store "print" Resolve.KOp with
    | Some entry -> entry.hash
    | None -> Alcotest.fail "missing Console.print"
  in
  match Run_transcript.observations transcript with
  | [ { value = "0\n"; trace = [ { operation; output } ] } ] ->
      Alcotest.(check bool) "Console print identity" true (Hash.equal print operation);
      Alcotest.(check string) "exact Console output" "hello" output
  | _ -> Alcotest.fail "Console recording did not produce the expected single event"

let test_reentrant_console_output_stays_with_its_operation () =
  let store, ctx = Eval_support.make_prelude_ctx () in
  let recorder = Run_transcript.create () in
  let output = Buffer.create 16 in
  let reentered = ref false in
  let nested = expression store "(app (var print) (lit \"nested\"))" in
  (match
     Prelude.install_console ctx ~out:(fun bytes ->
         Buffer.add_string output bytes;
         if String.equal bytes "outer" && not !reentered then (
           reentered := true;
           match Eval.run_expr ctx nested with
           | Ok _ -> ()
           | Error error ->
               Alcotest.failf "reentrant Console run failed: %s" (Runtime_err.to_string error)))
   with
  | Ok () -> ()
  | Error diagnostics -> Eval_support.fail_diags "install reentrant console" diagnostics);
  let result =
    Run_transcript.record_expression recorder ctx (fun () ->
        Eval.run_expr ctx (expression store "(app (var print) (lit \"outer\"))"))
  in
  (match result with
  | Ok _ -> ()
  | Error error -> Alcotest.failf "outer Console run failed: %s" (Runtime_err.to_string error));
  Alcotest.(check string) "both trusted callbacks ran" "outernested" (Buffer.contents output);
  match Run_transcript.observations (Run_transcript.transcript recorder) with
  | [ { trace = [ first; second ]; _ } ] ->
      Alcotest.(check string) "outer output remains on outer event" "outer" first.output;
      Alcotest.(check string) "nested output remains on nested event" "nested" second.output
  | _ -> Alcotest.fail "reentrant Console output should produce two routed events"

let channel_source =
  "(match (app (var channel.open) (lit 0))\n\
  \  (clause (pcon ok (pvar channel))\n\
  \    (let nonrec (pvar sender)\n\
  \      (app (var async.spawn)\n\
  \        (lam () (app (var channel.send) (var channel) (lit 9))))\n\
  \      (let nonrec (pvar received) (app (var channel.recv) (var channel))\n\
  \        (tuple (var received) (app (var async.await) (var sender))))))\n\
  \  (clause (pcon err (pvar error)) (var error)))"

let seeded ctx expression =
  Round_robin.run_expr_scheduled ctx ~mode:(Round_robin.Seeded_schedule { seed = 193 }) expression
  |> Result.map (fun scheduled -> scheduled.Round_robin.value)

let test_seeded_spawn_await_channel_is_deterministic () =
  let first, first_transcript = recorded channel_source seeded in
  let second, second_transcript = recorded channel_source seeded in
  (match (first, second) with
  | Ok value, Ok other ->
      Alcotest.(check string) "same result" (Value.show value) (Value.show other)
  | Error error, _ | _, Error error ->
      Alcotest.failf "seeded scheduler run failed: %s" (Runtime_err.to_string error));
  Alcotest.(check string)
    "seeded spawn/await/channel transcript bytes"
    (Run_transcript.serialize first_transcript)
    (Run_transcript.serialize second_transcript);
  match Run_transcript.observations first_transcript with
  | [ { trace; _ } ] ->
      let pinned name entries = List.assoc name entries in
      let expected =
        [
          pinned "channel.open" Channel_contract.channel_operation_hashes;
          pinned "async.spawn" Concurrency_contract.async_operation_hashes;
          pinned "channel.recv" Channel_contract.channel_operation_hashes;
          pinned "channel.send" Channel_contract.channel_operation_hashes;
          pinned "async.await" Concurrency_contract.async_operation_hashes;
        ]
      in
      Alcotest.(check (list string))
        "exact scheduler operation members in routed order" expected
        (List.map (fun (event : Run_transcript.event) -> Hash.to_hex event.operation) trace);
      Alcotest.(check bool)
        "non-Console scheduler events carry no output" true
        (List.for_all (fun (event : Run_transcript.event) -> String.equal event.output "") trace)
  | _ -> Alcotest.fail "scheduled expression should commit exactly one observation"

let test_multiple_expressions_keep_order () =
  let record_pair () =
    let store, ctx = Eval_support.make_prelude_ctx () in
    let recorder = Run_transcript.create () in
    let run source =
      Run_transcript.record_expression recorder ctx (fun () ->
          Eval.run_expr ctx (expression store source))
    in
    (match (run "(lit 1)", run "(lit 2)") with
    | Ok _, Ok _ -> ()
    | _ -> Alcotest.fail "sequential run failed");
    Run_transcript.transcript recorder
  in
  let transcript = record_pair () in
  let second_transcript = record_pair () in
  Alcotest.(check string)
    "fresh multiple-expression runs are byte-identical"
    (Run_transcript.serialize transcript)
    (Run_transcript.serialize second_transcript);
  match Run_transcript.observations transcript with
  | [ { value = "1\n"; _ }; { value = "2\n"; _ } ] -> ()
  | _ -> Alcotest.fail "sequential expressions were not retained in order"

let test_failures_commit_no_partial_observation () =
  let source =
    "(let nonrec (pwild) (app (var print) (lit \"visible-but-not-committed\")) (app (var add) (lit \
     \"x\") (lit 1)))"
  in
  let store, ctx = Eval_support.make_prelude_ctx () in
  let output = console ctx in
  let recorder = Run_transcript.create () in
  let result =
    Run_transcript.record_expression recorder ctx (fun () ->
        Eval.run_expr ctx (expression store source))
  in
  let transcript = Run_transcript.transcript recorder in
  fail_runtime "failed expression" result;
  Alcotest.(check string)
    "failed expression did reach the Console adapter" "visible-but-not-committed"
    (Buffer.contents output);
  Alcotest.(check int)
    "failed result adds no observation" 0
    (List.length (Run_transcript.observations transcript));
  Alcotest.(check string)
    "failure leaves only the empty header" "jacquard-run-transcript format=1 observations=0\n"
    (Run_transcript.serialize transcript);
  let _store, ctx = Eval_support.make_prelude_ctx () in
  let recorder = Run_transcript.create () in
  (try
     ignore (Run_transcript.record_expression recorder ctx (fun () -> raise Exit));
     Alcotest.fail "host exception should escape unchanged"
   with Exit -> ());
  Alcotest.(check int)
    "host exception adds no observation" 0
    (List.length (Run_transcript.observations (Run_transcript.transcript recorder)))

let zero_hash = String.make (2 * Hash.digest_size) '0'
let one_hash = String.make ((2 * Hash.digest_size) - 1) '0' ^ "1"
let console_print_hash = "28570e6bcdeb8646a90b31971204be7007f658bee65154b96e587c47a6585d5e"

let canonical observations =
  let body = String.concat "" observations in
  Printf.sprintf "jacquard-run-transcript format=1 observations=%d\n%s" (List.length observations)
    body

let observation ?(index = 0) ?(value = "0\n") events =
  Printf.sprintf "observation index=%d value-bytes=%d trace-events=%d\n%s%s" index
    (String.length value) (List.length events) value (String.concat "" events)

let event ?(index = 0) ?(operation = console_print_hash) ?(output = "") () =
  Printf.sprintf "trace index=%d operation=%s output-bytes=%d\n%s" index operation
    (String.length output) output

let parse_ok label bytes =
  match Run_transcript.parse bytes with
  | Ok transcript -> transcript
  | Error diagnostics -> Eval_support.fail_diags label diagnostics

let expect_invalid label bytes =
  let contains needle haystack =
    let needle_length = String.length needle in
    let rec search index =
      index + needle_length <= String.length haystack
      && (String.sub haystack index needle_length = needle || search (index + 1))
    in
    search 0
  in
  match Run_transcript.parse bytes with
  | Ok _ -> Alcotest.failf "%s: malformed transcript was accepted" label
  | Error diagnostics ->
      Alcotest.(check (list string))
        (label ^ " code") [ "E1004" ]
        (List.map Diag.code_or_uncoded diagnostics);
      Alcotest.(check bool)
        (label ^ " Warp domain") true
        (List.for_all (fun diagnostic -> Diag.domain diagnostic = Diag.Warp) diagnostics);
      List.iter
        (fun diagnostic ->
          Alcotest.(check bool)
            (label ^ " does not echo hostile payload")
            false
            (String.contains (Diag.cause diagnostic) '\255'
            || contains "hostile-payload" (Diag.cause diagnostic)))
        diagnostics

let expect_divergence label ~kind ~path ~rendered verdict =
  match verdict with
  | Run_transcript.Equal -> Alcotest.failf "%s: expected a divergence" label
  | Run_transcript.Divergence divergence ->
      Alcotest.(check string)
        (label ^ " kind") kind
        (Run_transcript.divergence_kind_name divergence.kind);
      Alcotest.(check string)
        (label ^ " path") path
        (Run_transcript.position_path divergence.position);
      Alcotest.(check string) (label ^ " rendering") rendered (Run_transcript.render divergence)

let test_parse_roundtrip_and_payload_framing () =
  let bytes =
    canonical
      [
        observation ~value:"header-looking\nvalue\n"
          [ event ~output:"raw\ntrace index=999 operation=not-a-header\n\255" () ];
      ]
  in
  let transcript = parse_ok "framed payload parse" bytes in
  Alcotest.(check string)
    "parse then serialize is identity" bytes
    (Run_transcript.serialize transcript);
  match Run_transcript.observations transcript with
  | [ { value = "header-looking\nvalue\n"; trace = [ { output; _ } ] } ] ->
      Alcotest.(check string)
        "Console payload remains exact raw bytes"
        "raw\ntrace index=999 operation=not-a-header\n\255" output
  | _ -> Alcotest.fail "framed transcript decoded unexpected observations"

let test_parser_rejects_every_noncanonical_class () =
  let valid = canonical [ observation [ event () ] ] in
  let replace_once needle replacement source =
    let needle_length = String.length needle in
    let rec find index =
      if index + needle_length > String.length source then
        Alcotest.failf "test fixture lacks %S" needle
      else if String.sub source index needle_length = needle then
        String.sub source 0 index ^ replacement
        ^ String.sub source (index + needle_length) (String.length source - index - needle_length)
      else find (index + 1)
    in
    find 0
  in
  let cases =
    [
      ("unknown version", replace_once "format=1" "format=2" valid);
      ("field spelling", replace_once "observations=" "observationz=" valid);
      ( "field order",
        replace_once "value-bytes=2 trace-events=1" "trace-events=1 value-bytes=2" valid );
      ("alternate whitespace", replace_once "format=1 observations" "format=1  observations" valid);
      ("CRLF", replace_once "observations=1\n" "observations=1\r\n" valid);
      ("noncanonical count", replace_once "observations=1" "observations=01" valid);
      ("signed count", replace_once "observations=1" "observations=+1" valid);
      ("empty count", replace_once "observations=1" "observations=" valid);
      ("nondigit count", replace_once "observations=1" "observations=x" valid);
      ("noncanonical length", replace_once "value-bytes=2" "value-bytes=02" valid);
      ("uppercase hash", replace_once console_print_hash (String.make 63 '0' ^ "A") valid);
      ("short hash", replace_once console_print_hash (String.make 63 '0') valid);
      ("long hash", replace_once console_print_hash (String.make 65 '0') valid);
      ("nonhex hash", replace_once console_print_hash (String.make 63 '0' ^ "g") valid);
      ("observation index", replace_once "observation index=0" "observation index=1" valid);
      ("trace index", replace_once "trace index=0" "trace index=1" valid);
      ("incorrect observation count", replace_once "observations=1" "observations=0" valid);
      ("incorrect trace count", replace_once "trace-events=1" "trace-events=0" valid);
      ("truncated value", replace_once "value-bytes=2" "value-bytes=999" valid);
      ("truncated output", replace_once "output-bytes=0" "output-bytes=1" valid);
      ("value without LF", replace_once "trace-events=1\n0\ntrace" "trace-events=1\n00trace" valid);
      ("trailing bytes", valid ^ "\255hostile-payload");
      ("empty input", "");
    ]
  in
  List.iter (fun (label, bytes) -> expect_invalid label bytes) cases;
  expect_invalid "non-Console output attribution"
    (canonical [ observation [ event ~operation:zero_hash ~output:"hostile-payload" () ] ]);
  expect_invalid "overflowing decimal"
    ("jacquard-run-transcript format=1 observations=" ^ String.make 128 '9' ^ "\n")

let test_compare_outcomes_and_exact_rendering () =
  let base =
    parse_ok "base comparison transcript"
      (canonical [ observation [ event ~output:"left\n" () ]; observation ~index:1 [] ])
  in
  Alcotest.(check bool)
    "equal transcript" true
    (match Run_transcript.compare base base with Run_transcript.Equal -> true | _ -> false);
  let value =
    parse_ok "value comparison transcript"
      (canonical
         [ observation ~value:"1\n" [ event ~output:"left\n" () ]; observation ~index:1 [] ])
  in
  expect_divergence "value" ~kind:"value-divergence" ~path:"observation[0].value"
    ~rendered:"  at observation[0].value:\n    - \"0\\n\"\n    + \"1\\n\""
    (Run_transcript.compare base value);
  let value_and_trace =
    parse_ok "value-before-trace comparison transcript"
      (canonical
         [ observation ~value:"1\n" [ event ~output:"right\t" () ]; observation ~index:1 [] ])
  in
  expect_divergence "value precedes trace" ~kind:"value-divergence" ~path:"observation[0].value"
    ~rendered:"  at observation[0].value:\n    - \"0\\n\"\n    + \"1\\n\""
    (Run_transcript.compare base value_and_trace);
  let operation_base =
    parse_ok "operation base transcript"
      (canonical [ observation [ event ~operation:zero_hash () ]; observation ~index:1 [] ])
  in
  let trace_operation =
    parse_ok "operation comparison transcript"
      (canonical [ observation [ event ~operation:one_hash () ]; observation ~index:1 [] ])
  in
  expect_divergence "trace operation" ~kind:"trace-divergence" ~path:"observation[0].trace[0]"
    ~rendered:
      (Printf.sprintf
         "  at observation[0].trace[0]:\n\
         \    - operation=%s output=\"\"\n\
         \    + operation=%s output=\"\""
         zero_hash one_hash)
    (Run_transcript.compare operation_base trace_operation);
  let trace_output =
    parse_ok "output comparison transcript"
      (canonical [ observation [ event ~output:"right\t" () ]; observation ~index:1 [] ])
  in
  expect_divergence "trace output" ~kind:"trace-divergence" ~path:"observation[0].trace[0]"
    ~rendered:
      (Printf.sprintf
         "  at observation[0].trace[0]:\n\
         \    - operation=%s output=\"left\\n\"\n\
         \    + operation=%s output=\"right\\t\""
         console_print_hash console_print_hash)
    (Run_transcript.compare base trace_output);
  let observation_prefix =
    parse_ok "observation prefix" (canonical [ observation [ event ~output:"left\n" () ] ])
  in
  expect_divergence "observation prefix" ~kind:"length-divergence" ~path:"observation[1]"
    ~rendered:
      "  at observation[1]:\n\
      \    - observation value=\"0\\n\" value-bytes=2 trace-events=0\n\
      \    + <missing>"
    (Run_transcript.compare base observation_prefix);
  let trace_prefix =
    parse_ok "trace prefix" (canonical [ observation []; observation ~index:1 [] ])
  in
  expect_divergence "trace prefix" ~kind:"length-divergence" ~path:"observation[0].trace[0]"
    ~rendered:
      (Printf.sprintf
         "  at observation[0].trace[0]:\n    - operation=%s output=\"left\\n\"\n    + <missing>"
         console_print_hash)
    (Run_transcript.compare base trace_prefix)

let test_equal_iff_canonical_bytes_equal () =
  let samples =
    [
      canonical [];
      canonical [ observation [] ];
      canonical [ observation [ event () ] ];
      canonical [ observation ~value:"line one\nline two\n" [ event ~output:"raw\000bytes" () ] ];
      canonical
        [ observation []; observation ~index:1 ~value:"last\n" [ event ~operation:one_hash () ] ];
    ]
  in
  let transcripts = List.map (parse_ok "byte-equivalence sample") samples in
  List.iteri
    (fun left_index left ->
      List.iteri
        (fun right_index right ->
          let equal =
            match Run_transcript.compare left right with Run_transcript.Equal -> true | _ -> false
          in
          let byte_equal =
            String.equal (Run_transcript.serialize left) (Run_transcript.serialize right)
          in
          Alcotest.(check bool)
            (Printf.sprintf "pair %d/%d structural iff byte equality" left_index right_index)
            byte_equal equal)
        transcripts)
    transcripts

let test_compare_values_projects_away_traces () =
  let left =
    parse_ok "value projection left"
      (canonical
         [
           observation ~value:"answer\n" [ event ~output:"left" () ];
           observation ~index:1 ~value:"tail\n" [ event ~operation:one_hash () ];
         ])
  in
  let trace_only_change =
    parse_ok "value projection trace-only change"
      (canonical
         [
           observation ~value:"answer\n" [ event ~output:"right" () ];
           observation ~index:1 ~value:"tail\n" [];
         ])
  in
  Alcotest.(check bool)
    "different traces have equal result projection" true
    (match Run_transcript.compare_values left trace_only_change with
    | Run_transcript.Equal -> true
    | Run_transcript.Divergence _ -> false);
  let changed_value =
    parse_ok "value projection changed value"
      (canonical
         [
           observation ~value:"changed\n" [ event ~operation:one_hash () ];
           observation ~index:1 ~value:"tail\n" [];
         ])
  in
  expect_divergence "result projection value" ~kind:"value-divergence" ~path:"observation[0].value"
    ~rendered:"  at observation[0].value:\n    - \"answer\\n\"\n    + \"changed\\n\""
    (Run_transcript.compare_values left changed_value);
  let prefix =
    parse_ok "value projection prefix"
      (canonical [ observation ~value:"answer\n" [ event ~operation:one_hash () ] ])
  in
  let expected = "  at observation[1]:\n    - \"tail\\n\"\n    + <missing>" in
  match Run_transcript.compare_values left prefix with
  | Run_transcript.Equal -> Alcotest.fail "result projection prefix unexpectedly compared equal"
  | Run_transcript.Divergence divergence ->
      Alcotest.(check string)
        "result projection prefix kind" "length-divergence"
        (Run_transcript.divergence_kind_name divergence.kind);
      Alcotest.(check string)
        "result projection prefix path" "observation[1]"
        (Run_transcript.position_path divergence.position);
      let rendered = Run_transcript.render divergence in
      Alcotest.(check string) "result projection prefix rendering" expected rendered;
      let contains needle haystack =
        let needle_length = String.length needle in
        let rec search index =
          index + needle_length <= String.length haystack
          && (String.sub haystack index needle_length = needle || search (index + 1))
        in
        search 0
      in
      Alcotest.(check bool)
        "result projection prefix has no trace count" false
        (contains "trace-events=" rendered);
      Alcotest.(check bool)
        "result projection prefix has no operation hash" false (contains one_hash rendered)

type mutation = { base : string; changed : string; expected_path : string }

let generated_mutation ~trace_mutation ~observation_count ~observation_choice ~trace_count
    ~trace_choice =
  let observation_index = observation_choice mod observation_count in
  let trace_index = trace_choice mod trace_count in
  let observations ~mutated =
    List.init observation_count (fun index ->
        let value =
          if mutated && (not trace_mutation) && index = observation_index then
            Printf.sprintf "value-%d-mutated\n" index
          else Printf.sprintf "value-%d\n" index
        in
        let events =
          List.init trace_count (fun event_index ->
              let output =
                if
                  mutated && trace_mutation && index = observation_index
                  && event_index = trace_index
                then Printf.sprintf "output-%d-%d-mutated" index event_index
                else Printf.sprintf "output-%d-%d" index event_index
              in
              event ~index:event_index ~output ())
        in
        observation ~index ~value events)
  in
  {
    base = canonical (observations ~mutated:false);
    changed = canonical (observations ~mutated:true);
    expected_path =
      (if not trace_mutation then Printf.sprintf "observation[%d].value" observation_index
       else Printf.sprintf "observation[%d].trace[%d]" observation_index trace_index);
  }

let test_seeded_single_mutation_reports_position () =
  let seen_later_observation = ref false in
  let seen_later_trace = ref false in
  let check_one ~trace_mutation ~observation_count ~observation_choice ~trace_count ~trace_choice =
    let mutation =
      generated_mutation ~trace_mutation ~observation_count ~observation_choice ~trace_count
        ~trace_choice
    in
    match (Run_transcript.parse mutation.base, Run_transcript.parse mutation.changed) with
    | Ok base, Ok changed ->
        let copy_is_equal =
          match Run_transcript.compare base base with Run_transcript.Equal -> true | _ -> false
        in
        let mutation_position =
          match Run_transcript.compare base changed with
          | Run_transcript.Equal -> None
          | Run_transcript.Divergence divergence ->
              Some (Run_transcript.position_path divergence.position)
        in
        copy_is_equal && mutation_position = Some mutation.expected_path
    | Error _, _ | _, Error _ -> false
  in
  let property =
    QCheck.Test.make ~count:200
      ~name:"value and trace transcript mutations report their logical positions"
      QCheck.(quad (int_range 1 5) nat_small (int_range 1 4) nat_small)
      (fun (observation_count, observation_choice, trace_count, trace_choice) ->
        let observation_index = observation_choice mod observation_count in
        let trace_index = trace_choice mod trace_count in
        if observation_index > 0 then seen_later_observation := true;
        if trace_index > 0 then seen_later_trace := true;
        check_one ~trace_mutation:false ~observation_count ~observation_choice ~trace_count
          ~trace_choice
        && check_one ~trace_mutation:true ~observation_count ~observation_choice ~trace_count
             ~trace_choice)
  in
  QCheck.Test.check_exn ~rand:(Random.State.make [| 0x194; 0x52; 0x1004 |]) property;
  Alcotest.(check bool) "fixed seed reaches a later observation" true !seen_later_observation;
  Alcotest.(check bool) "fixed seed reaches a later trace event" true !seen_later_trace

let suite =
  [
    Alcotest.test_case "pure canonical determinism" `Quick test_pure_is_canonical_and_deterministic;
    Alcotest.test_case "Console output is attached" `Quick test_console_output_is_attached_to_print;
    Alcotest.test_case "reentrant Console output is attributed" `Quick
      test_reentrant_console_output_stays_with_its_operation;
    Alcotest.test_case "seeded spawn await channel determinism" `Quick
      test_seeded_spawn_await_channel_is_deterministic;
    Alcotest.test_case "multiple expressions" `Quick test_multiple_expressions_keep_order;
    Alcotest.test_case "failure has no partial observation" `Quick
      test_failures_commit_no_partial_observation;
    Alcotest.test_case "parse roundtrip and payload framing" `Quick
      test_parse_roundtrip_and_payload_framing;
    Alcotest.test_case "parser strict malformed coverage" `Quick
      test_parser_rejects_every_noncanonical_class;
    Alcotest.test_case "compare outcomes and exact rendering" `Quick
      test_compare_outcomes_and_exact_rendering;
    Alcotest.test_case "Equal iff canonical bytes equal" `Quick test_equal_iff_canonical_bytes_equal;
    Alcotest.test_case "result comparison projects traces" `Quick
      test_compare_values_projects_away_traces;
    Alcotest.test_case "seeded single mutation reports position" `Quick
      test_seeded_single_mutation_reports_position;
  ]
