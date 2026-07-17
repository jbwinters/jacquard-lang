open Jacquard

let ok = function
  | Ok value -> value
  | Error diagnostics ->
      Alcotest.failf "unexpected scope-policy diagnostic: %s"
        (String.concat "\n" (List.map Diag.to_string diagnostics))

let error_text = function
  | Error [ diagnostic ] -> Diag.to_string diagnostic
  | Error diagnostics ->
      Alcotest.failf "expected one scope-policy diagnostic, got %d" (List.length diagnostics)
  | Ok _ -> Alcotest.fail "scope-policy operation unexpectedly succeeded"

let trace scope task = Structured_scope.id scope task |> ok |> Concurrency_contract.trace_task_id

let finish_done scope child value =
  ignore (Structured_scope.checkout scope child |> ok);
  ignore (Structured_scope.complete scope child value |> ok)

let finish_failed scope child message =
  ignore (Structured_scope.checkout scope child |> ok);
  ignore (Structured_scope.fail scope child message |> ok)

let finish_cancelled scope child ~resume ~drop =
  ignore (Structured_scope.checkout scope child |> ok);
  Structured_scope.request_cancel scope child |> ok;
  match Structured_scope.yield_cooperatively scope ~task:child ~resume ~drop |> ok with
  | Structured_scope.Yield_cancelled _ -> ()
  | Structured_scope.Yield_suspended -> Alcotest.fail "requested cancellation suspended"

let close scope =
  Structured_scope.close scope ~reason:Structured_scope.Normal ~escaping:[] ~drop:ignore |> ok

let test_zero_and_one_default () =
  let empty_scope, _ = Structured_scope.create ~body_resume:0 |> ok in
  let empty = Scope_policy.create empty_scope ~children:[] |> ok in
  Alcotest.(check bool)
    "fail-fast is the default" true
    (Scope_policy.policy empty = Concurrency_contract.Fail_fast);
  Alcotest.(check bool)
    "zero fail-fast succeeds with no values" true
    (Scope_policy.finish empty = Ok (Scope_policy.Fail_fast_result (Concurrency_contract.Done [])));
  let collect =
    Scope_policy.create ~policy:Concurrency_contract.Collect empty_scope ~children:[] |> ok
  in
  Alcotest.(check bool)
    "zero collect succeeds with no results" true
    (Scope_policy.finish collect = Ok (Scope_policy.Collect_result []));
  close empty_scope;
  let scope, _ = Structured_scope.create ~body_resume:10 |> ok in
  let child = Structured_scope.spawn scope ~resume:11 |> ok in
  let policy = Scope_policy.create scope ~children:[ child ] |> ok in
  finish_done scope child 42;
  Scope_policy.record_terminal policy ~decision:0 child ~drop:ignore |> ok;
  Alcotest.(check bool)
    "one success" true
    (Scope_policy.finish policy
   = Ok (Scope_policy.Fail_fast_result (Concurrency_contract.Done [ 42 ])));
  close scope

let test_fail_fast_cancels_in_input_order () =
  let scope, _ = Structured_scope.create ~body_resume:0 |> ok in
  let first = Structured_scope.spawn scope ~resume:1 |> ok in
  let second = Structured_scope.spawn scope ~resume:2 |> ok in
  let third = Structured_scope.spawn scope ~resume:3 |> ok in
  let policy = Scope_policy.create scope ~children:[ first; second; third ] |> ok in
  ignore (Structured_scope.checkout scope second |> ok);
  Structured_scope.suspend_yield scope second ~resume:21 |> ok;
  ignore (Structured_scope.checkout scope third |> ok);
  Structured_scope.suspend_yield scope third ~resume:31 |> ok;
  finish_failed scope first "first failure";
  let dropped = ref [] in
  Scope_policy.record_terminal policy ~decision:4 first ~drop:(fun resume ->
      dropped := !dropped @ [ resume ])
  |> ok;
  Alcotest.(check (list int)) "sibling cancellation follows input order" [ 21; 31 ] !dropped;
  Scope_policy.record_terminal policy ~decision:5 second ~drop:ignore |> ok;
  Scope_policy.record_terminal policy ~decision:6 third ~drop:ignore |> ok;
  Alcotest.(check bool)
    "first failure has no partial results" true
    (Scope_policy.finish policy
   = Ok (Scope_policy.Fail_fast_result (Concurrency_contract.Failed "first failure")));
  close scope

