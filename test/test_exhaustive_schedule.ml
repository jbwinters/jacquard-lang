open Jacquard

let store, ctx = Eval_support.make_prelude_ctx ()

let expression source =
  match Reader.parse_one ~file:"exhaustive-schedule.jqd" source with
  | Error diagnostics -> Eval_support.fail_diags "parse exhaustive schedule fixture" diagnostics
  | Ok form -> (
      match Kernel.expr_of_form form with
      | Error diagnostics ->
          Eval_support.fail_diags "validate exhaustive schedule fixture" diagnostics
      | Ok expression -> (
          match Resolve.resolve_expr (Store.names_view store) expression with
          | Ok expression -> expression
          | Error diagnostics ->
              Eval_support.fail_diags "resolve exhaustive schedule fixture" diagnostics))

let run ?(policy = Concurrency_contract.Collect) ?bounds source =
  match Exhaustive_schedule.run_expr ctx ~policy ?bounds (expression source) with
  | Ok report -> report
  | Error diagnostics -> Eval_support.fail_diags "enumerate schedules" diagnostics

let contains text substring =
  let rec loop offset =
    offset + String.length substring <= String.length text
    && (String.sub text offset (String.length substring) = substring || loop (offset + 1))
  in
  loop 0

let one_immediate = "(let nonrec (pwild) (app (var async.spawn) (lam () (lit 1))) (lit 0))"

let one_yield =
  "(let nonrec (pwild)   (app (var async.spawn)     (lam () (let nonrec (pwild) (app (var \
   async.yield)) (lit 1))))   (lit 0))"

let two_immediate =
  "(let nonrec (pwild) (app (var async.spawn) (lam () (lit 1)))   (let nonrec (pwild) (app (var \
   async.spawn) (lam () (lit 2))) (lit 0)))"

let channel_rendezvous =
  "(match (app (var channel.open) (lit 0))\n\
  \  (clause (pcon ok (pvar channel))\n\
  \    (let nonrec (pvar sender)\n\
  \      (app (var async.spawn)\n\
  \        (lam () (app (var channel.send) (var channel) (lit 7))))\n\
  \      (let nonrec (pvar received) (app (var channel.recv) (var channel))\n\
  \        (tuple (var received) (app (var async.await) (var sender))))))\n\
  \  (clause (pcon err (pvar error)) (var error)))"

let require_complete expected (report : Exhaustive_schedule.report) =
  Alcotest.(check int) "exact explored count" expected report.explored;
  Alcotest.(check int) "explored agrees with worlds" expected (List.length report.worlds);
  match report.completeness with
  | Exhaustive_schedule.Complete -> ()
  | Incomplete reasons ->
      Alcotest.failf "expected complete search, got %s"
        (String.concat "; " (List.map Exhaustive_schedule.incomplete_reason_to_string reasons))

let trace_key world = Schedule_trace.serialize world.Exhaustive_schedule.schedule

let test_hand_counted_schedule_trees () =
  let immediate = run one_immediate in
  require_complete 2 immediate;
  let yielded = run one_yield in
  require_complete 3 yielded;
  let two = run two_immediate in
  require_complete 8 two;
  let unique = List.sort_uniq String.compare (List.map trace_key two.worlds) in
  Alcotest.(check int) "default search performs no deduplication" 8 (List.length unique);
  let channels = run channel_rendezvous in
  require_complete 4 channels;
  Alcotest.(check int)
    "all Channel rendezvous schedules have distinct canonical traces" 4
    (channels.worlds |> List.map trace_key |> List.sort_uniq String.compare |> List.length);
  let channel_hashes =
    Channel_contract.channel_operation_hashes
    |> List.map (fun (_, encoded) -> Option.get (Hash.of_hex encoded))
  in
  let channel_hash name = List.assoc name Channel_contract.channel_operation_hashes in
  let required_channel_hashes =
    [ channel_hash "channel.open"; channel_hash "channel.send"; channel_hash "channel.recv" ]
    |> List.sort String.compare
  in
  let is_channel_hash hash = List.exists (Hash.equal hash) channel_hashes in
  List.iter
    (fun world ->
      (match world.Exhaustive_schedule.result with
      | Ok value ->
          Alcotest.(check string)
            "every exhaustive Channel world completes the rendezvous" "(ok(7), done(ok(())))"
            (Value.show value)
      | Error error ->
          Alcotest.failf "exhaustive Channel world failed: %s" (Runtime_err.to_string error));
      let channel_decisions =
        world.schedule.events
        |> List.filter_map (function
          | Schedule_trace.Decide { operation = Schedule_trace.Routed hash; _ }
            when is_channel_hash hash ->
              Some hash
          | Schedule_trace.Create _ | Schedule_trace.Decide _ -> None)
      in
      Alcotest.(check (list string))
        "every exhaustive world executes exactly one open, send, and recv" required_channel_hashes
        (channel_decisions |> List.map Hash.to_hex |> List.sort String.compare);
      match
        Round_robin.run_expr_outcome_scheduled ctx ~policy:Concurrency_contract.Collect
          ~allow_routed:false ~mode:(Round_robin.Replay_schedule world.schedule)
          (expression channel_rendezvous)
      with
      | Error error ->
          Alcotest.failf "strict Channel world replay failed: %s" (Runtime_err.to_string error)
      | Ok replayed ->
          Alcotest.(check string)
            "every exhaustive Channel trace strictly replays byte-for-byte"
            (Schedule_trace.serialize world.schedule)
            (Schedule_trace.serialize replayed.execution_schedule))
    channels.worlds

