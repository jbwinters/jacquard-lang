open Jacquard

let ok = function
  | Ok value -> value
  | Error diagnostics ->
      Alcotest.failf "unexpected cancellation diagnostic: %s"
        (String.concat "\n" (List.map Diag.to_string diagnostics))

let view scope task = Structured_scope.inspect scope task |> ok
let trace scope task = Structured_scope.id scope task |> ok |> Concurrency_contract.trace_task_id
let is_cancelled scope task = (view scope task).result = Some Concurrency_contract.Cancelled

let test_await_and_yield_deliver_before_suspension () =
  let scope, waiter = Structured_scope.create ~body_resume:0 |> ok in
  let target = Structured_scope.spawn scope ~resume:1 |> ok in
  ignore (Structured_scope.checkout scope waiter |> ok);
  Structured_scope.request_cancel scope waiter |> ok;
  let dropped = ref [] in
  (match
     Structured_scope.await_cooperatively scope ~waiter ~target ~resume:10 ~drop:(fun resume ->
         dropped := resume :: !dropped)
     |> ok
   with
  | Structured_scope.Await_cancelled awakened ->
      Alcotest.(check int) "cancelled await wakes no waiter" 0 (List.length awakened)
  | Structured_scope.Await_performed _ -> Alcotest.fail "cancelled await registered a waiter");
  Alcotest.(check bool) "waiter cancelled before await" true (is_cancelled scope waiter);
  Alcotest.(check int) "target has no registered waiter" 0 (List.length (view scope target).waiters);
  Alcotest.(check (list int)) "await continuation destroyed" [ 10 ] !dropped;
  let yielded = Structured_scope.spawn scope ~resume:2 |> ok in
  ignore (Structured_scope.checkout scope yielded |> ok);
  Structured_scope.request_cancel scope yielded |> ok;
  (match
     Structured_scope.yield_cooperatively scope ~task:yielded ~resume:20 ~drop:(fun resume ->
         dropped := resume :: !dropped)
     |> ok
   with
  | Structured_scope.Yield_cancelled awakened ->
      Alcotest.(check int) "cancelled yield wakes no waiter" 0 (List.length awakened)
  | Structured_scope.Yield_suspended -> Alcotest.fail "cancelled yield suspended");
  Alcotest.(check bool) "yielding task cancelled" true (is_cancelled scope yielded);
  Alcotest.(check (list int))
    "both continuations destroyed" [ 10; 20 ] (List.sort Int.compare !dropped);
  Structured_scope.close scope ~reason:Structured_scope.Normal ~escaping:[] ~drop:ignore |> ok

let test_routed_effect_preemption_and_fault_result () =
  let scope, caller = Structured_scope.create ~body_resume:0 |> ok in
  ignore (Structured_scope.checkout scope caller |> ok);
  Structured_scope.request_cancel scope caller |> ok;
  let calls = ref 0 in
  let drops = ref [] in
  (match
     Structured_scope.route_effect scope ~task:caller ~resume:30
       ~drop:(fun resume -> drops := resume :: !drops)
       ~action:(fun () ->
         incr calls;
         Ok 42)
     |> ok
   with
  | Structured_scope.Effect_cancelled _ -> ()
  | Structured_scope.Effect_routed _ -> Alcotest.fail "cancelled routed action executed");
  Alcotest.(check int) "preempted action counter" 0 !calls;
  Alcotest.(check (list int)) "preempted continuation destroyed" [ 30 ] !drops;
  let fault_scope, faulting = Structured_scope.create ~body_resume:1 |> ok in
  ignore (Structured_scope.checkout fault_scope faulting |> ok);
  let injected =
    Diag.error ~domain:Runtime ~code:"E9997" ~summary:"Injected routed-effect fault"
      ~cause:"The cancellation test injected a routed-effect failure."
      ~next_step:"Propagate the injected diagnostic unchanged." ~contrast:None ()
  in
  (match
     Structured_scope.route_effect fault_scope ~task:faulting ~resume:31 ~drop:ignore
       ~action:(fun () ->
         incr calls;
         Error [ injected ])
     |> ok
   with
  | Structured_scope.Effect_routed { resume; result = Error [ diagnostic ] } ->
      Alcotest.(check int) "fault returns continuation" 31 resume;
      Alcotest.(check string) "fault preserved" "E9997" (Diag.code_or_uncoded diagnostic)
  | Structured_scope.Effect_routed _ -> Alcotest.fail "wrong routed fault shape"
  | Structured_scope.Effect_cancelled _ -> Alcotest.fail "uncancelled routed action was preempted");
  Alcotest.(check int) "faulting action ran once" 1 !calls;
  Structured_scope.close scope ~reason:Structured_scope.Normal ~escaping:[] ~drop:ignore |> ok;
  Structured_scope.close fault_scope ~reason:Structured_scope.Aborted ~escaping:[] ~drop:ignore
  |> ok

