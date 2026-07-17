open Jacquard

let ok = function
  | Ok value -> value
  | Error error -> Alcotest.failf "unexpected scheduler error: %s" (Runtime_err.to_string error)

let contains text ~substring =
  let text_length = String.length text in
  let substring_length = String.length substring in
  let rec loop offset =
    offset + substring_length <= text_length
    && (String.sub text offset substring_length = substring || loop (offset + 1))
  in
  loop 0

let expression store source =
  match Reader.parse_one ~file:"round-robin.jqd" source with
  | Error diagnostics -> Eval_support.fail_diags "parse round-robin fixture" diagnostics
  | Ok form -> (
      match Kernel.expr_of_form form with
      | Error diagnostics -> Eval_support.fail_diags "validate round-robin fixture" diagnostics
      | Ok expression -> (
          match Resolve.resolve_expr (Store.names_view store) expression with
          | Ok expression -> expression
          | Error diagnostics -> Eval_support.fail_diags "resolve round-robin fixture" diagnostics))

let mixed_source =
  "(let nonrec (pvar first)\n\
  \   (app (var async.spawn)\n\
  \     (lam ()\n\
  \       (let nonrec (pwild) (app (var async.yield))\n\
  \         (let nonrec (pwild) (app (var async.yield)) (lit 10)))))\n\
  \   (let nonrec (pvar second)\n\
  \     (app (var async.spawn)\n\
  \       (lam ()\n\
  \         (let nonrec (pwild) (app (var async.yield))\n\
  \           (let nonrec (pwild) (app (var async.yield))\n\
  \             (let nonrec (pwild) (app (var async.yield)) (lit 20))))))\n\
  \     (let nonrec (pvar first-result) (app (var async.await) (var first))\n\
  \       (let nonrec (pwild) (app (var async.cancel) (var second))\n\
  \         (lit 99)))))"

let run_mixed () =
  let store, ctx = Eval_support.make_prelude_ctx () in
  let expr = expression store mixed_source in
  Round_robin.run_state ctx ~policy:Concurrency_contract.Collect (Eval.expr_state expr) |> ok

let result_text = function
  | Concurrency_contract.Done value -> "done(" ^ Value.show value ^ ")"
  | Concurrency_contract.Failed message -> "failed(" ^ message ^ ")"
  | Concurrency_contract.Cancelled -> "cancelled"

let foreign_task () = Value.VTask (Obj.magic (ref (), [ 0 ], 1))

let print_hash store =
  match Store.lookup_kind store "print" Resolve.KOp with
  | Some entry -> entry.hash
  | None -> Alcotest.fail "missing Console.print operation"

let test_real_eval_trace_and_cache () =
  let first = run_mixed () in
  let second = run_mixed () in
  Alcotest.(check string) "real Eval trace is exact" first.trace second.trace;
  Alcotest.(check bool) "real Eval decisions are exact" true (first.decisions = second.decisions);
  Alcotest.(check int) "three real evaluator tasks" 3 first.task_count;
  Alcotest.(check int) "bounded live high-water" 3 first.max_live;
  Alcotest.(check bool)
    "zero recursive ownership after close" true
    (first.metrics_after_close
    = Structured_scope.{ open_scopes = 0; live_tasks = 0; runnable_tasks = 0; owned_resumes = 0 });
  let store, ctx = Eval_support.make_prelude_ctx () in
  let expr = expression store mixed_source in
  let cache = Round_robin.create_cache () in
  let _, miss =
    Round_robin.run_expr_cached cache ctx ~policy:Concurrency_contract.Collect expr |> ok
  in
  let _, hit =
    Round_robin.run_expr_cached cache ctx ~policy:Concurrency_contract.Collect expr |> ok
  in
  let _, changed_bounds =
    Round_robin.run_expr_cached cache ctx ~policy:Concurrency_contract.Collect
      ~bounds:{ Round_robin.max_tasks = 4; max_decisions = 100_000 }
      expr
    |> ok
  in
  let _, changed_decision_bound =
    Round_robin.run_expr_cached cache ctx ~policy:Concurrency_contract.Collect
      ~bounds:{ Round_robin.max_tasks = 1024; max_decisions = 99_999 }
      expr
    |> ok
  in
  let _, changed_policy =
    Round_robin.run_expr_cached cache ctx ~policy:Concurrency_contract.Fail_fast expr |> ok
  in
  let changed_program = expression store "(lit 100)" in
  let _, changed_program =
    Round_robin.run_expr_cached cache ctx ~policy:Concurrency_contract.Collect changed_program |> ok
  in
  Alcotest.(check bool) "first proof misses" true (miss = Round_robin.Miss);
  Alcotest.(check bool) "exact identity hits" true (hit = Round_robin.Hit);
  Alcotest.(check bool) "bounds participate in identity" true (changed_bounds = Round_robin.Miss);
  Alcotest.(check bool)
    "max_decisions participates in identity" true
    (changed_decision_bound = Round_robin.Miss);
  Alcotest.(check bool) "policy participates in identity" true (changed_policy = Round_robin.Miss);
  Alcotest.(check bool)
    "canonical program hash participates in identity" true
    (changed_program = Round_robin.Miss)

