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
  ]