let test_spawn_action_is_not_created_after_delivery () =
  let scope, caller = Structured_scope.create ~body_resume:0 |> ok in
  ignore (Structured_scope.checkout scope caller |> ok);
  Structured_scope.request_cancel scope caller |> ok;
  let spawn_attempts = ref 0 in
  (match
     Structured_scope.route_effect scope ~task:caller ~resume:40 ~drop:ignore ~action:(fun () ->
         incr spawn_attempts;
         Structured_scope.spawn scope ~resume:41)
     |> ok
   with
  | Structured_scope.Effect_cancelled _ -> ()
  | Structured_scope.Effect_routed _ -> Alcotest.fail "cancelled spawn action ran");
  Alcotest.(check int) "spawn callback not entered" 0 !spawn_attempts;
  let metrics = Structured_scope.metrics scope in
  Alcotest.(check int) "no child created" 0 metrics.live_tasks;
  Alcotest.(check int) "no runnable continuation" 0 metrics.runnable_tasks;
  Structured_scope.close scope ~reason:Structured_scope.Normal ~escaping:[] ~drop:ignore |> ok

let test_public_delivery_destroys_suspended_resume_once () =
  let scope, _ = Structured_scope.create ~body_resume:0 |> ok in
  let target = Structured_scope.spawn scope ~resume:20 |> ok in
  ignore (Structured_scope.checkout scope target |> ok);
  Structured_scope.suspend_yield scope target ~resume:21 |> ok;
  Structured_scope.request_cancel scope target |> ok;
  let dropped = ref [] in
  let drop resume = dropped := !dropped @ [ resume ] in
  let awakened =
    Structured_scope.deliver_cancel scope ~point:Concurrency_contract.Yield target ~drop |> ok
  in
  Alcotest.(check int) "public delivery wakes no waiter" 0 (List.length awakened);
  Alcotest.(check (list int)) "suspended resume 21 destroyed exactly once" [ 21 ] !dropped;
  ignore (Structured_scope.deliver_cancel scope ~point:Concurrency_contract.Yield target ~drop |> ok);
  Alcotest.(check (list int)) "duplicate delivery destroys nothing" [ 21 ] !dropped;
  (match
     Structured_scope.at_cancellation_point scope ~point:Concurrency_contract.Yield ~task:target
       ~resume:23 ~drop
     |> ok
   with
  | Structured_scope.Boundary_cancelled awakened ->
      Alcotest.(check int) "stale cancelled boundary wakes nobody" 0 (List.length awakened)
  | Structured_scope.Boundary_continue _ ->
      Alcotest.fail "an already-cancelled task must not continue");
  Alcotest.(check (list int)) "stale boundary continuation destroyed once" [ 21; 23 ] !dropped;
  let completed = Structured_scope.spawn scope ~resume:22 |> ok in
  ignore (Structured_scope.checkout scope completed |> ok);
  ignore (Structured_scope.complete scope completed 99 |> ok);
  Structured_scope.request_cancel scope completed |> ok;
  ignore
    (Structured_scope.deliver_cancel scope ~point:Concurrency_contract.Routed_effect completed ~drop
    |> ok);
  Alcotest.(check (list int)) "completed delivery destroys nothing" [ 21; 23 ] !dropped;
  Structured_scope.close scope ~reason:Structured_scope.Normal ~escaping:[] ~drop:ignore |> ok