let test_fail_fast_retains_awakened_waiters () =
  let scope, _ = Structured_scope.create ~body_resume:0 |> ok in
  let failed = Structured_scope.spawn scope ~resume:1 |> ok in
  let target = Structured_scope.spawn scope ~resume:2 |> ok in
  let first_waiter = Structured_scope.spawn scope ~resume:3 |> ok in
  let second_waiter = Structured_scope.spawn scope ~resume:4 |> ok in
  let policy = Scope_policy.create scope ~children:[ failed; target ] |> ok in
  ignore (Structured_scope.checkout scope target |> ok);
  Structured_scope.suspend_yield scope target ~resume:21 |> ok;
  ignore (Structured_scope.checkout scope first_waiter |> ok);
  (match Structured_scope.await scope ~waiter:first_waiter ~target ~resume:31 |> ok with
  | Scheduler_core.Await_suspended, [] -> ()
  | _ -> Alcotest.fail "first policy waiter did not suspend");
  ignore (Structured_scope.checkout scope second_waiter |> ok);
  (match Structured_scope.await scope ~waiter:second_waiter ~target ~resume:41 |> ok with
  | Scheduler_core.Await_suspended, [] -> ()
  | _ -> Alcotest.fail "second policy waiter did not suspend");
  finish_failed scope failed "wake waiters";
  let dropped = ref [] in
  Scope_policy.record_terminal policy ~decision:0 failed ~drop:(fun resume ->
      dropped := resume :: !dropped)
  |> ok;
  let awakened = Scope_policy.take_awakened policy in
  Alcotest.(check (list string))
    "fail-fast retains waiter registration order"
    [ trace scope first_waiter; trace scope second_waiter ]
    (List.map (trace scope) awakened);
  Alcotest.(check (list int)) "cancelled target resume was destroyed" [ 21 ] !dropped;
  List.iter
    (fun waiter ->
      let waiter_view = Structured_scope.inspect scope waiter |> ok in
      Alcotest.(check bool)
        "retained waiter is runnable with its resume" true
        (waiter_view.lifecycle = Concurrency_contract.Runnable && waiter_view.owns_resume))
    awakened;
  Alcotest.(check int)
    "awakened handoff drains exactly once" 0
    (List.length (Scope_policy.take_awakened policy));
  Scope_policy.record_terminal policy ~decision:1 target ~drop:ignore |> ok;
  close scope