let test_warp_case_exact_count_and_replay () =
  let warp_case =
    "(app (var test.run)   (lam ()     (let nonrec (pwild) (app (var async.spawn) (lam () (lit \
     1)))       (app (var check.true) (var true) (lit \"parent assertion\")))))"
  in
  let expr = expression warp_case in
  let report =
    match Exhaustive_schedule.run_expr ctx ~policy:Concurrency_contract.Collect expr with
    | Ok report -> report
    | Error diagnostics -> Eval_support.fail_diags "enumerate Warp Case" diagnostics
  in
  require_complete 2 report;
  List.iter
    (fun world ->
      (match world.Exhaustive_schedule.result with
      | Ok value ->
          Alcotest.(check string)
            "every schedule passes the same Warp assertion"
            "mk-report(cons((\"parent assertion\", true), nil), none)" (Value.show value)
      | Error error -> Alcotest.failf "Warp schedule failed: %s" (Runtime_err.to_string error));
      match
        Round_robin.run_expr_outcome_scheduled ctx ~policy:Concurrency_contract.Collect
          ~allow_routed:false ~mode:(Round_robin.Replay_schedule world.schedule) expr
      with
      | Error error -> Alcotest.failf "strict replay failed: %s" (Runtime_err.to_string error)
      | Ok replayed ->
          Alcotest.(check string)
            "each exhaustive world is byte-replayable"
            (Schedule_trace.serialize world.schedule)
            (Schedule_trace.serialize replayed.execution_schedule))
    report.worlds

let test_schedule_sensitive_failure_is_found () =
  let source =
    "(let nonrec (pwild) (app (var async.spawn) (lam () (app (lit 1))))   (let nonrec (pwild)     \
     (app (var async.spawn) (lam () (app (var div) (lit 1) (lit 0))))     (lit 0)))"
  in
  let report = run ~policy:Concurrency_contract.Fail_fast source in
  require_complete 8 report;
  let errors =
    report.worlds
    |> List.filter_map (fun world ->
        match world.Exhaustive_schedule.result with
        | Ok _ -> None
        | Error error -> Some (Runtime_err.to_string error))
    |> List.sort_uniq String.compare
  in
  Alcotest.(check int) "both scheduler-sensitive first failures are found" 2 (List.length errors);
  Alcotest.(check bool)
    "application failure found" true
    (List.exists (fun error -> contains error "type error:") errors);
  Alcotest.(check bool)
    "arithmetic failure found" true
    (List.exists (fun error -> contains error "arithmetic error:") errors)

let has_reason predicate = function
  | Exhaustive_schedule.Complete -> false
  | Incomplete reasons -> List.exists predicate reasons