let test_fresh_run_identity_and_routed_resume_guard () =
  let store, ctx = Eval_support.make_prelude_ctx () in
  let retained = ref None in
  Eval.register_root_handler ctx (print_hash store) (fun args ->
      (retained := match args with value :: _ -> Some value | [] -> None);
      Ok Value.unit_v);
  let retain_task =
    expression store
      "(let nonrec (pvar child) (app (var async.spawn) (lam () (lit 7)))\n\
      \   (app (var print) (var child)))"
  in
  ignore
    (Round_robin.run_state ctx ~policy:Concurrency_contract.Collect (Eval.expr_state retain_task)
    |> ok);
  let stale = Option.get !retained in
  let second = Round_robin.run_state ctx (Eval.SApply (stale, [])) |> ok in
  (match second.root_error with
  | Some (Runtime_err.Invalid_task_handle _) -> ()
  | Some error ->
      Alcotest.failf "same-context stale Task returned the wrong error: %s"
        (Runtime_err.to_string error)
  | None -> Alcotest.fail "a Task retained from the prior scheduler run was accepted");
  let cell = ref Value.unit_v in
  let hostile_scope = Value.{ empty_scope with env = Env.add "hidden" cell empty_scope.env } in
  Eval.register_root_handler ctx (print_hash store) (fun _ ->
      cell := foreign_task ();
      Ok Value.unit_v);
  let perform = expression store "(app (var print) (lit \"guard\"))" in
  let state =
    Eval.SEval
      ( hostile_scope,
        perform,
        [ Value.FTuple { done_rev = []; pending = []; scope = hostile_scope } ] )
  in
  match Eval.run_state_capturing_once_routed ctx state with
  | Error error -> Alcotest.failf "capture failed: %s" (Runtime_err.to_string error)
  | Ok (Eval.OCValue value) ->
      Alcotest.failf "routed Console operation unexpectedly returned %s" (Value.show value)
  | Ok (Eval.OCOp { op; name; args; resume }) -> (
      match Eval.dispatch_root_operation ctx ~resume ~op ~name ~effect_:"Console" args with
      | Error (Runtime_err.Invalid_task_handle _) -> ()
      | Error error ->
          Alcotest.failf "hostile resume mutation returned the wrong error: %s"
            (Runtime_err.to_string error)
      | Ok value ->
          Alcotest.failf "hostile root handler mutated a suspended Once resume: %s"
            (Value.show value))

let test_real_failure_policies_and_linked_terminal_ordinals () =
  let store, ctx = Eval_support.make_prelude_ctx () in
  let failing_children =
    expression store
      "(let nonrec (pvar bad)\n\
      \   (app (var async.spawn) (lam () (app (lit 1))))\n\
      \   (let nonrec (pvar good) (app (var async.spawn) (lam () (lit 7)))\n\
      \     (tuple (app (var async.await) (var bad))\n\
      \       (app (var async.await) (var good)))))"
  in
  let collect =
    Round_robin.run_state ctx ~policy:Concurrency_contract.Collect
      (Eval.expr_state failing_children)
    |> ok
  in
  (match collect.aggregate with
  | Scope_policy.Collect_result
      [ Concurrency_contract.Failed _; Concurrency_contract.Done (Value.VInt 7) ] ->
      ()
  | _ -> Alcotest.fail "collect did not retain the real failing and successful child results");
  let fail_fast =
    Round_robin.run_state ctx ~policy:Concurrency_contract.Fail_fast
      (Eval.expr_state failing_children)
    |> ok
  in
  (match fail_fast.aggregate with
  | Scope_policy.Fail_fast_result (Concurrency_contract.Failed _) -> ()
  | _ -> Alcotest.fail "fail-fast did not select the real failing child");
  let simultaneous =
    expression store
      "(let nonrec (pvar target)\n\
      \   (app (var async.spawn)\n\
      \     (lam ()\n\
      \       (let nonrec (pwild) (app (var async.yield))\n\
      \         (let nonrec (pwild) (app (var async.yield))\n\
      \           (let nonrec (pwild) (app (var async.yield)) (lit 7))))))\n\
      \   (let nonrec (pwild)\n\
      \     (app (var async.spawn) (lam () (app (var async.await) (var target))))\n\
      \     (let nonrec (pwild)\n\
      \       (app (var async.spawn) (lam () (app (lit 1))))\n\
      \       (lit 0))))"
  in
  let linked = Round_robin.run_state ctx (Eval.expr_state simultaneous) |> ok in
  Alcotest.(check bool)
    "one scheduler decision links a stable second terminal observation" true
    (linked.trace |> String.split_on_char '\n'
    |> List.exists (fun line ->
        String.starts_with ~prefix:"policy-observe decision=" line
        && String.ends_with ~suffix:"ordinal=1 task=0#2" line))