let test_fail_fast_retains_same_delivery_waiter_when_drop_raises () =
  let scope, _ = Structured_scope.create ~body_resume:0 |> ok in
  let failed = Structured_scope.spawn scope ~resume:1 |> ok in
  let target = Structured_scope.spawn scope ~resume:2 |> ok in
  let waiter = Structured_scope.spawn scope ~resume:3 |> ok in
  let policy = Scope_policy.create scope ~children:[ failed; target ] |> ok in
  ignore (Structured_scope.checkout scope target |> ok);
  Structured_scope.suspend_yield scope target ~resume:21 |> ok;
  ignore (Structured_scope.checkout scope waiter |> ok);
  (match Structured_scope.await scope ~waiter ~target ~resume:31 |> ok with
  | Scheduler_core.Await_suspended, [] -> ()
  | _ -> Alcotest.fail "same-delivery policy waiter did not suspend");
  finish_failed scope failed "wake waiter before raising";
  let dropped = ref [] in
  let drop_exception = Failure "same delivery drop failed" in
  let backtraces_were_enabled = Printexc.backtrace_status () in
  Printexc.record_backtrace true;
  Fun.protect
    ~finally:(fun () -> Printexc.record_backtrace backtraces_were_enabled)
    (fun () ->
      let drop_backtrace =
        match raise drop_exception with
        | exception caught when caught == drop_exception -> Printexc.get_raw_backtrace ()
        | _ -> Alcotest.fail "failed to capture the physical drop exception backtrace"
      in
      match
        Scope_policy.record_terminal policy ~decision:0 failed ~drop:(fun resume ->
            dropped := resume :: !dropped;
            Printexc.raise_with_backtrace drop_exception drop_backtrace)
      with
      | exception caught when caught == drop_exception ->
          let original = Printexc.raw_backtrace_to_string drop_backtrace in
          let reraised = Printexc.raw_backtrace_to_string (Printexc.get_raw_backtrace ()) in
          Alcotest.(check bool)
            "same-delivery drop keeps its original backtrace" true
            (String.starts_with ~prefix:original reraised)
      | exception exn ->
          Alcotest.failf "policy replaced the physical drop exception: %s" (Printexc.to_string exn)
      | Ok () | Error _ -> Alcotest.fail "policy swallowed the physical drop exception");
  Alcotest.(check (list int)) "raising drop receives the target resume once" [ 21 ] !dropped;
  let awakened = Scope_policy.take_awakened policy in
  Alcotest.(check (list string))
    "same-delivery waiter remains buffered"
    [ trace scope waiter ]
    (List.map (trace scope) awakened);
  let waiter_view = Structured_scope.inspect scope waiter |> ok in
  Alcotest.(check bool)
    "same-delivery waiter is runnable with its resume" true
    (waiter_view.lifecycle = Concurrency_contract.Runnable && waiter_view.owns_resume);
  Alcotest.(check int)
    "same-delivery handoff drains exactly once" 0
    (List.length (Scope_policy.take_awakened policy));
  let duplicate =
    Structured_scope.deliver_cancel scope ~point:Concurrency_contract.Yield target ~drop:(fun _ ->
        Alcotest.fail "duplicate cancellation repeated the drop")
    |> ok
  in
  Alcotest.(check int) "duplicate cancellation has no awakened handoff" 0 (List.length duplicate);
  Scope_policy.record_terminal policy ~decision:1 target ~drop:ignore |> ok;
  close scope

let test_collect_mixed_results_in_input_order () =
  let scope, _ = Structured_scope.create ~body_resume:0 |> ok in
  let failed = Structured_scope.spawn scope ~resume:1 |> ok in
  let cancelled = Structured_scope.spawn scope ~resume:2 |> ok in
  let done_ = Structured_scope.spawn scope ~resume:3 |> ok in
  let policy =
    Scope_policy.create ~policy:Concurrency_contract.Collect scope
      ~children:[ failed; cancelled; done_ ]
    |> ok
  in
  finish_failed scope failed "mixed failure";
  Scope_policy.record_terminal policy ~decision:0 failed ~drop:ignore |> ok;
  Alcotest.(check bool)
    "collect leaves unfinished siblings uncancelled" false
    (Structured_scope.inspect scope done_ |> ok).cancellation_requested;
  finish_done scope done_ 30;
  finish_cancelled scope cancelled ~resume:20 ~drop:ignore;
  Scope_policy.record_terminal policy ~decision:1 done_ ~drop:ignore |> ok;
  Scope_policy.record_terminal policy ~decision:2 cancelled ~drop:ignore |> ok;
  Alcotest.(check bool)
    "collect uses creation/input order, not terminal order" true
    (Scope_policy.finish policy
    = Ok
        (Scope_policy.Collect_result
           [
             Concurrency_contract.Failed "mixed failure";
             Concurrency_contract.Cancelled;
             Concurrency_contract.Done 30;
           ]));
  close scope