let test_budgets_are_structured_incomplete_results () =
  let world_limited =
    run
      ~bounds:{ Exhaustive_schedule.max_tasks = 8; max_decisions = 32; max_worlds = 1 }
      one_immediate
  in
  Alcotest.(check int) "one world was explored exactly" 1 world_limited.explored;
  Alcotest.(check int) "one world was started exactly" 1 world_limited.worlds_started;
  Alcotest.(check bool)
    "world exhaustion is incomplete" true
    (has_reason
       (function Exhaustive_schedule.World_budget { limit = 1 } -> true | _ -> false)
       world_limited.completeness);
  let decision_limited =
    run
      ~bounds:{ Exhaustive_schedule.max_tasks = 8; max_decisions = 2; max_worlds = 8 }
      one_immediate
  in
  Alcotest.(check int) "no bounded decision prefix is called a world" 0 decision_limited.explored;
  Alcotest.(check bool)
    "decision exhaustion is incomplete" true
    (has_reason
       (function Exhaustive_schedule.Decision_budget { limit = 2 } -> true | _ -> false)
       decision_limited.completeness);
  let task_limited =
    run
      ~bounds:{ Exhaustive_schedule.max_tasks = 1; max_decisions = 8; max_worlds = 8 }
      one_immediate
  in
  Alcotest.(check int) "no over-task prefix is called a world" 0 task_limited.explored;
  Alcotest.(check bool)
    "task exhaustion is incomplete" true
    (has_reason
       (function Exhaustive_schedule.Task_budget { limit = 1 } -> true | _ -> false)
       task_limited.completeness);
  match
    Exhaustive_schedule.run_expr ctx
      ~bounds:{ Exhaustive_schedule.max_tasks = 0; max_decisions = 0; max_worlds = 0 }
      (expression one_immediate)
  with
  | Error diagnostics ->
      Alcotest.(check int) "all non-positive budgets are diagnosed" 3 (List.length diagnostics);
      Alcotest.(check bool)
        "budget validation uses the scheduler diagnostic family" true
        (List.for_all
           (fun diagnostic -> String.equal (Diag.code_or_uncoded diagnostic) "E0908")
           diagnostics)
  | Ok _ -> Alcotest.fail "non-positive exhaustive budgets were accepted"

let test_decision_budget_keeps_short_alternative_worlds () =
  let source =
    "(let nonrec (pwild)     (app (var async.spawn)       (lam ()         (let nonrec (pwild)  \
     (app (var async.yield))           (let nonrec (pwild) (app (var async.yield)) (lit 1)))))  \
     (let nonrec (pwild)       (app (var async.spawn) (lam () (app (var div) (lit 1) (lit 0))))  \
     (lit 0)))"
  in
  let full = run ~policy:Concurrency_contract.Fail_fast source in
  require_complete 36 full;
  let decision_count world =
    world.Exhaustive_schedule.schedule.events
    |> List.filter_map (function
      | Schedule_trace.Decide decision -> Some decision
      | Create _ -> None)
    |> List.length
  in
  (match full.worlds with
  | fifo :: _ ->
      Alcotest.(check int) "FIFO seed is the long seven-decision world" 7 (decision_count fifo)
  | [] -> Alcotest.fail "complete uneven schedule tree was empty");
  let bounded =
    run ~policy:Concurrency_contract.Fail_fast
      ~bounds:{ Exhaustive_schedule.max_tasks = 8; max_decisions = 5; max_worlds = 1_000 }
      source
  in
  Alcotest.(check int) "three short alternatives survive the long FIFO refusal" 3 bounded.explored;
  Alcotest.(check bool)
    "every retained world fits the exact decision bound" true
    (List.for_all (fun world -> decision_count world = 5) bounded.worlds);
  Alcotest.(check int)
    "the three bounded traces are distinct" 3
    (bounded.worlds |> List.map trace_key |> List.sort_uniq String.compare |> List.length);
  Alcotest.(check bool)
    "the omitted long schedules keep the report incomplete" true
    (has_reason
       (function Exhaustive_schedule.Decision_budget { limit = 5 } -> true | _ -> false)
       bounded.completeness)

