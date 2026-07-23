open Jacquard

let ok = function
  | Ok value -> value
  | Error diagnostics ->
      Alcotest.failf "unexpected host-readiness diagnostic: %s"
        (String.concat "\n" (List.map Diag.to_string diagnostics))

let error_code = function
  | Error (diagnostic :: _) -> Diag.code_or_uncoded diagnostic
  | Error [] -> Alcotest.fail "host-readiness returned an empty diagnostic list"
  | Ok _ -> Alcotest.fail "host-readiness operation unexpectedly succeeded"

let view scheduler task = Scheduler_core.inspect scheduler task |> ok

let test_live_pipe_wakeup_and_recording () =
  let reader, writer = Unix.pipe () in
  let scheduler, task = Scheduler_core.create ~scope_path:[ 0 ] ~body_resume:17 |> ok in
  let registry = Host_readiness.create scheduler in
  let resume = Scheduler_core.checkout scheduler task |> ok in
  let registration = Host_readiness.register registry ~task ~descriptor:reader ~resume |> ok in
  Alcotest.(check int)
    "one duplicated descriptor is owned" 1
    (Host_readiness.registration_count registry);
  Alcotest.(check bool)
    "task suspended on host readiness" true
    ((view scheduler task).suspension = Some (Scheduler_core.Host_readiness registration.id));
  ignore (Unix.write_substring writer "x" 0 1);
  let poll = Host_readiness.poll_live registry |> ok in
  Alcotest.(check int) "one readiness decision" 1 (List.length poll.decisions);
  Alcotest.(check bool)
    "recorded decision retains task identity" true
    (poll.decisions = [ registration ]);
  Alcotest.(check int) "wake returns task" 1 (List.length poll.awakened);
  Alcotest.(check int)
    "readiness descriptor retires after wake" 0
    (Host_readiness.registration_count registry);
  Alcotest.(check bool)
    "task became runnable" true
    ((view scheduler task).lifecycle = Concurrency_contract.Runnable);
  Alcotest.(check int) "resume token is unchanged" 17 (Scheduler_core.checkout scheduler task |> ok);
  ignore (Scheduler_core.complete scheduler task () |> ok);
  Host_readiness.shutdown registry ~drop:ignore |> ok;
  Unix.close reader;
  Unix.close writer

let counting_ops closed poll_count =
  {
    Host_readiness.duplicate = (fun descriptor -> Unix.dup ~cloexec:true descriptor);
    close =
      (fun descriptor ->
        incr closed;
        Unix.close descriptor);
    poll_readable =
      (fun descriptors ->
        incr poll_count;
        let readable, _, _ = Unix.select descriptors [] [] 0.0 in
        readable);
  }

let test_cancellation_and_shutdown_release_once () =
  let reader, writer = Unix.pipe () in
  let scheduler, task = Scheduler_core.create ~scope_path:[ 0 ] ~body_resume:21 |> ok in
  let closed = ref 0 in
  let poll_count = ref 0 in
  let registry = Host_readiness.create ~descriptor_ops:(counting_ops closed poll_count) scheduler in
  let resume = Scheduler_core.checkout scheduler task |> ok in
  ignore (Host_readiness.register registry ~task ~descriptor:reader ~resume |> ok);
  let dropped = ref [] in
  Host_readiness.cancel registry task ~drop:(fun value -> dropped := value :: !dropped)
  |> ok |> ignore;
  Alcotest.(check (list int)) "cancellation drops the suspended resume once" [ 21 ] !dropped;
  Alcotest.(check int)
    "cancellation retires descriptor" 0
    (Host_readiness.registration_count registry);
  Alcotest.(check int) "cancellation closes its owned duplicate exactly once" 1 !closed;
  Host_readiness.cancel registry task ~drop:(fun value -> dropped := value :: !dropped)
  |> ok |> ignore;
  Alcotest.(check (list int)) "repeated cancellation does not drop twice" [ 21 ] !dropped;
  let survivor = Scheduler_core.spawn scheduler ~resume:22 |> ok in
  let survivor_resume = Scheduler_core.checkout scheduler survivor |> ok in
  ignore
    (Host_readiness.register registry ~task:survivor ~descriptor:reader ~resume:survivor_resume
    |> ok);
  Host_readiness.shutdown registry ~drop:(fun value -> dropped := value :: !dropped) |> ok;
  Host_readiness.shutdown registry ~drop:(fun value -> dropped := value :: !dropped) |> ok;
  Alcotest.(check (list int)) "shutdown drops its suspended resume once" [ 22; 21 ] !dropped;
  Alcotest.(check int) "shutdown closes its owned duplicate exactly once" 2 !closed;
  Unix.close reader;
  Unix.close writer

