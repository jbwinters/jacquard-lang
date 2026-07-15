open Jacquard

let ok = function
  | Ok value -> value
  | Error diagnostics ->
      Alcotest.failf "unexpected scheduler diagnostic: %s"
        (String.concat "\n" (List.map Diag.to_string diagnostics))

let error_code = function
  | Error ({ Diag.code; _ } :: _) -> code
  | Error [] -> Alcotest.fail "scheduler returned an empty diagnostic list"
  | Ok _ -> Alcotest.fail "scheduler operation unexpectedly succeeded"

let trace scheduler handle =
  Scheduler_core.id scheduler handle |> ok |> Concurrency_contract.trace_task_id

let view scheduler handle = Scheduler_core.inspect scheduler handle |> ok

let check_lifecycle expected scheduler handle =
  let actual = (view scheduler handle).lifecycle in
  Alcotest.(check bool) "lifecycle" true (expected = actual)

let is_live_wakeup scheduler handle =
  let task = view scheduler handle in
  task.lifecycle = Concurrency_contract.Runnable && task.owns_resume

let check_live_wakeups scheduler awakened =
  List.iter
    (fun handle ->
      Alcotest.(check bool)
        ("live wakeup " ^ trace scheduler handle)
        true (is_live_wakeup scheduler handle))
    awakened

let test_deterministic_ids_and_yield () =
  let scheduler, body = Scheduler_core.create ~scope_path:[ 0; 4 ] ~body_resume:10 |> ok in
  let child = Scheduler_core.spawn scheduler ~resume:20 |> ok in
  Alcotest.(check string) "body ID" "0/4#0" (trace scheduler body);
  Alcotest.(check string) "child ID" "0/4#1" (trace scheduler child);
  Alcotest.(check int) "checkout transfers token" 20 (Scheduler_core.checkout scheduler child |> ok);
  Alcotest.(check string)
    "duplicate checkout is diagnosed" "E0908"
    (Scheduler_core.checkout scheduler child |> error_code);
  Scheduler_core.suspend_yield scheduler child ~resume:21 |> ok;
  check_lifecycle Concurrency_contract.Suspended scheduler child;
  let yielded = view scheduler child in
  Alcotest.(check bool) "yield reason" true (yielded.suspension = Some Scheduler_core.Yielded);
  Alcotest.(check bool) "one owned resume" true yielded.owns_resume;
  Scheduler_core.wake_yielded scheduler child |> ok;
  check_lifecycle Concurrency_contract.Runnable scheduler child;
  Alcotest.(check int) "returned token" 21 (Scheduler_core.checkout scheduler child |> ok)

let test_multiple_awaiters_and_terminal_result () =
  let scheduler, target = Scheduler_core.create ~scope_path:[ 0 ] ~body_resume:100 |> ok in
  let first = Scheduler_core.spawn scheduler ~resume:1 |> ok in
  let second = Scheduler_core.spawn scheduler ~resume:2 |> ok in
  ignore (Scheduler_core.checkout scheduler first |> ok);
  let outcome, awakened = Scheduler_core.await scheduler ~waiter:first ~target ~resume:11 |> ok in
  Alcotest.(check bool) "first suspends" true (outcome = Scheduler_core.Await_suspended);
  Alcotest.(check int) "no early wake" 0 (List.length awakened);
  ignore (Scheduler_core.checkout scheduler second |> ok);
  ignore (Scheduler_core.await scheduler ~waiter:second ~target ~resume:22 |> ok);
  Alcotest.(check (list string))
    "registration order" [ "0#1"; "0#2" ]
    (List.map Concurrency_contract.trace_task_id (view scheduler target).waiters);
  ignore (Scheduler_core.checkout scheduler target |> ok);
  let awakened = Scheduler_core.complete scheduler target 42 |> ok in
  Alcotest.(check (list string)) "wake order" [ "0#1"; "0#2" ] (List.map (trace scheduler) awakened);
  List.iter (check_lifecycle Concurrency_contract.Runnable scheduler) awakened;
  let terminal = view scheduler target in
  Alcotest.(check bool)
    "immutable Done result" true
    (terminal.result = Some (Concurrency_contract.Done 42));
  Alcotest.(check bool) "terminal owns no resume" false terminal.owns_resume;
  Alcotest.(check string)
    "repeat terminal transition" "E0908"
    (Scheduler_core.complete scheduler target 43 |> error_code)