let test_fail_fast_requeues_awakened_waiter () =
  let store, ctx = Eval_support.make_prelude_ctx () in
  let output = Buffer.create 16 in
  (match Prelude.install_console ctx ~out:(Buffer.add_string output) with
  | Ok () -> ()
  | Error diagnostics -> Eval_support.fail_diags "install console" diagnostics);
  let source =
    "(let nonrec (pvar blocker)\n\
    \   (app (var async.spawn)\n\
    \     (lam ()\n\
    \       (let nonrec (pwild) (app (var async.yield))\n\
    \         (let nonrec (pwild) (app (var async.yield))\n\
    \           (let nonrec (pwild) (app (var async.yield))\n\
    \             (let nonrec (pwild) (app (var async.yield)) (lit 1)))))))\n\
    \   (let nonrec (pvar target)\n\
    \     (app (var async.spawn) (lam () (app (var async.await) (var blocker))))\n\
    \     (let nonrec (pvar waiter)\n\
    \       (app (var async.spawn)\n\
    \         (lam ()\n\
    \           (let nonrec (pwild) (app (var async.await) (var target))\n\
    \             (app (var print) (lit \"must-not-run\")))))\n\
    \       (let nonrec (pwild) (app (var async.spawn) (lam () (app (lit 1))))\n\
    \         (lit 0)))))"
  in
  let outcome =
    Round_robin.run_state ctx ~policy:Concurrency_contract.Fail_fast
      (Eval.expr_state (expression store source))
    |> ok
  in
  (match outcome.aggregate with
  | Scope_policy.Fail_fast_result (Concurrency_contract.Failed _) -> ()
  | _ -> Alcotest.fail "fail-fast did not retain the triggering child failure");
  Alcotest.(check bool)
    "waiter awakened by sibling cancellation is returned to the global queue" true
    (contains outcome.trace ~substring:"runnable=[0#0,0#1,0#3]");
  Alcotest.(check bool)
    "awakened waiter observes its pending cancellation" true
    (contains outcome.trace ~substring:"terminal task=0#3 result=cancelled");
  Alcotest.(check string)
    "cancelled awakened waiter performs no later world work" "" (Buffer.contents output);
  Alcotest.(check bool)
    "fail-fast waiter path closes all ownership" true
    (outcome.metrics_after_close
    = Structured_scope.{ open_scopes = 0; live_tasks = 0; runnable_tasks = 0; owned_resumes = 0 })