let test_scheduler_decision_selects_first_failure () =
  let scope, _ = Structured_scope.create ~body_resume:0 |> ok in
  let created_first = Structured_scope.spawn scope ~resume:1 |> ok in
  let decided_first = Structured_scope.spawn scope ~resume:2 |> ok in
  let policy = Scope_policy.create scope ~children:[ created_first; decided_first ] |> ok in
  finish_failed scope created_first "created-first";
  finish_failed scope decided_first "decision-first";
  Scope_policy.record_terminal policy ~decision:20 decided_first ~drop:ignore |> ok;
  Scope_policy.record_terminal policy ~decision:20 ~ordinal:1 created_first ~drop:ignore |> ok;
  Alcotest.(check bool)
    "decision order wins over creation order for simultaneous failures" true
    (Scope_policy.finish policy
   = Ok (Scope_policy.Fail_fast_result (Concurrency_contract.Failed "decision-first")));
  close scope

let test_nested_policies () =
  let root, _ = Structured_scope.create ~body_resume:0 |> ok in
  let root_child = Structured_scope.spawn root ~resume:1 |> ok in
  let nested, _ = Structured_scope.nest root ~body_resume:10 |> ok in
  let left = Structured_scope.spawn nested ~resume:11 |> ok in
  let right = Structured_scope.spawn nested ~resume:12 |> ok in
  let nested_policy =
    Scope_policy.create ~policy:Concurrency_contract.Collect nested ~children:[ left; right ] |> ok
  in
  finish_done nested right 2;
  finish_done nested left 1;
  Scope_policy.record_terminal nested_policy ~decision:0 right ~drop:ignore |> ok;
  Scope_policy.record_terminal nested_policy ~decision:1 left ~drop:ignore |> ok;
  Alcotest.(check bool)
    "nested collect remains input ordered" true
    (Scope_policy.finish nested_policy
    = Ok (Scope_policy.Collect_result [ Concurrency_contract.Done 1; Concurrency_contract.Done 2 ])
    );
  let root_policy = Scope_policy.create root ~children:[ root_child ] |> ok in
  finish_done root root_child 3;
  Scope_policy.record_terminal root_policy ~decision:0 root_child ~drop:ignore |> ok;
  Alcotest.(check bool)
    "enclosing default remains independent" true
    (Scope_policy.finish root_policy
   = Ok (Scope_policy.Fail_fast_result (Concurrency_contract.Done [ 3 ])));
  close root

let test_failure_during_cancellation_keeps_first_decision () =
  let scope, _ = Structured_scope.create ~body_resume:0 |> ok in
  let first = Structured_scope.spawn scope ~resume:1 |> ok in
  let late = Structured_scope.spawn scope ~resume:2 |> ok in
  let suspended = Structured_scope.spawn scope ~resume:3 |> ok in
  let policy = Scope_policy.create scope ~children:[ first; late; suspended ] |> ok in
  ignore (Structured_scope.checkout scope late |> ok);
  ignore (Structured_scope.checkout scope suspended |> ok);
  Structured_scope.suspend_yield scope suspended ~resume:31 |> ok;
  finish_failed scope first "decision-7";
  let dropped = ref [] in
  Scope_policy.record_terminal policy ~decision:7 first ~drop:(fun resume ->
      dropped := resume :: !dropped)
  |> ok;
  Alcotest.(check bool)
    "checked-out sibling has pending cancellation" true
    (Structured_scope.inspect scope late |> ok).cancellation_requested;
  ignore (Structured_scope.fail scope late "failed while cancellation pending" |> ok);
  Scope_policy.record_terminal policy ~decision:8 late ~drop:ignore |> ok;
  Scope_policy.record_terminal policy ~decision:9 suspended ~drop:ignore |> ok;
  Alcotest.(check (list int)) "suspended sibling destroyed" [ 31 ] !dropped;
  Alcotest.(check bool)
    "later failure cannot replace first scheduler decision" true
    (Scope_policy.finish policy
   = Ok (Scope_policy.Fail_fast_result (Concurrency_contract.Failed "decision-7")));
  close scope