let test_terminal_await_is_immediate () =
  let scheduler, waiter = Scheduler_core.create ~scope_path:[ 0 ] ~body_resume:1 |> ok in
  let target = Scheduler_core.spawn scheduler ~resume:2 |> ok in
  ignore (Scheduler_core.checkout scheduler target |> ok);
  ignore (Scheduler_core.fail scheduler target "boom" |> ok);
  ignore (Scheduler_core.checkout scheduler waiter |> ok);
  let outcome, awakened = Scheduler_core.await scheduler ~waiter ~target ~resume:3 |> ok in
  Alcotest.(check bool)
    "failure delivered immediately" true
    (outcome = Scheduler_core.Await_ready (Concurrency_contract.Failed "boom"));
  Alcotest.(check int) "no registered wake" 0 (List.length awakened);
  check_lifecycle Concurrency_contract.Runnable scheduler waiter;
  Alcotest.(check int) "waiter token retained" 3 (Scheduler_core.checkout scheduler waiter |> ok)

let test_self_await_and_cycle_fail_without_exception () =
  let scheduler, self = Scheduler_core.create ~scope_path:[ 0 ] ~body_resume:0 |> ok in
  ignore (Scheduler_core.checkout scheduler self |> ok);
  let outcome, awakened =
    Scheduler_core.await scheduler ~waiter:self ~target:self ~resume:1 |> ok
  in
  let expected = "async deadlock: task 0#0 awaited itself" in
  Alcotest.(check bool)
    "self-await message" true
    (outcome = Scheduler_core.Await_deadlocked expected);
  Alcotest.(check bool)
    "self-await becomes Failed" true
    ((view scheduler self).result = Some (Concurrency_contract.Failed expected));
  Alcotest.(check int) "self-await reports no terminal wakeup" 0 (List.length awakened);
  let scheduler, a = Scheduler_core.create ~scope_path:[ 0 ] ~body_resume:0 |> ok in
  let b = Scheduler_core.spawn scheduler ~resume:1 |> ok in
  let block scheduler waiter target resume =
    ignore (Scheduler_core.checkout scheduler waiter |> ok);
    Scheduler_core.await scheduler ~waiter ~target ~resume |> ok
  in
  ignore (block scheduler a b 10);
  let outcome, awakened = block scheduler b a 11 in
  let expected = "async deadlock: await cycle 0#0 -> 0#1 -> 0#0" in
  Alcotest.(check bool)
    "two-node cycle message" true
    (outcome = Scheduler_core.Await_deadlocked expected);
  Alcotest.(check int) "two-node cycle reports no terminal wakeup" 0 (List.length awakened);
  List.iter
    (fun handle ->
      let task = view scheduler handle in
      Alcotest.(check bool)
        "two-node member failed" true
        (task.result = Some (Concurrency_contract.Failed expected));
      Alcotest.(check bool) "two-node member dropped resume" false task.owns_resume)
    [ a; b ];
  let scheduler, a = Scheduler_core.create ~scope_path:[ 0 ] ~body_resume:0 |> ok in
  let b = Scheduler_core.spawn scheduler ~resume:1 |> ok in
  let c = Scheduler_core.spawn scheduler ~resume:2 |> ok in
  let first_external = Scheduler_core.spawn scheduler ~resume:3 |> ok in
  let cancelled_external = Scheduler_core.spawn scheduler ~resume:4 |> ok in
  let second_external = Scheduler_core.spawn scheduler ~resume:5 |> ok in
  ignore (block scheduler first_external a 30);
  ignore (block scheduler cancelled_external b 40);
  Scheduler_core.request_cancel scheduler cancelled_external |> ok;
  ignore
    (Scheduler_core.deliver_cancel scheduler ~point:Concurrency_contract.Await cancelled_external
    |> ok);
  ignore (block scheduler second_external a 50);
  ignore (block scheduler a b 10);
  ignore (block scheduler b c 11);
  let outcome, awakened = block scheduler c a 12 in
  let expected = "async deadlock: await cycle 0#0 -> 0#1 -> 0#2 -> 0#0" in
  Alcotest.(check bool)
    "closed cycle message" true
    (outcome = Scheduler_core.Await_deadlocked expected);
  List.iter
    (fun handle ->
      let task = view scheduler handle in
      Alcotest.(check bool)
        "cycle member failed" true
        (task.result = Some (Concurrency_contract.Failed expected));
      Alcotest.(check bool) "cycle member dropped resume" false task.owns_resume)
    [ a; b; c ];
  Alcotest.(check (list string))
    "only external waiters wake in registration order" [ "0#3"; "0#5" ]
    (List.map (trace scheduler) awakened);
  check_live_wakeups scheduler awakened;
  Alcotest.(check bool)
    "cancelled external waiter remains terminal" true
    ((view scheduler cancelled_external).result = Some Concurrency_contract.Cancelled)