let test_raising_drop_keeps_immediate_cancellation_terminal () =
  let scope, caller = Structured_scope.create ~body_resume:0 |> ok in
  let target = Structured_scope.spawn scope ~resume:1 |> ok in
  ignore (Structured_scope.checkout scope target |> ok);
  Structured_scope.suspend_yield scope target ~resume:80 |> ok;
  ignore (Structured_scope.checkout scope caller |> ok);
  let cleanup_failure = Failure "cancel destruction failed" in
  let drop_calls = ref [] in
  (match
     Structured_scope.cancel scope ~caller ~target ~resume:81 ~drop:(fun resume ->
         drop_calls := resume :: !drop_calls;
         raise cleanup_failure)
   with
  | exception caught when caught == cleanup_failure -> ()
  | exception exn ->
      Alcotest.failf "wrong cancellation cleanup exception: %s" (Printexc.to_string exn)
  | Ok _ | Error _ -> Alcotest.fail "raising cancellation cleanup was swallowed");
  let target_view = view scope target in
  Alcotest.(check bool)
    "target remains terminal after raising drop" true
    (target_view.lifecycle = Concurrency_contract.Cancelled_state
    && target_view.result = Some Concurrency_contract.Cancelled);
  Alcotest.(check bool) "target resume is not re-owned" false target_view.owns_resume;
  Alcotest.(check (list int)) "transferred resume was offered once" [ 80 ] !drop_calls;
  Alcotest.(check int)
    "scope owns no resume after failed destruction" 0 (Structured_scope.metrics scope).owned_resumes;
  let duplicate_drop_calls = ref 0 in
  let awakened =
    Structured_scope.deliver_cancel scope ~point:Concurrency_contract.Yield target ~drop:(fun _ ->
        incr duplicate_drop_calls)
    |> ok
  in
  Alcotest.(check int) "duplicate delivery wakes nobody" 0 (List.length awakened);
  Alcotest.(check int) "duplicate delivery does not re-drop" 0 !duplicate_drop_calls;
  Structured_scope.close scope ~reason:Structured_scope.Normal ~escaping:[] ~drop:ignore |> ok

let test_cancelled_target_wakes_registered_waiters_in_order () =
  let scope, target = Structured_scope.create ~body_resume:0 |> ok in
  let first = Structured_scope.spawn scope ~resume:1 |> ok in
  let second = Structured_scope.spawn scope ~resume:2 |> ok in
  let caller = Structured_scope.spawn scope ~resume:3 |> ok in
  ignore (Structured_scope.checkout scope target |> ok);
  Structured_scope.suspend_yield scope target ~resume:10 |> ok;
  ignore (Structured_scope.checkout scope first |> ok);
  (match Structured_scope.await scope ~waiter:first ~target ~resume:11 |> ok with
  | Scheduler_core.Await_suspended, [] -> ()
  | _ -> Alcotest.fail "first waiter must suspend without wakeups");
  ignore (Structured_scope.checkout scope second |> ok);
  (match Structured_scope.await scope ~waiter:second ~target ~resume:12 |> ok with
  | Scheduler_core.Await_suspended, [] -> ()
  | _ -> Alcotest.fail "second waiter must suspend without wakeups");
  ignore (Structured_scope.checkout scope caller |> ok);
  let dropped = ref [] in
  let drop resume = dropped := !dropped @ [ resume ] in
  (match Structured_scope.cancel scope ~caller ~target ~resume:13 ~drop |> ok with
  | Structured_scope.Cancel_continues { resume; awakened } ->
      Alcotest.(check int) "caller continuation" 13 resume;
      Alcotest.(check (list string))
        "waiters wake in registration order"
        [ trace scope first; trace scope second ]
        (List.map (trace scope) awakened)
  | Structured_scope.Cancel_caller_cancelled _ ->
      Alcotest.fail "cancelling another task must preserve the caller");
  let target_view = view scope target in
  Alcotest.(check bool)
    "target is cancelled" true
    (target_view.lifecycle = Concurrency_contract.Cancelled_state);
  Alcotest.(check bool)
    "target result is cancelled" true
    (target_view.result = Some Concurrency_contract.Cancelled);
  let check_awakened label task =
    let task_view = view scope task in
    Alcotest.(check bool)
      (label ^ " is runnable") true
      (task_view.lifecycle = Concurrency_contract.Runnable);
    Alcotest.(check bool) (label ^ " no longer suspended") true (task_view.suspension = None);
    Alcotest.(check bool) (label ^ " has no result") true (task_view.result = None);
    Alcotest.(check bool) (label ^ " owns its resume") true task_view.owns_resume
  in
  check_awakened "first waiter" first;
  check_awakened "second waiter" second;
  let observe_cancelled label task resume =
    ignore (Structured_scope.checkout scope task |> ok);
    match Structured_scope.await scope ~waiter:task ~target ~resume |> ok with
    | Scheduler_core.Await_ready Concurrency_contract.Cancelled, [] -> ()
    | Scheduler_core.Await_ready _, _ -> Alcotest.fail (label ^ " observed wrong result")
    | Scheduler_core.Await_suspended, _ | Scheduler_core.Await_deadlocked _, _ ->
        Alcotest.fail (label ^ " must observe the terminal result")
  in
  observe_cancelled "first waiter" first 14;
  observe_cancelled "second waiter" second 15;
  Structured_scope.suspend_yield scope caller ~resume:13 |> ok;
  Structured_scope.close scope ~reason:Structured_scope.Normal ~escaping:[] ~drop |> ok;
  Alcotest.(check (list int)) "all owned continuations destroyed once" [ 10; 14; 15; 13 ] !dropped

