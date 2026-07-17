open Jacquard

let root = Concurrency_contract.task_id ~scope_path:[ 0 ] ~spawn_index:0
let child = Concurrency_contract.task_id ~scope_path:[ 0 ] ~spawn_index:1
let nested = Concurrency_contract.task_id ~scope_path:[ 0; 1 ] ~spawn_index:0
let program = Hash.of_string "schedule-trace-test-program"

let valid_events =
  [
    Schedule_trace.Create { scope_path = [ 0 ]; task = root; parent = None };
    Schedule_trace.Decide
      { sequence = 0; runnable = [ root ]; chosen = root; operation = Schedule_trace.Async_spawn };
    Schedule_trace.Create { scope_path = [ 0 ]; task = child; parent = Some root };
    Schedule_trace.Decide
      {
        sequence = 1;
        runnable = [ child; root ];
        chosen = child;
        operation = Schedule_trace.Async_scope;
      };
    Schedule_trace.Create { scope_path = [ 0; 1 ]; task = nested; parent = Some child };
    Schedule_trace.Decide
      {
        sequence = 2;
        runnable = [ root; nested ];
        chosen = root;
        operation = Schedule_trace.Routed (Hash.of_string "world-op");
      };
  ]

let valid ?fork events =
  match
    Schedule_trace.make ~scheduler:"fifo-round-robin-v0" ~program
      ~policy:Concurrency_contract.Fail_fast ~max_tasks:16 ~max_decisions:64 ?fork events
  with
  | Ok trace -> trace
  | Error diagnostics ->
      Alcotest.failf "valid trace rejected: %s"
        (String.concat "; " (List.map Diag.to_string diagnostics))

let diagnostic = function
  | Error [ diagnostic ] -> diagnostic
  | Error diagnostics -> Alcotest.failf "expected one diagnostic, got %d" (List.length diagnostics)
  | Ok _ -> Alcotest.fail "invalid schedule trace was accepted"

let contains needle haystack =
  let length = String.length needle in
  let rec loop index =
    index + length <= String.length haystack
    && (String.sub haystack index length = needle || loop (index + 1))
  in
  loop 0

let test_canonical_round_trip_and_identity () =
  let fork = Schedule_trace.{ decision = 2; chosen = root } in
  let trace = valid ~fork valid_events in
  let bytes = Schedule_trace.serialize trace in
  let expected_header =
    Printf.sprintf
      "jacquard-schedule format=1 scheduler=fifo-round-robin-v0 program=%s policy=fail-fast \
       max-tasks=16 max-decisions=64 fork=2:0#0\n"
      (Hash.to_hex program)
  in
  Alcotest.(check bool) "exact header" true (String.starts_with ~prefix:expected_header bytes);
  let reparsed =
    match Schedule_trace.parse bytes with
    | Ok trace -> trace
    | Error diagnostics ->
        Alcotest.failf "canonical parse failed: %s"
          (String.concat "; " (List.map Diag.to_string diagnostics))
  in
  Alcotest.(check string) "byte-identical round trip" bytes (Schedule_trace.serialize reparsed);
  Alcotest.(check string)
    "canonical identity"
    (Hash.to_hex (Hash.of_string bytes))
    (Hash.to_hex (Schedule_trace.identity reparsed))

let test_legacy_unknown_and_noncanonical_refused () =
  let legacy = diagnostic (Schedule_trace.parse "decision=0 runnable=[0#0] chosen=0#0\n") in
  Alcotest.(check bool)
    "unversioned refusal" true
    (contains "unversioned schedule traces" legacy.message);
  let bytes = Schedule_trace.serialize (valid valid_events) in
  let replace_once source needle replacement =
    let index =
      let rec find index =
        if index + String.length needle > String.length source then None
        else if String.sub source index (String.length needle) = needle then Some index
        else find (index + 1)
      in
      find 0
    in
    match index with
    | None -> Alcotest.fail "test replacement needle missing"
    | Some index ->
        String.sub source 0 index ^ replacement
        ^ String.sub source
            (index + String.length needle)
            (String.length source - index - String.length needle)
  in
  let unknown_version =
    diagnostic (Schedule_trace.parse (replace_once bytes "format=1" "format=2"))
  in
  Alcotest.(check bool)
    "unknown version refusal" true
    (contains "unsupported format version 2" unknown_version.message);
  let noncanonical = diagnostic (Schedule_trace.parse (" " ^ bytes)) in
  Alcotest.(check bool)
    "whitespace refusal" true
    (contains "unversioned schedule traces" noncanonical.message);
  let no_lf = diagnostic (Schedule_trace.parse (String.sub bytes 0 (String.length bytes - 1))) in
  Alcotest.(check bool) "trailing LF required" true (contains "must end with LF" no_lf.message)