let test_real_eval_self_await_deadlock () =
  let store, ctx = Eval_support.make_prelude_ctx () in
  let retained = ref None in
  Eval.register_root_handler ctx (print_hash store) (fun args ->
      match (!retained, args) with
      | None, [ task ] ->
          retained := Some task;
          Ok Value.unit_v
      | Some task, [ _ ] -> Ok task
      | _, _ -> Error (Runtime_err.Arity "test print handler expects one argument"));
  let source =
    "(let nonrec (pvar child)\n\
    \   (app (var async.spawn)\n\
    \     (lam ()\n\
    \       (let nonrec (pwild) (app (var async.yield))\n\
    \         (let nonrec (pvar self) (app (var print) (lit \"self\"))\n\
    \           (app (var async.await) (var self))))))\n\
    \   (let nonrec (pwild) (app (var print) (var child))\n\
    \     (app (var async.await) (var child))))"
  in
  let outcome = Round_robin.run_state ctx (Eval.expr_state (expression store source)) |> ok in
  let message = "async deadlock: task 0#1 awaited itself" in
  if not (contains outcome.trace ~substring:("deadlock=" ^ Printf.sprintf "%S" message)) then
    Alcotest.failf "real evaluator missed self-await deadlock:\n%s" outcome.trace;
  (match outcome.aggregate with
  | Scope_policy.Fail_fast_result (Concurrency_contract.Failed actual)
    when String.equal actual message ->
      ()
  | _ -> Alcotest.fail "self-await deadlock did not become the frozen fail-fast result");
  Alcotest.(check bool)
    "deadlock refusal closes all ownership" true
    (outcome.metrics_after_close
    = Structured_scope.{ open_scopes = 0; live_tasks = 0; runnable_tasks = 0; owned_resumes = 0 })

let test_multiple_waiters_nested_escape_and_bounds () =
  let store, ctx = Eval_support.make_prelude_ctx () in
  let multiple =
    expression store
      "(let nonrec (pvar target)\n\
      \   (app (var async.spawn)\n\
      \     (lam () (let nonrec (pwild) (app (var async.yield)) (lit 7))))\n\
      \   (let nonrec (pvar left)\n\
      \     (app (var async.spawn) (lam () (app (var async.await) (var target))))\n\
      \     (let nonrec (pvar right)\n\
      \       (app (var async.spawn) (lam () (app (var async.await) (var target))))\n\
      \       (tuple (app (var async.await) (var left))\n\
      \         (app (var async.await) (var right))))))"
  in
  let outcome =
    Round_robin.run_state ctx ~policy:Concurrency_contract.Collect (Eval.expr_state multiple) |> ok
  in
  Alcotest.(check string)
    "registration-ordered waiters receive the immutable result"
    "done((done(done(7)), done(done(7))))" (result_text outcome.body);
  let nested =
    expression store
      "(app (var async.scope)\n\
      \   (lam ()\n\
      \     (let nonrec (pvar child) (app (var async.spawn) (lam () (lit 42)))\n\
      \       (app (var async.await) (var child)))))"
  in
  Alcotest.(check string)
    "nested scope result" "done(done(42))"
    (Value.show (Round_robin.run_expr ctx nested |> ok));
  let escaping = expression store "(app (var async.spawn) (lam () (lit 1)))" in
  (match Round_robin.run_state ctx (Eval.expr_state escaping) with
  | Error (Runtime_err.Invalid_task_handle message) ->
      Alcotest.(check bool)
        "escape retains the frozen message" true
        (String.starts_with ~prefix:Concurrency_contract.task_escape_message message)
  | Error error -> Alcotest.failf "wrong escape error: %s" (Runtime_err.to_string error)
  | Ok _ -> Alcotest.fail "Task escaped the integrated scope");
  let over_bound =
    expression store
      "(let nonrec (pwild) (app (var async.spawn) (lam () (tuple)))\n\
      \   (app (var async.spawn) (lam () (tuple))))"
  in
  (match Round_robin.run_expr ctx ~bounds:{ max_tasks = 2; max_decisions = 100 } over_bound with
  | Error (Runtime_err.Scheduler_error message) ->
      Alcotest.(check bool)
        "task bound reports exact refusal" true
        (String.ends_with ~suffix:"task bound 2 exceeded" message)
  | Error error -> Alcotest.failf "wrong bound error: %s" (Runtime_err.to_string error)
  | Ok _ -> Alcotest.fail "task bound was not enforced");
  let store, ctx = Eval_support.make_prelude_ctx () in
  let output = Buffer.create 16 in
  (match Prelude.install_console ctx ~out:(Buffer.add_string output) with
  | Ok () -> ()
  | Error diagnostics -> Eval_support.fail_diags "install console" diagnostics);
  let cancelled_before_routed_print =
    expression store
      "(let nonrec (pvar target)\n\
      \   (app (var async.spawn)\n\
      \     (lam ()\n\
      \       (let nonrec (pwild) (app (var async.yield))\n\
      \         (app (var print) (lit \"must-not-run\")))))\n\
      \   (let nonrec (pwild) (app (var async.cancel) (var target))\n\
      \     (app (var async.await) (var target))))"
  in
  Alcotest.(check string)
    "cancelled child reports its immutable result" "cancelled"
    (Value.show
       (Round_robin.run_expr ctx ~policy:Concurrency_contract.Collect cancelled_before_routed_print
       |> ok));
  Alcotest.(check string)
    "cancellation is delivered before the routed world operation" "" (Buffer.contents output)