let test_strict_replay_never_needs_live_readiness () =
  let reader, writer = Unix.pipe () in
  let scheduler, task = Scheduler_core.create ~scope_path:[ 0 ] ~body_resume:34 |> ok in
  let closed = ref 0 in
  let poll_count = ref 0 in
  let registry = Host_readiness.create ~descriptor_ops:(counting_ops closed poll_count) scheduler in
  let resume = Scheduler_core.checkout scheduler task |> ok in
  let registration = Host_readiness.register registry ~task ~descriptor:reader ~resume |> ok in
  (* The injected poller increments a counter. Replay must not invoke it, whether or not the pipe
     is ready. *)
  let replay = Host_readiness.replay registry ~registrations:[ registration ] |> ok in
  Alcotest.(check int) "replay wakes recorded task" 1 (List.length replay.awakened);
  Alcotest.(check int)
    "successful replay has no cleanup diagnostic" 0
    (List.length replay.cleanup_diagnostics);
  Alcotest.(check int) "replay retired descriptor" 0 (Host_readiness.registration_count registry);
  Alcotest.(check int) "replay closed its duplicate" 1 !closed;
  Alcotest.(check int) "replay never polled live descriptors" 0 !poll_count;
  Alcotest.(check int) "replay preserves resume" 34 (Scheduler_core.checkout scheduler task |> ok);
  Alcotest.(check string)
    "duplicate replay is refused deterministically" "E0908"
    (Host_readiness.replay registry ~registrations:[ registration ] |> error_code);
  ignore (Scheduler_core.complete scheduler task () |> ok);
  Host_readiness.shutdown registry ~drop:ignore |> ok;
  Unix.close reader;
  Unix.close writer

let test_equivalent_fresh_run_replays_recorded_identity () =
  let old_reader, old_writer = Unix.pipe () in
  let old_scheduler, old_task = Scheduler_core.create ~scope_path:[ 0 ] ~body_resume:1 |> ok in
  let old_registry = Host_readiness.create old_scheduler in
  let old_resume = Scheduler_core.checkout old_scheduler old_task |> ok in
  let recorded =
    Host_readiness.register old_registry ~task:old_task ~descriptor:old_reader ~resume:old_resume
    |> ok
  in
  Host_readiness.shutdown old_registry ~drop:ignore |> ok;
  Unix.close old_reader;
  Unix.close old_writer;
  let reader, writer = Unix.pipe () in
  let scheduler, task = Scheduler_core.create ~scope_path:[ 0 ] ~body_resume:2 |> ok in
  let closed = ref 0 in
  let poll_count = ref 0 in
  let registry = Host_readiness.create ~descriptor_ops:(counting_ops closed poll_count) scheduler in
  let resume = Scheduler_core.checkout scheduler task |> ok in
  ignore (Host_readiness.register registry ~task ~descriptor:reader ~resume |> ok);
  Host_readiness.replay registry ~registrations:[ recorded ] |> ok |> ignore;
  Alcotest.(check int) "equivalent replay never polled" 0 !poll_count;
  Alcotest.(check int) "equivalent replay closes owned duplicate" 1 !closed;
  ignore (Scheduler_core.checkout scheduler task |> ok);
  ignore (Scheduler_core.complete scheduler task () |> ok);
  Host_readiness.shutdown registry ~drop:ignore |> ok;
  Unix.close reader;
  Unix.close writer