let test_cancellation_before_failure_keeps_first_decision () =
  let scope, _ = Structured_scope.create ~body_resume:0 |> ok in
  let cancelled = Structured_scope.spawn scope ~resume:1 |> ok in
  let late = Structured_scope.spawn scope ~resume:2 |> ok in
  let policy = Scope_policy.create scope ~children:[ cancelled; late ] |> ok in
  ignore (Structured_scope.checkout scope late |> ok);
  finish_cancelled scope cancelled ~resume:11 ~drop:ignore;
  Scope_policy.record_terminal policy ~decision:7 cancelled ~drop:ignore |> ok;
  Alcotest.(check bool)
    "checked-out sibling has pending cancellation" true
    (Structured_scope.inspect scope late |> ok).cancellation_requested;
  ignore (Structured_scope.fail scope late "failed while cancellation pending" |> ok);
  Scope_policy.record_terminal policy ~decision:8 late ~drop:ignore |> ok;
  Alcotest.(check bool)
    "later failure cannot replace first cancellation" true
    (Scope_policy.finish policy = Ok (Scope_policy.Fail_fast_result Concurrency_contract.Cancelled));
  close scope

let test_cancellation_cleanup_survives_drop_failure () =
  let scope, _ = Structured_scope.create ~body_resume:0 |> ok in
  let first = Structured_scope.spawn scope ~resume:1 |> ok in
  let left = Structured_scope.spawn scope ~resume:2 |> ok in
  let right = Structured_scope.spawn scope ~resume:3 |> ok in
  let right_waiter = Structured_scope.spawn scope ~resume:4 |> ok in
  let policy = Scope_policy.create scope ~children:[ first; left; right ] |> ok in
  ignore (Structured_scope.checkout scope left |> ok);
  Structured_scope.suspend_yield scope left ~resume:21 |> ok;
  ignore (Structured_scope.checkout scope right |> ok);
  Structured_scope.suspend_yield scope right ~resume:31 |> ok;
  ignore (Structured_scope.checkout scope right_waiter |> ok);
  (match Structured_scope.await scope ~waiter:right_waiter ~target:right ~resume:41 |> ok with
  | Scheduler_core.Await_suspended, [] -> ()
  | _ -> Alcotest.fail "waiter on later sibling did not suspend");
  finish_failed scope first "first failure";
  let dropped = ref [] in
  Alcotest.check_raises "first drop failure is re-raised after cleanup" (Failure "drop 21")
    (fun () ->
      ignore
        (Scope_policy.record_terminal policy ~decision:4 first ~drop:(fun resume ->
             dropped := !dropped @ [ resume ];
             if resume = 21 then failwith "drop 21")));
  Alcotest.(check (list int))
    "later siblings are still cancelled after a drop failure" [ 21; 31 ] !dropped;
  Alcotest.(check (list string))
    "later awakened waiters survive an earlier drop failure"
    [ trace scope right_waiter ]
    (List.map (trace scope) (Scope_policy.take_awakened policy));
  Scope_policy.record_terminal policy ~decision:5 left ~drop:ignore |> ok;
  Scope_policy.record_terminal policy ~decision:6 right ~drop:ignore |> ok;
  Alcotest.(check bool)
    "drop failure does not replace the selected child failure" true
    (Scope_policy.finish policy
   = Ok (Scope_policy.Fail_fast_result (Concurrency_contract.Failed "first failure")));
  close scope