let test_duplicate_completed_and_self_cancel () =
  let scope, caller = Structured_scope.create ~body_resume:0 |> ok in
  let target = Structured_scope.spawn scope ~resume:1 |> ok in
  let completed = Structured_scope.spawn scope ~resume:2 |> ok in
  ignore (Structured_scope.checkout scope completed |> ok);
  ignore (Structured_scope.complete scope completed 99 |> ok);
  ignore (Structured_scope.checkout scope caller |> ok);
  let continuation = ref 50 in
  for _ = 1 to 4 do
    match
      Structured_scope.cancel scope ~caller ~target ~resume:!continuation ~drop:ignore |> ok
    with
    | Structured_scope.Cancel_continues { resume; awakened } ->
        Alcotest.(check int) "duplicate cancel wakes nothing" 0 (List.length awakened);
        continuation := resume
    | Structured_scope.Cancel_caller_cancelled _ ->
        Alcotest.fail "cancelling another task cancelled caller"
  done;
  Alcotest.(check bool) "one pending target request" true (view scope target).cancellation_requested;
  (match
     Structured_scope.cancel scope ~caller ~target:completed ~resume:!continuation ~drop:ignore
     |> ok
   with
  | Structured_scope.Cancel_continues { resume; awakened = [] } -> continuation := resume
  | _ -> Alcotest.fail "cancel of completed target was not a no-op");
  Alcotest.(check bool)
    "completed result preserved" true
    ((view scope completed).result = Some (Concurrency_contract.Done 99));
  let dropped = ref [] in
  (match
     Structured_scope.cancel scope ~caller ~target:caller ~resume:!continuation ~drop:(fun resume ->
         dropped := resume :: !dropped)
     |> ok
   with
  | Structured_scope.Cancel_caller_cancelled awakened ->
      Alcotest.(check int) "self-cancel wakes nothing" 0 (List.length awakened)
  | Structured_scope.Cancel_continues _ -> Alcotest.fail "self-cancel continued");
  Alcotest.(check bool) "self reaches Cancelled once" true (is_cancelled scope caller);
  Alcotest.(check (list int)) "self continuation destroyed" [ 50 ] !dropped;
  Structured_scope.close scope ~reason:Structured_scope.Normal ~escaping:[] ~drop:ignore |> ok