let test_cancel_and_cleanup () =
  let scheduler, target = Scheduler_core.create ~scope_path:[ 0 ] ~body_resume:10 |> ok in
  let waiter = Scheduler_core.spawn scheduler ~resume:20 |> ok in
  ignore (Scheduler_core.checkout scheduler waiter |> ok);
  ignore (Scheduler_core.await scheduler ~waiter ~target ~resume:21 |> ok);
  Scheduler_core.request_cancel scheduler waiter |> ok;
  let awakened =
    Scheduler_core.deliver_cancel scheduler ~point:Concurrency_contract.Await waiter |> ok
  in
  Alcotest.(check int) "cancel wakes no waiter" 0 (List.length awakened);
  Alcotest.(check bool)
    "cancel result" true
    ((view scheduler waiter).result = Some Concurrency_contract.Cancelled);
  Alcotest.(check int) "await edge removed" 0 (List.length (view scheduler target).waiters);
  let owned = Scheduler_core.close scheduler in
  Alcotest.(check (list int)) "close transfers remaining tokens" [ 10 ] owned;
  Alcotest.(check int) "close is idempotent" 0 (List.length (Scheduler_core.close scheduler));
  Alcotest.(check string)
    "closed scope rejects spawn" "E0908"
    (Scheduler_core.spawn scheduler ~resume:30 |> error_code)

let test_foreign_handle_diagnostic () =
  let left, _ = Scheduler_core.create ~scope_path:[ 0 ] ~body_resume:1 |> ok in
  let _, foreign = Scheduler_core.create ~scope_path:[ 0 ] ~body_resume:2 |> ok in
  Alcotest.(check string)
    "foreign handle" "E0907"
    (Scheduler_core.inspect left foreign |> error_code)

let prop_transition_table =
  QCheck.Test.make ~count:200 ~name:"scheduler transitions preserve resume ownership"
    QCheck.nat_small (fun seed ->
      let scheduler, body = Scheduler_core.create ~scope_path:[ 0 ] ~body_resume:seed |> ok in
      Scheduler_core.checkout scheduler body = Ok seed
      && Scheduler_core.suspend_yield scheduler body ~resume:(seed + 1) = Ok ()
      && (view scheduler body).lifecycle = Concurrency_contract.Suspended
      && (view scheduler body).owns_resume
      && Scheduler_core.wake_yielded scheduler body = Ok ()
      && Scheduler_core.checkout scheduler body = Ok (seed + 1)
      && Scheduler_core.complete scheduler body seed = Ok []
      && (view scheduler body).lifecycle = Concurrency_contract.Done_state
      && not (view scheduler body).owns_resume)

let prop_cycle_wakeups_are_live =
  QCheck.Test.make ~count:200
    ~name:"every cycle-failure wakeup is runnable and owns exactly one resume" QCheck.nat_small
    (fun seed ->
      let scheduler, a = Scheduler_core.create ~scope_path:[ 0 ] ~body_resume:seed |> ok in
      let b = Scheduler_core.spawn scheduler ~resume:(seed + 1) |> ok in
      let waiter_count = seed mod 7 in
      let waiters =
        List.init waiter_count (fun index ->
            Scheduler_core.spawn scheduler ~resume:(100 + index) |> ok)
      in
      List.iteri
        (fun index waiter ->
          ignore (Scheduler_core.checkout scheduler waiter |> ok);
          ignore (Scheduler_core.await scheduler ~waiter ~target:a ~resume:(200 + index) |> ok);
          if index mod 2 = 1 then (
            Scheduler_core.request_cancel scheduler waiter |> ok;
            ignore
              (Scheduler_core.deliver_cancel scheduler ~point:Concurrency_contract.Await waiter
              |> ok)))
        waiters;
      ignore (Scheduler_core.checkout scheduler a |> ok);
      ignore (Scheduler_core.await scheduler ~waiter:a ~target:b ~resume:300 |> ok);
      ignore (Scheduler_core.checkout scheduler b |> ok);
      let _, awakened = Scheduler_core.await scheduler ~waiter:b ~target:a ~resume:301 |> ok in
      let expected = List.filteri (fun index _ -> index mod 2 = 0) waiters in
      List.map (trace scheduler) awakened = List.map (trace scheduler) expected
      && List.for_all (is_live_wakeup scheduler) awakened
      && List.for_all
           (fun member ->
             let task = view scheduler member in
             task.lifecycle = Concurrency_contract.Failed_state && not task.owns_resume)
           [ a; b ])

let run () =
  test_deterministic_ids_and_yield ();
  test_multiple_awaiters_and_terminal_result ();
  test_terminal_await_is_immediate ();
  test_self_await_and_cycle_fail_without_exception ();
  test_cancel_and_cleanup ();
  test_foreign_handle_diagnostic ();
  QCheck.Test.check_exn prop_transition_table;
  QCheck.Test.check_exn prop_cycle_wakeups_are_live