let test_exact_diagnostics () =
  let scope, _ = Structured_scope.create ~body_resume:0 |> ok in
  let child = Structured_scope.spawn scope ~resume:1 |> ok in
  Alcotest.(check string)
    "duplicate child"
    "error[E0908]: invalid structured-concurrency scope policy: duplicate child 0#1\n\
    \  hint: record each child terminal state once in scheduler decision order"
    (Scope_policy.create scope ~children:[ child; child ] |> error_text);
  let policy = Scope_policy.create scope ~children:[ child ] |> ok in
  Alcotest.(check string)
    "negative decision"
    "error[E0908]: invalid structured-concurrency scope policy: decision sequence must be \
     non-negative\n\
    \  hint: record each child terminal state once in scheduler decision order"
    (Scope_policy.record_terminal policy ~decision:(-1) child ~drop:ignore |> error_text);
  Alcotest.(check string)
    "early finish"
    "error[E0908]: invalid structured-concurrency scope policy: scope results requested before all \
     children terminated\n\
    \  hint: record each child terminal state once in scheduler decision order"
    (Scope_policy.finish policy |> error_text);
  Alcotest.(check string)
    "nonterminal observation"
    "error[E0908]: invalid structured-concurrency scope policy: child 0#1 is not terminal\n\
    \  hint: record each child terminal state once in scheduler decision order"
    (Scope_policy.record_terminal policy ~decision:0 child ~drop:ignore |> error_text);
  finish_done scope child 1;
  Scope_policy.record_terminal policy ~decision:2 child ~drop:ignore |> ok;
  Alcotest.(check string)
    "duplicate observation checks sequence first"
    "error[E0908]: invalid structured-concurrency scope policy: terminal observation (2,0) does \
     not follow (2,0)\n\
    \  hint: record each child terminal state once in scheduler decision order"
    (Scope_policy.record_terminal policy ~decision:2 child ~drop:ignore |> error_text);
  Alcotest.(check string)
    "decreasing decision"
    "error[E0908]: invalid structured-concurrency scope policy: terminal observation (1,0) does \
     not follow (2,0)\n\
    \  hint: record each child terminal state once in scheduler decision order"
    (Scope_policy.record_terminal policy ~decision:1 child ~drop:ignore |> error_text);
  Alcotest.(check string)
    "increasing duplicate terminal observation"
    "error[E0908]: invalid structured-concurrency scope policy: child 0#1 was already observed \
     terminal\n\
    \  hint: record each child terminal state once in scheduler decision order"
    (Scope_policy.record_terminal policy ~decision:3 child ~drop:ignore |> error_text);
  let unregistered = Structured_scope.spawn scope ~resume:2 |> ok in
  Alcotest.(check string)
    "unregistered same-scope child"
    "error[E0908]: invalid structured-concurrency scope policy: task 0#2 is not a registered child\n\
    \  hint: record each child terminal state once in scheduler decision order"
    (Scope_policy.record_terminal policy ~decision:4 unregistered ~drop:ignore |> error_text);
  let nested, _ = Structured_scope.nest scope ~body_resume:10 |> ok in
  let nested_child = Structured_scope.spawn nested ~resume:11 |> ok in
  Alcotest.(check string)
    "foreign-scope child"
    "error[E0907]: a Task may not escape, outlive, or be used outside the structured scope that \
     created it: the handle belongs to another structured scope\n\
    \  hint: use the handle only with async.await or async.cancel inside its creating structured \
     scope"
    (Scope_policy.record_terminal policy ~decision:4 nested_child ~drop:ignore |> error_text);
  let foreign, _ = Structured_scope.create ~body_resume:20 |> ok in
  let foreign_child = Structured_scope.spawn foreign ~resume:21 |> ok in
  Alcotest.(check string)
    "foreign-run child"
    "error[E0907]: a Task may not escape, outlive, or be used outside the structured scope that \
     created it: the handle belongs to another run\n\
    \  hint: use the handle only with async.await or async.cancel inside its creating structured \
     scope"
    (Scope_policy.record_terminal policy ~decision:4 foreign_child ~drop:ignore |> error_text);
  close foreign;
  close scope

let prop_collect_is_input_ordered =
  QCheck.Test.make ~count:200
    ~name:"collect is invariant under deterministic terminal-decision permutations" QCheck.nat_small
    (fun seed ->
      let count = seed mod 9 in
      let scope, _ = Structured_scope.create ~body_resume:(-1) |> ok in
      let children =
        List.init count (fun index -> Structured_scope.spawn scope ~resume:index |> ok)
      in
      let expected =
        List.mapi
          (fun index child ->
            match (seed + index) mod 3 with
            | 0 ->
                finish_done scope child index;
                Concurrency_contract.Done index
            | 1 ->
                let message = Printf.sprintf "failure-%d" index in
                finish_failed scope child message;
                Concurrency_contract.Failed message
            | _ ->
                finish_cancelled scope child ~resume:(100 + index) ~drop:ignore;
                Concurrency_contract.Cancelled)
          children
      in
      let policy = Scope_policy.create ~policy:Concurrency_contract.Collect scope ~children |> ok in
      let ordered =
        List.mapi (fun index child -> (Hashtbl.hash (seed, index), child)) children
        |> List.sort (fun (left, _) (right, _) -> Int.compare left right)
        |> List.map snd
      in
      List.iteri
        (fun decision child ->
          Scope_policy.record_terminal policy ~decision child ~drop:ignore |> ok)
        ordered;
      let actual = Scope_policy.finish policy in
      close scope;
      actual = Ok (Scope_policy.Collect_result expected))