let test_global_nested_fifo_and_bounds () =
  let store, ctx = Eval_support.make_prelude_ctx () in
  let interleaved =
    expression store
      "(let nonrec (pwild)\n\
      \   (app (var async.spawn)\n\
      \     (lam () (let nonrec (pwild) (app (var async.yield)) (lit 9))))\n\
      \   (app (var async.scope)\n\
      \     (lam () (let nonrec (pwild) (app (var async.yield)) (lit 42)))))"
  in
  let outcome = Round_robin.run_state ctx (Eval.expr_state interleaved) |> ok in
  let expected_trace =
    String.concat "\n"
      [
        "decision=0 runnable=[0#0] chosen=0#0";
        "spawn parent=0#0 child=0#1";
        "decision=1 runnable=[0#1,0#0] chosen=0#1";
        "yield task=0#1";
        "decision=2 runnable=[0#0,0#1] chosen=0#0";
        "scope-open parent=0 child=0/1";
        "decision=3 runnable=[0#1,0/1#0] chosen=0#1";
        "terminal task=0#1 result=done(9)";
        "policy-observe decision=3 ordinal=0 task=0#1";
        "decision=4 runnable=[0/1#0] chosen=0/1#0";
        "yield task=0/1#0";
        "decision=5 runnable=[0/1#0] chosen=0/1#0";
        "terminal task=0/1#0 result=done(42)";
        "scope-complete path=0/1 result=done(42)";
        "decision=6 runnable=[0#0] chosen=0#0";
        "terminal task=0#0 result=done(done(42))";
        "";
      ]
  in
  Alcotest.(check string)
    "outer sibling and nested body share one exact FIFO" expected_trace outcome.trace;
  Alcotest.(check int) "nested body participates in global task count" 3 outcome.task_count;
  Alcotest.(check int) "nested body participates in global live high-water" 3 outcome.max_live;
  let over_task_bound =
    expression store
      "(let nonrec (pwild) (app (var async.spawn) (lam () (lit 9)))\n\
      \   (app (var async.scope)\n\
      \     (lam ()\n\
      \       (let nonrec (pvar child) (app (var async.spawn) (lam () (lit 42)))\n\
      \         (app (var async.await) (var child))))))"
  in
  (match
     Round_robin.run_expr ctx ~bounds:{ max_tasks = 3; max_decisions = 100 } over_task_bound
   with
  | Error (Runtime_err.Scheduler_error message) ->
      Alcotest.(check bool)
        "nested allocation uses the global task bound" true
        (String.ends_with ~suffix:"task bound 3 exceeded" message)
  | Error error -> Alcotest.failf "wrong nested task-bound error: %s" (Runtime_err.to_string error)
  | Ok value -> Alcotest.failf "nested task bound was not global: %s" (Value.show value));
  match Round_robin.run_expr ctx ~bounds:{ max_tasks = 10; max_decisions = 6 } interleaved with
  | Error (Runtime_err.Scheduler_error message) ->
      Alcotest.(check string)
        "nested scheduling uses the global decision bound" "decision bound exceeded" message
  | Error error ->
      Alcotest.failf "wrong nested decision-bound error: %s" (Runtime_err.to_string error)
  | Ok value -> Alcotest.failf "nested decision bound was not global: %s" (Value.show value)

let prop_128_exact_real_eval_traces =
  let expected = (run_mixed ()).trace in
  QCheck.Test.make ~count:128 ~name:"128 real Eval schedules retain the exact FIFO trace" QCheck.int
    (fun seed ->
      Random.init seed;
      let outcome = run_mixed () in
      String.equal expected outcome.trace && outcome.task_count = 3 && outcome.max_live = 3)

let run () =
  test_real_eval_trace_and_cache ();
  test_fresh_run_identity_and_routed_resume_guard ();
  test_real_failure_policies_and_linked_terminal_ordinals ();
  test_fail_fast_requeues_awakened_waiter ();
  test_real_eval_self_await_deadlock ();
  test_multiple_waiters_nested_escape_and_bounds ();
  test_global_nested_fifo_and_bounds ();
  QCheck.Test.check_exn prop_128_exact_real_eval_traces

let suite = [ Alcotest.test_case "real evaluator FIFO lifecycle" `Quick run ]