let close_once_failure_ops close_count poll_count =
  {
    Host_readiness.duplicate = (fun descriptor -> Unix.dup ~cloexec:true descriptor);
    close =
      (fun descriptor ->
        incr close_count;
        Unix.close descriptor;
        if !close_count = 1 then raise (Unix.Unix_error (Unix.EIO, "close", "injected")));
    poll_readable =
      (fun descriptors ->
        incr poll_count;
        descriptors);
  }

let check_cleanup_error label diagnostics =
  Alcotest.(check (list string)) label [ "E0908" ] (List.map Diag.code_or_uncoded diagnostics)

let test_poll_close_failure_preserves_all_wakeups () =
  let reader, writer = Unix.pipe () in
  let scheduler, root = Scheduler_core.create ~scope_path:[ 0 ] ~body_resume:300 |> ok in
  let child = Scheduler_core.spawn scheduler ~resume:301 |> ok in
  let close_count = ref 0 in
  let poll_count = ref 0 in
  let registry =
    Host_readiness.create ~descriptor_ops:(close_once_failure_ops close_count poll_count) scheduler
  in
  let root_resume = Scheduler_core.checkout scheduler root |> ok in
  ignore (Host_readiness.register registry ~task:root ~descriptor:reader ~resume:root_resume |> ok);
  let child_resume = Scheduler_core.checkout scheduler child |> ok in
  ignore (Host_readiness.register registry ~task:child ~descriptor:reader ~resume:child_resume |> ok);
  let poll = Host_readiness.poll_live registry |> ok in
  Alcotest.(check int) "poll returns every completed wakeup" 2 (List.length poll.awakened);
  Alcotest.(check int) "poll records every completed decision" 2 (List.length poll.decisions);
  check_cleanup_error "poll carries close failure beside wakeups" poll.cleanup_diagnostics;
  Alcotest.(check int) "poll continues closing later descriptors" 2 !close_count;
  Alcotest.(check int) "poll executes one readiness query" 1 !poll_count;
  Alcotest.(check int)
    "poll retires every registration despite close failure" 0
    (Host_readiness.registration_count registry);
  Alcotest.(check bool)
    "root remains available to the caller's runnable queue" true
    ((view scheduler root).lifecycle = Concurrency_contract.Runnable);
  Alcotest.(check bool)
    "child remains available to the caller's runnable queue" true
    ((view scheduler child).lifecycle = Concurrency_contract.Runnable);
  Host_readiness.shutdown registry ~drop:ignore |> ok;
  Unix.close reader;
  Unix.close writer

let test_replay_close_failure_preserves_wakeup_without_polling () =
  let reader, writer = Unix.pipe () in
  let scheduler, task = Scheduler_core.create ~scope_path:[ 0 ] ~body_resume:310 |> ok in
  let close_count = ref 0 in
  let poll_count = ref 0 in
  let registry =
    Host_readiness.create ~descriptor_ops:(close_once_failure_ops close_count poll_count) scheduler
  in
  let resume = Scheduler_core.checkout scheduler task |> ok in
  let registration = Host_readiness.register registry ~task ~descriptor:reader ~resume |> ok in
  let replay = Host_readiness.replay registry ~registrations:[ registration ] |> ok in
  Alcotest.(check int) "replay returns completed wakeup" 1 (List.length replay.awakened);
  check_cleanup_error "replay carries close failure beside wakeup" replay.cleanup_diagnostics;
  Alcotest.(check int) "replay attempts descriptor close once" 1 !close_count;
  Alcotest.(check int) "replay still performs no readiness query" 0 !poll_count;
  Alcotest.(check bool)
    "replayed task remains available to caller" true
    ((view scheduler task).lifecycle = Concurrency_contract.Runnable);
  Host_readiness.shutdown registry ~drop:ignore |> ok;
  Unix.close reader;
  Unix.close writer