let prop_fail_fast_agrees_with_frozen_first_failure =
  QCheck.Test.make ~count:200
    ~name:"fail-fast selection agrees with the frozen first_failure relation" QCheck.nat_small
    (fun seed ->
      let count = 1 + (seed mod 8) in
      let scope, _ = Structured_scope.create ~body_resume:(-1) |> ok in
      let children =
        List.init count (fun index -> Structured_scope.spawn scope ~resume:index |> ok)
      in
      let entries =
        List.mapi
          (fun index child ->
            let result =
              match (seed + index) mod 3 with
              | 0 ->
                  finish_done scope child index;
                  Concurrency_contract.Done index
              | 1 ->
                  let message = Printf.sprintf "failure-%d" index in
                  finish_failed scope child message;
                  Concurrency_contract.Failed message
              | _ ->
                  finish_cancelled scope child ~resume:(100 + index) ~drop:ignore;
                  Concurrency_contract.Cancelled
            in
            (index, child, result))
          children
      in
      let scheduled =
        entries
        |> List.sort (fun (left, _, _) (right, _, _) ->
            Int.compare (Hashtbl.hash (seed, left)) (Hashtbl.hash (seed, right)))
        |> List.mapi (fun decision (index, child, result) -> (decision, index, child, result))
      in
      let decision_for index =
        scheduled
        |> List.find_map (fun (decision, candidate, _, _) ->
            if candidate = index then Some decision else None)
        |> Option.get
      in
      let completions : int Concurrency_contract.completion list =
        List.map
          (fun (index, child, result) ->
            ({ sequence = decision_for index; task = Structured_scope.id scope child |> ok; result }
              : int Concurrency_contract.completion))
          entries
      in
      let expected =
        match Concurrency_contract.first_failure completions with
        | Some { result = Concurrency_contract.Failed message; _ } ->
            Concurrency_contract.Failed message
        | Some { result = Concurrency_contract.Cancelled; _ } -> Concurrency_contract.Cancelled
        | Some { result = Concurrency_contract.Done _; _ } -> assert false
        | None ->
            Concurrency_contract.Done
              (List.map
                 (function
                   | _, _, Concurrency_contract.Done value -> value
                   | _, _, (Concurrency_contract.Failed _ | Concurrency_contract.Cancelled) ->
                       assert false)
                 entries)
      in
      let policy = Scope_policy.create scope ~children |> ok in
      List.iter
        (fun (decision, _, child, _) ->
          Scope_policy.record_terminal policy ~decision child ~drop:ignore |> ok)
        scheduled;
      let actual = Scope_policy.finish policy in
      close scope;
      actual = Ok (Scope_policy.Fail_fast_result expected))

let run () =
  test_zero_and_one_default ();
  test_fail_fast_cancels_in_input_order ();
  test_fail_fast_retains_awakened_waiters ();
  test_fail_fast_retains_same_delivery_waiter_when_drop_raises ();
  test_collect_mixed_results_in_input_order ();
  test_scheduler_decision_selects_first_failure ();
  test_nested_policies ();
  test_failure_during_cancellation_keeps_first_decision ();
  test_cancellation_before_failure_keeps_first_decision ();
  test_cancellation_cleanup_survives_drop_failure ();
  test_exact_diagnostics ();
  QCheck.Test.check_exn prop_collect_is_input_ordered;
  QCheck.Test.check_exn prop_fail_fast_agrees_with_frozen_first_failure

let suite = [ Alcotest.test_case "fail-fast and collect aggregation" `Quick run ]