let test_task_budget_keeps_nonallocating_alternative_worlds () =
  let source =
    "(let nonrec (pwild)     (app (var async.spawn)       (lam ()         (let nonrec (pwild)  \
     (app (var async.spawn) (lam () (lit 9))) (lit 1))))     (let nonrec (pwild)       (app  (var \
     async.spawn) (lam () (app (var div) (lit 1) (lit 0))))       (lit 0)))"
  in
  let bounded =
    run ~policy:Concurrency_contract.Fail_fast
      ~bounds:{ Exhaustive_schedule.max_tasks = 3; max_decisions = 64; max_worlds = 1_000 }
      source
  in
  Alcotest.(check int)
    "three alternatives finish without allocating the fourth task" 3 bounded.explored;
  Alcotest.(check bool)
    "every retained world respects the exact task budget" true
    (List.for_all (fun world -> world.Exhaustive_schedule.outcome.task_count = 3) bounded.worlds);
  Alcotest.(check int)
    "the three task-bounded traces are distinct" 3
    (bounded.worlds |> List.map trace_key |> List.sort_uniq String.compare |> List.length);
  Alcotest.(check bool)
    "allocating branches keep the report incomplete" true
    (has_reason
       (function Exhaustive_schedule.Task_budget { limit = 3 } -> true | _ -> false)
       bounded.completeness)

let test_routed_world_effect_is_not_executed () =
  let store, world_ctx = Eval_support.make_prelude_ctx () in
  let output = Buffer.create 16 in
  (match Prelude.install_console world_ctx ~out:(Buffer.add_string output) with
  | Ok () -> ()
  | Error diagnostics -> Eval_support.fail_diags "install hostile console" diagnostics);
  let expr =
    match Reader.parse_one ~file:"non-hermetic.jqd" "(app (var print) (lit \"must-not-run\"))" with
    | Error diagnostics -> Eval_support.fail_diags "parse non-hermetic fixture" diagnostics
    | Ok form -> (
        match Kernel.expr_of_form form with
        | Error diagnostics -> Eval_support.fail_diags "validate non-hermetic fixture" diagnostics
        | Ok expr -> (
            match Resolve.resolve_expr (Store.names_view store) expr with
            | Ok expr -> expr
            | Error diagnostics ->
                Eval_support.fail_diags "resolve non-hermetic fixture" diagnostics))
  in
  let report =
    match Exhaustive_schedule.run_expr world_ctx expr with
    | Ok report -> report
    | Error diagnostics -> Eval_support.fail_diags "refuse non-hermetic exploration" diagnostics
  in
  Alcotest.(check string) "root callback was not invoked" "" (Buffer.contents output);
  Alcotest.(check int) "refused prefix is not a complete explored world" 0 report.explored;
  Alcotest.(check bool)
    "routed effect makes completeness explicit" true
    (has_reason
       (function Exhaustive_schedule.Routed_effect { decision = 0; _ } -> true | _ -> false)
       report.completeness)

let test_once_async_resumptions_are_world_local () =
  let report = run two_immediate in
  require_complete 8 report;
  List.iter
    (fun world ->
      match world.Exhaustive_schedule.result with
      | Error Runtime_err.Once_resumed_twice -> Alcotest.fail "an Async Once resume was duplicated"
      | Error error -> Alcotest.failf "unexpected world error: %s" (Runtime_err.to_string error)
      | Ok (Value.VInt 0) ->
          Alcotest.(check int)
            "every fresh world created exactly root plus two children" 3 world.outcome.task_count;
          Alcotest.(check bool)
            "every world drains affine ownership" true
            (world.outcome.metrics_after_close
            = Structured_scope.
                { open_scopes = 0; live_tasks = 0; runnable_tasks = 0; owned_resumes = 0 })
      | Ok value -> Alcotest.failf "unexpected world value: %s" (Value.show value))
    report.worlds

let suite =
  [
    Alcotest.test_case "hand-counted schedule trees" `Quick test_hand_counted_schedule_trees;
    Alcotest.test_case "Warp exact count and replay" `Quick test_warp_case_exact_count_and_replay;
    Alcotest.test_case "schedule-sensitive failure" `Quick test_schedule_sensitive_failure_is_found;
    Alcotest.test_case "structured incomplete budgets" `Quick
      test_budgets_are_structured_incomplete_results;
    Alcotest.test_case "decision budget keeps short alternatives" `Quick
      test_decision_budget_keeps_short_alternative_worlds;
    Alcotest.test_case "task budget keeps nonallocating alternatives" `Quick
      test_task_budget_keeps_nonallocating_alternative_worlds;
    Alcotest.test_case "hermetic routed-effect refusal" `Quick
      test_routed_world_effect_is_not_executed;
    Alcotest.test_case "Once resumptions stay world-local" `Quick
      test_once_async_resumptions_are_world_local;
  ]