let test_cancel_close_failure_preserves_wakeups () =
  let reader, writer = Unix.pipe () in
  let scheduler, task = Scheduler_core.create ~scope_path:[ 0 ] ~body_resume:320 |> ok in
  let waiter = Scheduler_core.spawn scheduler ~resume:321 |> ok in
  let close_count = ref 0 in
  let poll_count = ref 0 in
  let registry =
    Host_readiness.create ~descriptor_ops:(close_once_failure_ops close_count poll_count) scheduler
  in
  let resume = Scheduler_core.checkout scheduler task |> ok in
  ignore (Host_readiness.register registry ~task ~descriptor:reader ~resume |> ok);
  let waiter_resume = Scheduler_core.checkout scheduler waiter |> ok in
  ignore (Scheduler_core.await scheduler ~waiter ~target:task ~resume:waiter_resume |> ok);
  let dropped = ref [] in
  let cancellation =
    Host_readiness.cancel registry task ~drop:(fun value -> dropped := value :: !dropped) |> ok
  in
  check_cleanup_error "cancel carries close failure beside wakeups" cancellation.cleanup_diagnostics;
  Alcotest.(check int)
    "cancel returns waiter awakened by terminal transition" 1
    (List.length cancellation.awakened);
  Alcotest.(check bool)
    "cancelled task's waiter remains available to caller" true
    ((view scheduler waiter).lifecycle = Concurrency_contract.Runnable);
  Alcotest.(check (list int)) "cancel still transfers resume exactly once" [ 320 ] !dropped;
  Alcotest.(check int) "cancel attempts descriptor close once" 1 !close_count;
  Alcotest.(check int) "cancel never polls" 0 !poll_count;
  Alcotest.(check int)
    "cancel retires registration despite close failure" 0
    (Host_readiness.registration_count registry);
  Host_readiness.shutdown registry ~drop:ignore |> ok;
  Unix.close reader;
  Unix.close writer

let test_reconcile_defensively_retires_direct_cancellation () =
  let reader, writer = Unix.pipe () in
  let scheduler, task = Scheduler_core.create ~scope_path:[ 0 ] ~body_resume:89 |> ok in
  let closed = ref 0 in
  let poll_count = ref 0 in
  let registry = Host_readiness.create ~descriptor_ops:(counting_ops closed poll_count) scheduler in
  let resume = Scheduler_core.checkout scheduler task |> ok in
  ignore (Host_readiness.register registry ~task ~descriptor:reader ~resume |> ok);
  Scheduler_core.request_cancel scheduler task |> ok;
  let _, transferred =
    Scheduler_core.deliver_cancel scheduler ~point:Concurrency_contract.Routed_effect task |> ok
  in
  Alcotest.(check (list int))
    "direct core cancellation transfers resume to its caller" [ 89 ] transferred;
  Host_readiness.reconcile registry |> ok;
  Alcotest.(check int)
    "reconciliation retires stranded duplicate" 0
    (Host_readiness.registration_count registry);
  Alcotest.(check int) "reconciliation closes duplicate once" 1 !closed;
  Alcotest.(check int) "reconciliation never polls" 0 !poll_count;
  Host_readiness.shutdown registry ~drop:ignore |> ok;
  Unix.close reader;
  Unix.close writer

let test_active_shutdown_releases_owned_state_once () =
  let reader, writer = Unix.pipe () in
  let scheduler, task = Scheduler_core.create ~scope_path:[ 0 ] ~body_resume:144 |> ok in
  let closed = ref 0 in
  let poll_count = ref 0 in
  let registry = Host_readiness.create ~descriptor_ops:(counting_ops closed poll_count) scheduler in
  let resume = Scheduler_core.checkout scheduler task |> ok in
  ignore (Host_readiness.register registry ~task ~descriptor:reader ~resume |> ok);
  let dropped = ref [] in
  Host_readiness.shutdown registry ~drop:(fun value -> dropped := value :: !dropped) |> ok;
  Alcotest.(check int) "active shutdown closes its duplicate once" 1 !closed;
  Alcotest.(check (list int)) "active shutdown transfers its resume once" [ 144 ] !dropped;
  Alcotest.(check int)
    "active shutdown owns no registrations" 0
    (Host_readiness.registration_count registry);
  Host_readiness.shutdown registry ~drop:(fun value -> dropped := value :: !dropped) |> ok;
  Alcotest.(check int) "repeated active shutdown does not close twice" 1 !closed;
  Alcotest.(check (list int)) "repeated active shutdown does not drop twice" [ 144 ] !dropped;
  Alcotest.(check int) "shutdown never polls" 0 !poll_count;
  Unix.close reader;
  Unix.close writer