let test_suspended_target_and_precancelled_caller () =
  let scope, caller = Structured_scope.create ~body_resume:0 |> ok in
  let target = Structured_scope.spawn scope ~resume:1 |> ok in
  ignore (Structured_scope.checkout scope target |> ok);
  Structured_scope.suspend_yield scope target ~resume:60 |> ok;
  ignore (Structured_scope.checkout scope caller |> ok);
  let dropped = ref [] in
  (match
     Structured_scope.cancel scope ~caller ~target ~resume:61 ~drop:(fun resume ->
         dropped := resume :: !dropped)
     |> ok
   with
  | Structured_scope.Cancel_continues { resume = 61; awakened = [] } -> ()
  | _ -> Alcotest.fail "suspended target cancellation had wrong outcome");
  Alcotest.(check bool) "suspended target cancelled immediately" true (is_cancelled scope target);
  Alcotest.(check (list int)) "suspended continuation destroyed" [ 60 ] !dropped;
  let blocked_scope, blocked_caller = Structured_scope.create ~body_resume:2 |> ok in
  let untouched = Structured_scope.spawn blocked_scope ~resume:3 |> ok in
  ignore (Structured_scope.checkout blocked_scope blocked_caller |> ok);
  Structured_scope.request_cancel blocked_scope blocked_caller |> ok;
  (match
     Structured_scope.cancel blocked_scope ~caller:blocked_caller ~target:untouched ~resume:62
       ~drop:(fun resume -> dropped := resume :: !dropped)
     |> ok
   with
  | Structured_scope.Cancel_caller_cancelled _ -> ()
  | Structured_scope.Cancel_continues _ -> Alcotest.fail "pre-cancelled caller continued");
  Alcotest.(check bool)
    "target request not performed" false (view blocked_scope untouched).cancellation_requested;
  Alcotest.(check (list int))
    "caller continuation destroyed" [ 60; 62 ] (List.sort Int.compare !dropped);
  Structured_scope.close scope ~reason:Structured_scope.Normal ~escaping:[] ~drop:ignore |> ok;
  Structured_scope.close blocked_scope ~reason:Structured_scope.Aborted ~escaping:[] ~drop:ignore
  |> ok

let explicit_bracket ~events body =
  events := !events @ [ "acquire" ];
  match body () with
  | result ->
      events := !events @ [ "release" ];
      result
  | exception exn ->
      events := !events @ [ "release" ];
      raise exn

let test_bracket_cleanup_without_post_cancel_step () =
  let scope, task = Structured_scope.create ~body_resume:0 |> ok in
  ignore (Structured_scope.checkout scope task |> ok);
  Structured_scope.request_cancel scope task |> ok;
  let events = ref [] in
  explicit_bracket ~events (fun () ->
      match
        Structured_scope.yield_cooperatively scope ~task ~resume:70 ~drop:(fun _ ->
            events := !events @ [ "drop-continuation" ])
        |> ok
      with
      | Structured_scope.Yield_cancelled _ -> ()
      | Structured_scope.Yield_suspended -> events := !events @ [ "post-cancel-user-step" ]);
  Alcotest.(check (list string))
    "explicit release runs, user continuation does not"
    [ "acquire"; "drop-continuation"; "release" ]
    !events;
  Structured_scope.close scope ~reason:Structured_scope.Normal ~escaping:[] ~drop:ignore |> ok

let prop_duplicate_requests_deliver_once =
  QCheck.Test.make ~count:200 ~name:"duplicate requests destroy one continuation and cancel once"
    QCheck.nat_small (fun seed ->
      let scope, _ = Structured_scope.create ~body_resume:(-1) |> ok in
      let task = Structured_scope.spawn scope ~resume:seed |> ok in
      let repetitions = (seed mod 32) + 1 in
      for _ = 1 to repetitions do
        Structured_scope.request_cancel scope task |> ok
      done;
      ignore (Structured_scope.checkout scope task |> ok);
      let drops = ref 0 in
      let outcome =
        Structured_scope.yield_cooperatively scope ~task ~resume:(seed + 1) ~drop:(fun _ ->
            incr drops)
        |> ok
      in
      let cancelled =
        match outcome with
        | Structured_scope.Yield_cancelled [] -> true
        | Structured_scope.Yield_cancelled (_ :: _) | Structured_scope.Yield_suspended -> false
      in
      let terminal = is_cancelled scope task in
      Structured_scope.close scope ~reason:Structured_scope.Normal ~escaping:[] ~drop:ignore |> ok;
      cancelled && terminal && !drops = 1)

let run () =
  test_await_and_yield_deliver_before_suspension ();
  test_routed_effect_preemption_and_fault_result ();
  test_spawn_action_is_not_created_after_delivery ();
  test_public_delivery_destroys_suspended_resume_once ();
  test_raising_drop_keeps_immediate_cancellation_terminal ();
  test_cancelled_target_wakes_registered_waiters_in_order ();
  test_duplicate_completed_and_self_cancel ();
  test_suspended_target_and_precancelled_caller ();
  test_bracket_cleanup_without_post_cancel_step ();
  QCheck.Test.check_exn prop_duplicate_requests_deliver_once

let suite = [ Alcotest.test_case "cooperative boundary delivery" `Quick run ]