let test_impossible_events_refused () =
  let expect_with_bounds ~max_tasks ~max_decisions message events =
    let diagnostic =
      Schedule_trace.make ~scheduler:"fifo-round-robin-v0" ~program
        ~policy:Concurrency_contract.Fail_fast ~max_tasks ~max_decisions events
      |> diagnostic
    in
    Alcotest.(check bool) message true (contains message diagnostic.message)
  in
  let expect = expect_with_bounds ~max_tasks:16 ~max_decisions:64 in
  expect "first event" (List.tl valid_events);
  expect "created more than once"
    (Schedule_trace.Create { scope_path = [ 0 ]; task = root; parent = None } :: valid_events);
  let wrong_sequence =
    match valid_events with
    | first :: Schedule_trace.Decide decision :: rest ->
        first :: Schedule_trace.Decide { decision with sequence = 1 } :: rest
    | _ -> assert false
  in
  expect "decision sequence 0 was expected" wrong_sequence;
  let outside =
    [
      List.hd valid_events;
      Schedule_trace.Decide
        { sequence = 0; runnable = [ root ]; chosen = child; operation = Schedule_trace.Return };
    ]
  in
  expect "outside its runnable queue" outside;
  let provenance = Schedule_trace.{ decision = 2; chosen = child } in
  let diagnostic =
    Schedule_trace.make ~scheduler:"fifo-round-robin-v0" ~program
      ~policy:Concurrency_contract.Fail_fast ~max_tasks:16 ~max_decisions:64 ~fork:provenance
      valid_events
    |> diagnostic
  in
  Alcotest.(check bool)
    "fork provenance matches branch" true
    (contains "fork provenance chooses" diagnostic.message);
  let impossible_creation =
    [
      Schedule_trace.Create { scope_path = [ 0 ]; task = root; parent = None };
      Schedule_trace.Decide
        { sequence = 0; runnable = [ root ]; chosen = root; operation = Schedule_trace.Return };
      Schedule_trace.Create { scope_path = [ 0 ]; task = child; parent = Some root };
    ]
  in
  expect "cannot create a task" impossible_creation;
  let sibling = Concurrency_contract.task_id ~scope_path:[ 0 ] ~spawn_index:2 in
  let double_creation =
    [
      Schedule_trace.Create { scope_path = [ 0 ]; task = root; parent = None };
      Schedule_trace.Decide
        { sequence = 0; runnable = [ root ]; chosen = root; operation = Schedule_trace.Async_spawn };
      Schedule_trace.Create { scope_path = [ 0 ]; task = child; parent = Some root };
      Schedule_trace.Create { scope_path = [ 0 ]; task = sibling; parent = Some root };
    ]
  in
  expect "must follow a decision" double_creation;
  let root_create = Schedule_trace.Create { scope_path = [ 0 ]; task = root; parent = None } in
  let spawn =
    Schedule_trace.Decide
      { sequence = 0; runnable = [ root ]; chosen = root; operation = Schedule_trace.Async_spawn }
  in
  expect_with_bounds ~max_tasks:1 ~max_decisions:2 "max-tasks 1"
    [
      root_create;
      spawn;
      Schedule_trace.Create { scope_path = [ 0 ]; task = child; parent = Some root };
    ];
  expect_with_bounds ~max_tasks:1 ~max_decisions:1 "max-decisions 1"
    [
      root_create;
      Schedule_trace.Decide
        { sequence = 0; runnable = [ root ]; chosen = root; operation = Schedule_trace.Async_yield };
      Schedule_trace.Decide
        { sequence = 1; runnable = [ root ]; chosen = root; operation = Schedule_trace.Return };
    ];
  expect_with_bounds ~max_tasks:1 ~max_decisions:1 "runnable queue exceeds max-tasks 1"
    [
      root_create;
      Schedule_trace.Decide
        {
          sequence = 0;
          runnable = [ root; root ];
          chosen = root;
          operation = Schedule_trace.Return;
        };
    ];
  expect_with_bounds ~max_tasks:1 ~max_decisions:2 "terminal task 0#0 reappears"
    [
      root_create;
      Schedule_trace.Decide
        { sequence = 0; runnable = [ root ]; chosen = root; operation = Schedule_trace.Return };
      Schedule_trace.Decide
        { sequence = 1; runnable = [ root ]; chosen = root; operation = Schedule_trace.Return };
    ]

let suite =
  [
    Alcotest.test_case "canonical codec and identity" `Quick test_canonical_round_trip_and_identity;
    Alcotest.test_case "legacy, unknown, and noncanonical refusal" `Quick
      test_legacy_unknown_and_noncanonical_refused;
    Alcotest.test_case "impossible event refusal" `Quick test_impossible_events_refused;
  ]