let test_shutdown_continues_after_close_failure () =
  let reader, writer = Unix.pipe () in
  let scheduler, root = Scheduler_core.create ~scope_path:[ 0 ] ~body_resume:233 |> ok in
  let child = Scheduler_core.spawn scheduler ~resume:234 |> ok in
  let close_count = ref 0 in
  let descriptor_ops =
    {
      Host_readiness.duplicate = (fun descriptor -> Unix.dup ~cloexec:true descriptor);
      close =
        (fun descriptor ->
          incr close_count;
          Unix.close descriptor;
          if !close_count = 1 then raise (Unix.Unix_error (Unix.EIO, "close", "injected")));
      poll_readable =
        (fun descriptors ->
          let readable, _, _ = Unix.select descriptors [] [] 0.0 in
          readable);
    }
  in
  let registry = Host_readiness.create ~descriptor_ops scheduler in
  let root_resume = Scheduler_core.checkout scheduler root |> ok in
  ignore (Host_readiness.register registry ~task:root ~descriptor:reader ~resume:root_resume |> ok);
  let child_resume = Scheduler_core.checkout scheduler child |> ok in
  ignore (Host_readiness.register registry ~task:child ~descriptor:reader ~resume:child_resume |> ok);
  let dropped = ref [] in
  Alcotest.(check string)
    "close failure maps to a structured diagnostic" "E0908"
    (Host_readiness.shutdown registry ~drop:(fun value -> dropped := value :: !dropped)
    |> error_code);
  Alcotest.(check int) "shutdown attempted every descriptor close" 2 !close_count;
  Alcotest.(check (list int))
    "shutdown transferred every resume despite close failure" [ 233; 234 ]
    (List.sort Int.compare !dropped);
  Alcotest.(check int)
    "failed close retired all registrations" 0
    (Host_readiness.registration_count registry);
  Host_readiness.shutdown registry ~drop:(fun value -> dropped := value :: !dropped) |> ok;
  Alcotest.(check int) "repeated failed shutdown does not close twice" 2 !close_count;
  Alcotest.(check (list int))
    "repeated failed shutdown does not drop twice" [ 233; 234 ] (List.sort Int.compare !dropped);
  Unix.close reader;
  Unix.close writer

let test_descriptor_refusal_preserves_checked_out_task () =
  let reader, writer = Unix.pipe () in
  Unix.close reader;
  let scheduler, task = Scheduler_core.create ~scope_path:[ 0 ] ~body_resume:55 |> ok in
  let registry = Host_readiness.create scheduler in
  let resume = Scheduler_core.checkout scheduler task |> ok in
  Alcotest.(check string)
    "closed descriptor maps to structured diagnostic" "E0908"
    (Host_readiness.register registry ~task ~descriptor:reader ~resume |> error_code);
  Alcotest.(check int)
    "failed registration owns no descriptor" 0
    (Host_readiness.registration_count registry);
  Alcotest.(check bool)
    "failure left task runnable and checked out" true
    ((view scheduler task).lifecycle = Concurrency_contract.Runnable
    && not (view scheduler task).owns_resume);
  Scheduler_core.suspend_yield scheduler task ~resume |> ok;
  let dropped = ref [] in
  Host_readiness.shutdown registry ~drop:(fun value -> dropped := value :: !dropped) |> ok;
  Alcotest.(check (list int)) "shutdown transfers exactly the remaining resume" [ 55 ] !dropped;
  Unix.close writer

let run () =
  test_live_pipe_wakeup_and_recording ();
  test_cancellation_and_shutdown_release_once ();
  test_strict_replay_never_needs_live_readiness ();
  test_equivalent_fresh_run_replays_recorded_identity ();
  test_poll_close_failure_preserves_all_wakeups ();
  test_replay_close_failure_preserves_wakeup_without_polling ();
  test_cancel_close_failure_preserves_wakeups ();
  test_reconcile_defensively_retires_direct_cancellation ();
  test_active_shutdown_releases_owned_state_once ();
  test_shutdown_continues_after_close_failure ();
  test_descriptor_refusal_preserves_checked_out_task ()
