open Jacquard

let ok = function
  | Ok value -> value
  | Error diagnostics ->
      Alcotest.failf "unexpected structured-scope diagnostic: %s"
        (String.concat "\n" (List.map Diag.to_string diagnostics))

let error_code = function
  | Error ({ Diag.code; _ } :: _) -> code
  | Error [] -> Alcotest.fail "structured scope returned an empty diagnostic list"
  | Ok _ -> Alcotest.fail "structured-scope operation unexpectedly succeeded"

let check_zero_metrics label scope =
  let metrics = Structured_scope.metrics scope in
  Alcotest.(check int) (label ^ " open scopes") 0 metrics.open_scopes;
  Alcotest.(check int) (label ^ " live tasks") 0 metrics.live_tasks;
  Alcotest.(check int) (label ^ " runnable tasks") 0 metrics.runnable_tasks;
  Alcotest.(check int) (label ^ " owned resumes") 0 metrics.owned_resumes

let test_join_and_forgotten_child_cleanup () =
  let scope, body = Structured_scope.create ~body_resume:0 |> ok in
  let child = Structured_scope.spawn scope ~resume:1 |> ok in
  ignore (Structured_scope.checkout scope body |> ok);
  let outcome, awakened =
    Structured_scope.await scope ~waiter:body ~target:child ~resume:10 |> ok
  in
  Alcotest.(check bool) "body waits for child" true (outcome = Scheduler_core.Await_suspended);
  ignore (Structured_scope.checkout scope child |> ok);
  let awakened_after_completion = Structured_scope.complete scope child 42 |> ok in
  Alcotest.(check int) "one join wakes" 1 (List.length awakened_after_completion);
  Alcotest.(check bool) "the joined body wakes" true (awakened_after_completion = [ body ]);
  Alcotest.(check int) "no deadlock wakeups" 0 (List.length awakened);
  let forgotten = Structured_scope.spawn scope ~resume:2 |> ok in
  ignore forgotten;
  let dropped = ref [] in
  Structured_scope.close scope ~reason:Structured_scope.Normal ~escaping:[] ~drop:(fun resume ->
      dropped := resume :: !dropped)
  |> ok;
  Alcotest.(check (list int))
    "remaining tokens explicitly dropped" [ 2; 10 ] (List.sort Int.compare !dropped);
  check_zero_metrics "normal close" scope;
  Alcotest.(check string)
    "stale spawn" "E0907"
    (Structured_scope.spawn scope ~resume:99 |> error_code);
  Alcotest.(check string) "stale handle" "E0907" (Structured_scope.inspect scope body |> error_code)

let test_nested_lineage_and_recursive_cleanup () =
  let root, root_body = Structured_scope.create ~body_resume:1 |> ok in
  ignore (Structured_scope.spawn root ~resume:2 |> ok);
  let nested, nested_body = Structured_scope.nest root ~body_resume:3 |> ok in
  ignore (Structured_scope.spawn nested ~resume:4 |> ok);
  let grandchild, _ = Structured_scope.nest nested ~body_resume:5 |> ok in
  Alcotest.(check (list int)) "root lineage" [ 0 ] (Structured_scope.scope_path root);
  Alcotest.(check (list int)) "nested lineage" [ 0; 1 ] (Structured_scope.scope_path nested);
  Alcotest.(check (list int))
    "grandchild lineage" [ 0; 1; 1 ]
    (Structured_scope.scope_path grandchild);
  Alcotest.(check string)
    "cross-scope task use" "E0907"
    (Structured_scope.inspect root nested_body |> error_code);
  let before = Structured_scope.metrics root in
  Alcotest.(check int) "three open scopes" 3 before.open_scopes;
  Alcotest.(check int) "five live tasks" 5 before.live_tasks;
  let dropped = ref [] in
  Structured_scope.close root ~reason:Structured_scope.Aborted ~escaping:[] ~drop:(fun resume ->
      dropped := resume :: !dropped)
  |> ok;
  Alcotest.(check (list int))
    "recursive descendant cleanup" [ 1; 2; 3; 4; 5 ] (List.sort Int.compare !dropped);
  check_zero_metrics "recursive abort" root;
  Alcotest.(check string)
    "nested handle is stale" "E0907"
    (Structured_scope.id nested nested_body |> error_code);
  ignore root_body

let test_returned_stored_and_ancestor_handles () =
  let escaped, _ = Structured_scope.create ~body_resume:10 |> ok in
  let child = Structured_scope.spawn escaped ~resume:11 |> ok in
  let dropped = ref 0 in
  Alcotest.(check string)
    "returned child escape" "E0907"
    (Structured_scope.close escaped ~reason:Structured_scope.Normal ~escaping:[ child ]
       ~drop:(fun _ -> incr dropped)
    |> error_code);
  Alcotest.(check int) "escape still cleans every resume" 2 !dropped;
  check_zero_metrics "returned escape" escaped;
  let root, root_body = Structured_scope.create ~body_resume:20 |> ok in
  let nested, _ = Structured_scope.nest root ~body_resume:21 |> ok in
  Structured_scope.close nested ~reason:Structured_scope.Normal ~escaping:[ root_body ] ~drop:ignore
  |> ok;
  ignore (Structured_scope.inspect root root_body |> ok);
  Structured_scope.close root ~reason:Structured_scope.Normal ~escaping:[] ~drop:ignore |> ok;
  let left, _ = Structured_scope.create ~body_resume:30 |> ok in
  let _, foreign = Structured_scope.create ~body_resume:31 |> ok in
  Alcotest.(check string)
    "stored foreign handle" "E0907"
    (Structured_scope.close left ~reason:Structured_scope.Normal ~escaping:[ foreign ] ~drop:ignore
    |> error_code)

let abort_diagnostic = Diag.error ~code:"E9998" "scope body aborted"

let test_bracket_cleans_normal_abort_and_exception () =
  let normal, _ = Structured_scope.create ~body_resume:1 |> ok in
  let normal_result =
    Structured_scope.protect normal ~drop:ignore
      ~escapes:(fun _ -> [])
      (fun scope ->
        ignore (Structured_scope.spawn scope ~resume:2 |> ok);
        Ok 42)
    |> ok
  in
  Alcotest.(check int) "normal bracket result" 42 normal_result;
  check_zero_metrics "normal bracket" normal;
  let aborted, _ = Structured_scope.create ~body_resume:3 |> ok in
  Alcotest.(check string)
    "abort diagnostic preserved" "E9998"
    (Structured_scope.protect aborted ~drop:ignore
       ~escapes:(fun _ -> [])
       (fun scope ->
         ignore (Structured_scope.spawn scope ~resume:4 |> ok);
         Error [ abort_diagnostic ])
    |> error_code);
  check_zero_metrics "aborted bracket" aborted;
  let raised, _ = Structured_scope.create ~body_resume:5 |> ok in
  (match
     Structured_scope.protect raised ~drop:ignore
       ~escapes:(fun _ -> [])
       (fun scope ->
         ignore (Structured_scope.spawn scope ~resume:6 |> ok);
         raise (Failure "host abort"))
   with
  | exception Failure message when String.equal message "host abort" -> ()
  | exception exn -> Alcotest.failf "wrong host exception: %s" (Printexc.to_string exn)
  | Ok _ | Error _ -> Alcotest.fail "host exception was swallowed");
  check_zero_metrics "exception bracket" raised;
  let escaping, _ = Structured_scope.create ~body_resume:7 |> ok in
  Alcotest.(check string)
    "bracket returned-handle escape" "E0907"
    (Structured_scope.protect escaping ~drop:ignore
       ~escapes:(fun task -> [ task ])
       (fun scope -> Structured_scope.spawn scope ~resume:8)
    |> error_code);
  check_zero_metrics "escaping bracket" escaping

let test_cleanup_exception_precedence () =
  let normal, _ = Structured_scope.create ~body_resume:1 |> ok in
  let normal_drops = ref 0 in
  (match
     Structured_scope.protect normal
       ~drop:(fun _ ->
         incr normal_drops;
         raise (Failure "normal cleanup failed"))
       ~escapes:(fun _ -> [])
       (fun scope ->
         ignore (Structured_scope.spawn scope ~resume:2 |> ok);
         ignore (Structured_scope.spawn scope ~resume:3 |> ok);
         Ok 42)
   with
  | exception Failure message when String.equal message "normal cleanup failed" -> ()
  | exception exn -> Alcotest.failf "wrong normal cleanup exception: %s" (Printexc.to_string exn)
  | Ok _ | Error _ -> Alcotest.fail "normal cleanup exception was swallowed");
  Alcotest.(check int) "normal cleanup attempts every drop" 3 !normal_drops;
  check_zero_metrics "normal cleanup exception" normal;
  let aborted, _ = Structured_scope.create ~body_resume:4 |> ok in
  let aborted_drops = ref 0 in
  Alcotest.(check string)
    "body diagnostic precedes cleanup exception" "E9998"
    (Structured_scope.protect aborted
       ~drop:(fun _ ->
         incr aborted_drops;
         raise (Failure "aborted cleanup failed"))
       ~escapes:(fun _ -> [])
       (fun scope ->
         ignore (Structured_scope.spawn scope ~resume:5 |> ok);
         Error [ abort_diagnostic ])
    |> error_code);
  Alcotest.(check int) "aborted cleanup attempts every drop" 2 !aborted_drops;
  check_zero_metrics "aborted cleanup exception" aborted;
  let raised, _ = Structured_scope.create ~body_resume:6 |> ok in
  let raised_drops = ref 0 in
  let backtraces_were_enabled = Printexc.backtrace_status () in
  Printexc.record_backtrace true;
  Fun.protect
    ~finally:(fun () -> Printexc.record_backtrace backtraces_were_enabled)
    (fun () ->
      let body_exception = Failure "host body failed" in
      let body_backtrace =
        match raise body_exception with
        | exception caught when caught == body_exception -> Printexc.get_raw_backtrace ()
        | _ -> Alcotest.fail "failed to capture host body backtrace"
      in
      match
        Structured_scope.protect raised
          ~drop:(fun _ ->
            incr raised_drops;
            raise (Failure "raised cleanup failed"))
          ~escapes:(fun _ -> [])
          (fun scope ->
            ignore (Structured_scope.spawn scope ~resume:7 |> ok);
            Printexc.raise_with_backtrace body_exception body_backtrace)
      with
      | exception caught when caught == body_exception ->
          let original = Printexc.raw_backtrace_to_string body_backtrace in
          let reraised = Printexc.raw_backtrace_to_string (Printexc.get_raw_backtrace ()) in
          Alcotest.(check bool)
            "host backtrace precedes cleanup backtrace" true
            (String.starts_with ~prefix:original reraised)
      | exception exn ->
          Alcotest.failf "cleanup masked the host exception: %s" (Printexc.to_string exn)
      | Ok _ | Error _ -> Alcotest.fail "host exception was swallowed");
  Alcotest.(check int) "raised cleanup attempts every drop" 2 !raised_drops;
  check_zero_metrics "raised cleanup exception" raised

let test_checkout_bracket_restores_error_and_exception () =
  let returned, body = Structured_scope.create ~body_resume:40 |> ok in
  Alcotest.(check int)
    "unsettled checkout result is preserved" 40
    (Structured_scope.with_checkout returned body (fun resume -> Ok resume) |> ok);
  Alcotest.(check bool)
    "normal return restores unsettled ownership" true
    (Structured_scope.inspect returned body |> ok).owns_resume;
  Structured_scope.close returned ~reason:Structured_scope.Normal ~escaping:[] ~drop:ignore |> ok;
  check_zero_metrics "checkout normal return" returned;
  let aborted, body = Structured_scope.create ~body_resume:41 |> ok in
  Alcotest.(check string)
    "checkout error is preserved" "E9998"
    (Structured_scope.with_checkout aborted body (fun _ -> Error [ abort_diagnostic ]) |> error_code);
  Alcotest.(check bool)
    "checkout error restores scheduler ownership" true
    (Structured_scope.inspect aborted body |> ok).owns_resume;
  let dropped = ref [] in
  Structured_scope.close aborted ~reason:Structured_scope.Aborted ~escaping:[] ~drop:(fun resume ->
      dropped := resume :: !dropped)
  |> ok;
  Alcotest.(check (list int)) "restored error token is dropped" [ 41 ] !dropped;
  check_zero_metrics "checkout error" aborted;
  let raised, body = Structured_scope.create ~body_resume:42 |> ok in
  let checkout_exception = Failure "checkout host abort" in
  let backtraces_were_enabled = Printexc.backtrace_status () in
  Printexc.record_backtrace true;
  Fun.protect
    ~finally:(fun () -> Printexc.record_backtrace backtraces_were_enabled)
    (fun () ->
      let checkout_backtrace =
        match raise checkout_exception with
        | exception caught when caught == checkout_exception -> Printexc.get_raw_backtrace ()
        | _ -> Alcotest.fail "failed to capture checkout exception backtrace"
      in
      match
        Structured_scope.with_checkout raised body (fun _ ->
            Printexc.raise_with_backtrace checkout_exception checkout_backtrace)
      with
      | exception caught when caught == checkout_exception ->
          let original = Printexc.raw_backtrace_to_string checkout_backtrace in
          let reraised = Printexc.raw_backtrace_to_string (Printexc.get_raw_backtrace ()) in
          Alcotest.(check bool)
            "checkout exception keeps its original backtrace" true
            (String.starts_with ~prefix:original reraised)
      | exception exn ->
          Alcotest.failf "checkout replaced the physical exception: %s" (Printexc.to_string exn)
      | Ok _ | Error _ -> Alcotest.fail "checkout host exception was swallowed");
  Alcotest.(check bool)
    "checkout exception restores scheduler ownership" true
    (Structured_scope.inspect raised body |> ok).owns_resume;
  let dropped = ref [] in
  Structured_scope.close raised ~reason:Structured_scope.Raised ~escaping:[] ~drop:(fun resume ->
      dropped := resume :: !dropped)
  |> ok;
  Alcotest.(check (list int)) "restored exception token is dropped" [ 42 ] !dropped;
  check_zero_metrics "checkout exception" raised

let hostile_task_for_ctx ctx ~scope_path ~spawn_index =
  let payload = Obj.new_block 0 3 in
  Obj.set_field payload 0 (Obj.field (Obj.repr ctx) 1);
  Obj.set_field payload 1 (Obj.repr scope_path);
  Obj.set_field payload 2 (Obj.repr spawn_index);
  Value.VTask (Obj.obj payload)

let hostile_channel_for_ctx ctx ~scope_path ~open_index =
  let id = Obj.new_block 0 2 in
  Obj.set_field id 0 (Obj.repr scope_path);
  Obj.set_field id 1 (Obj.repr open_index);
  let payload = Obj.new_block 0 2 in
  Obj.set_field payload 0 (Obj.field (Obj.repr ctx) 1);
  Obj.set_field payload 1 id;
  Value.VChannel (Obj.obj payload)

let expect_escape label ctx ~scope_path value =
  Alcotest.(check string) label "E0907" (Eval.reject_task_escape ctx ~scope_path value |> error_code)

let test_dynamic_escape_graph_scan () =
  let harness = Eval_support.make () in
  let ctx = harness.ctx in
  let task = hostile_task_for_ctx ctx ~scope_path:[ 0; 1 ] ~spawn_index:2 in
  expect_escape "tuple escape" ctx ~scope_path:[ 0 ] (Value.VTuple [ task ]);
  expect_escape "constructor escape" ctx ~scope_path:[ 0 ]
    (Value.VCon { con = Hash.of_string "hidden-task"; name = "hidden"; args = [ task ] });
  let task_cell = ref task in
  let self_cell = ref Value.unit_v in
  let environment =
    Value.Env.empty |> Value.Env.add "task" task_cell |> Value.Env.add "self" self_cell
  in
  let closure_scope = Value.{ empty_scope with env = environment } in
  let closure =
    Value.VClosure
      { scope = closure_scope; params = []; body = Kernel.{ it = Var "self"; meta = Meta.empty } }
  in
  self_cell := closure;
  expect_escape "cyclic closure storage escape" ctx ~scope_path:[ 0 ] closure;
  let resume =
    Value.VResume [ Value.FTuple { done_rev = [ task ]; pending = []; scope = Value.empty_scope } ]
  in
  expect_escape "resumption escape" ctx ~scope_path:[ 0 ] resume;
  let outer_task = hostile_task_for_ctx ctx ~scope_path:[ 0 ] ~spawn_index:3 in
  Eval.reject_task_escape ctx ~scope_path:[ 0; 1 ] (Value.VTuple [ outer_task ]) |> ok;
  let channel = hostile_channel_for_ctx ctx ~scope_path:[ 0; 1 ] ~open_index:2 in
  Eval.validate_channel_value ctx ~scope_path:[ 0; 1 ] channel |> ok |> ignore;
  List.iter
    (fun (label, path) ->
      Alcotest.(check string)
        label "E0907"
        (Eval.validate_channel_value ctx ~scope_path:path channel |> error_code))
    [
      ("channel parent scope", [ 0 ]);
      ("channel child scope", [ 0; 1; 1 ]);
      ("channel sibling scope", [ 0; 2 ]);
    ];
  let foreign_ctx = (Eval_support.make ()).ctx in
  Alcotest.(check string)
    "channel foreign run" "E0907"
    (Eval.validate_channel_value foreign_ctx ~scope_path:[ 0; 1 ] channel |> error_code);
  let malformed = hostile_channel_for_ctx ctx ~scope_path:[] ~open_index:(-1) in
  Alcotest.(check string)
    "forged malformed channel ID" "E0907"
    (Eval.validate_channel_value ctx ~scope_path:[] malformed |> error_code);
  expect_escape "channel tuple escape" ctx ~scope_path:[ 0 ] (Value.VTuple [ channel ]);
  let channel_resume =
    Value.VResume
      [ Value.FTuple { done_rev = [ channel ]; pending = []; scope = Value.empty_scope } ]
  in
  expect_escape "channel resumption escape" ctx ~scope_path:[ 0 ] channel_resume

let map_channel_resume resume = function
  | Structured_scope.Channel_send_ok -> resume + 1000
  | Structured_scope.Channel_recv_ok value -> resume + String.length value
  | Structured_scope.Channel_closed -> resume + 3000

let opened_channel scope capacity =
  match Structured_scope.channel_open scope ~capacity |> ok with
  | Structured_scope.Channel_opened channel -> channel
  | Structured_scope.Channel_invalid_capacity rejected ->
      Alcotest.failf "capacity %d unexpectedly rejected" rejected

let test_scoped_channel_ownership_and_cancellation () =
  let scope, body = Structured_scope.create ~body_resume:10 |> ok in
  (match Structured_scope.channel_open scope ~capacity:(-1) |> ok with
  | Structured_scope.Channel_invalid_capacity -1 -> ()
  | _ -> Alcotest.fail "negative channel capacity was not a typed refusal");
  let channel = opened_channel scope 0 in
  let senders =
    List.init 3 (fun index -> Structured_scope.spawn scope ~resume:(20 + index) |> ok)
  in
  List.iteri
    (fun index sender ->
      let resume = Structured_scope.checkout scope sender |> ok in
      match
        Structured_scope.channel_send scope ~task:sender ~channel ~resume
          ~value:(string_of_int (index + 1))
          ~map_resume:map_channel_resume
        |> ok
      with
      | Structured_scope.Channel_suspended -> ()
      | Structured_scope.Channel_continues _ -> Alcotest.fail "rendezvous sender did not suspend")
    senders;
  let middle = List.nth senders 1 in
  Structured_scope.request_cancel scope middle |> ok;
  let dropped = ref [] in
  let awakened =
    Structured_scope.deliver_cancel scope ~point:Concurrency_contract.Routed_effect middle
      ~drop:(fun resume -> dropped := resume :: !dropped)
    |> ok
  in
  Alcotest.(check (list int)) "middle blocked resume dropped once" [ 21 ] !dropped;
  Alcotest.(check int) "channel cancellation wakes nobody" 0 (List.length awakened);
  let receive expected =
    let resume = Structured_scope.checkout scope body |> ok in
    match
      Structured_scope.channel_recv scope ~task:body ~channel ~resume ~map_resume:map_channel_resume
      |> ok
    with
    | Structured_scope.Channel_suspended -> Alcotest.fail "surviving sender was stranded"
    | Structured_scope.Channel_continues { resume; awakened = [ sender ] } ->
        Alcotest.(check string)
          "sender FIFO" expected
          (Structured_scope.id scope sender |> ok |> Concurrency_contract.trace_task_id);
        Structured_scope.suspend_yield scope body ~resume |> ok;
        Structured_scope.wake_yielded scope body |> ok
    | Structured_scope.Channel_continues _ -> Alcotest.fail "wrong channel wakeup cardinality"
  in
  receive "0#1";
  receive "0#3";
  let nested, nested_body = Structured_scope.nest scope ~body_resume:40 |> ok in
  Alcotest.(check string)
    "nested task cannot use parent channel" "E0907"
    (Structured_scope.with_checkout nested nested_body (fun resume ->
         Structured_scope.channel_send nested ~task:nested_body ~channel ~resume ~value:"escape"
           ~map_resume:map_channel_resume)
    |> error_code);
  Alcotest.(check bool)
    "foreign-handle refusal preserves continuation" true
    (Structured_scope.inspect nested nested_body |> ok).owns_resume;
  Structured_scope.close scope ~reason:Structured_scope.Normal ~escaping:[] ~drop:ignore |> ok;
  check_zero_metrics "channel cancellation close" scope

let test_closed_channel_remains_live_until_scope_teardown () =
  let scope, body = Structured_scope.create ~body_resume:1 |> ok in
  let channel = opened_channel scope 0 in
  let close_once () =
    let resume = Structured_scope.checkout scope body |> ok in
    match
      Structured_scope.channel_close scope ~task:body ~channel ~resume
        ~map_resume:map_channel_resume ~map_closer:(fun resume -> resume + 2000)
      |> ok
    with
    | Structured_scope.Channel_suspended -> Alcotest.fail "channel.close suspended"
    | Structured_scope.Channel_continues { resume; awakened = [] } ->
        Structured_scope.suspend_yield scope body ~resume |> ok;
        Structured_scope.wake_yielded scope body |> ok
    | Structured_scope.Channel_continues _ -> Alcotest.fail "empty close woke a task"
  in
  close_once ();
  close_once ();
  Structured_scope.close scope ~reason:Structured_scope.Normal ~escaping:[] ~drop:ignore |> ok;
  Alcotest.(check string)
    "teardown makes channel operation stale" "E0907"
    (Structured_scope.with_checkout scope body (fun resume ->
         Structured_scope.channel_send scope ~task:body ~channel ~resume ~value:"stale"
           ~map_resume:map_channel_resume)
    |> error_code)

let test_channel_transition_preflight_is_atomic () =
  let scope, receiver = Structured_scope.create ~body_resume:10 |> ok in
  let channel = opened_channel scope 0 in
  Alcotest.(check string)
    "owned caller resume rejects receive" "E0908"
    (Structured_scope.channel_recv scope ~task:receiver ~channel ~resume:99
       ~map_resume:map_channel_resume
    |> error_code);
  Alcotest.(check bool)
    "invalid caller lifecycle preserves resume" true
    (Structured_scope.inspect scope receiver |> ok).owns_resume;
  let receiver_resume = Structured_scope.checkout scope receiver |> ok in
  (match
     Structured_scope.channel_recv scope ~task:receiver ~channel ~resume:receiver_resume
       ~map_resume:map_channel_resume
     |> ok
   with
  | Structured_scope.Channel_suspended -> ()
  | Structured_scope.Channel_continues _ -> Alcotest.fail "receiver did not suspend");
  let sender = Structured_scope.spawn scope ~resume:20 |> ok in
  let mapper_raised =
    match
      Structured_scope.with_checkout scope sender (fun resume ->
          Structured_scope.channel_send scope ~task:sender ~channel ~resume ~value:"first"
            ~map_resume:(fun _ _ -> raise Exit))
    with
    | exception Exit -> true
    | Ok _ | Error _ -> false
  in
  Alcotest.(check bool) "raising waiter mapper propagates" true mapper_raised;
  Alcotest.(check bool)
    "raising mapper leaves receiver suspended" true
    ((Structured_scope.inspect scope receiver |> ok).lifecycle = Concurrency_contract.Suspended);
  let transition =
    Structured_scope.with_checkout scope sender (fun resume ->
        Structured_scope.channel_send scope ~task:sender ~channel ~resume ~value:"second"
          ~map_resume:map_channel_resume)
    |> ok
  in
  (match transition with
  | Structured_scope.Channel_continues { awakened = [ awakened ]; _ } ->
      Alcotest.(check string)
        "the original receiver wakes once" "0#0"
        (Structured_scope.id scope awakened |> ok |> Concurrency_contract.trace_task_id)
  | Structured_scope.Channel_suspended -> Alcotest.fail "valid rendezvous sender suspended"
  | Structured_scope.Channel_continues _ -> Alcotest.fail "rendezvous wake count changed");
  let later = Structured_scope.spawn scope ~resume:30 |> ok in
  (match
     Structured_scope.with_checkout scope later (fun resume ->
         Structured_scope.channel_send scope ~task:later ~channel ~resume ~value:"later"
           ~map_resume:map_channel_resume)
     |> ok
   with
  | Structured_scope.Channel_suspended -> ()
  | Structured_scope.Channel_continues _ ->
      Alcotest.fail "a rejected receive or mapper left a phantom receiver");
  Structured_scope.close scope ~reason:Structured_scope.Normal ~escaping:[] ~drop:ignore |> ok;
  check_zero_metrics "atomic channel preflight" scope

let scheduler_of_scope_for_test scope =
  (Obj.obj (Obj.field (Obj.repr scope) 0) : (int, string) Scheduler_core.t)

let test_channel_close_preflights_every_waiter () =
  let scope, body = Structured_scope.create ~body_resume:1 |> ok in
  let channel = opened_channel scope 0 in
  let first = Structured_scope.spawn scope ~resume:10 |> ok in
  let second = Structured_scope.spawn scope ~resume:20 |> ok in
  let block sender value =
    match
      Structured_scope.with_checkout scope sender (fun resume ->
          Structured_scope.channel_send scope ~task:sender ~channel ~resume ~value
            ~map_resume:map_channel_resume)
      |> ok
    with
    | Structured_scope.Channel_suspended -> ()
    | Structured_scope.Channel_continues _ -> Alcotest.fail "rendezvous sender did not block"
  in
  block first "first";
  block second "second";
  let scheduler = scheduler_of_scope_for_test scope in
  let channel_id =
    match (Scheduler_core.inspect scheduler second |> ok).suspension with
    | Some (Scheduler_core.Channel_sending id) -> id
    | _ -> Alcotest.fail "second sender lost its channel suspension"
  in
  Scheduler_core.wake_channel_with scheduler second ~channel:channel_id ~map_resume:(fun resume ->
      Ok resume)
  |> ok;
  let second_resume = Scheduler_core.checkout scheduler second |> ok in
  let wrong_channel = Channel_contract.channel_id ~scope_path:[ 0 ] ~open_index:99 in
  Scheduler_core.suspend_channel scheduler second ~channel:wrong_channel ~direction:`Send
    ~resume:second_resume
  |> ok;
  Alcotest.(check string)
    "second invalid close wake rejects atomically" "E0908"
    (Structured_scope.with_checkout scope body (fun resume ->
         Structured_scope.channel_close scope ~task:body ~channel ~resume
           ~map_resume:map_channel_resume ~map_closer:Fun.id)
    |> error_code);
  Alcotest.(check bool)
    "first waiter was not partially woken" true
    ((Structured_scope.inspect scope first |> ok).lifecycle = Concurrency_contract.Suspended);
  let third = Structured_scope.spawn scope ~resume:30 |> ok in
  (match
     Structured_scope.with_checkout scope third (fun resume ->
         Structured_scope.channel_send scope ~task:third ~channel ~resume ~value:"third"
           ~map_resume:map_channel_resume)
     |> ok
   with
  | Structured_scope.Channel_suspended -> ()
  | Structured_scope.Channel_continues _ -> Alcotest.fail "failed close still closed the channel");
  Structured_scope.close scope ~reason:Structured_scope.Normal ~escaping:[] ~drop:ignore |> ok;
  check_zero_metrics "all-waiter close preflight" scope

let test_channel_cancellation_preflight_and_drop_exception () =
  let scope, _ = Structured_scope.create ~body_resume:1 |> ok in
  let channel = opened_channel scope 0 in
  let sender = Structured_scope.spawn scope ~resume:20 |> ok in
  (match
     Structured_scope.with_checkout scope sender (fun resume ->
         Structured_scope.channel_send scope ~task:sender ~channel ~resume ~value:"pending"
           ~map_resume:map_channel_resume)
     |> ok
   with
  | Structured_scope.Channel_suspended -> ()
  | Structured_scope.Channel_continues _ -> Alcotest.fail "sender did not block");
  let dropped = ref 0 in
  let awakened =
    Structured_scope.deliver_cancel scope ~point:Concurrency_contract.Routed_effect sender
      ~drop:(fun _ -> incr dropped)
    |> ok
  in
  Alcotest.(check int) "no-request delivery wakes nobody" 0 (List.length awakened);
  Alcotest.(check int) "no-request delivery drops nothing" 0 !dropped;
  Alcotest.(check bool)
    "no-request delivery preserves channel suspension" true
    ((Structured_scope.inspect scope sender |> ok).lifecycle = Concurrency_contract.Suspended);
  Structured_scope.request_cancel scope sender |> ok;
  let drop_raised =
    match
      Structured_scope.deliver_cancel scope ~point:Concurrency_contract.Routed_effect sender
        ~drop:(fun _ -> raise Exit)
    with
    | exception Exit -> true
    | Ok _ | Error _ -> false
  in
  Alcotest.(check bool) "drop exception propagates after transfer" true drop_raised;
  Alcotest.(check bool)
    "raising drop still terminalizes exactly once" true
    ((Structured_scope.inspect scope sender |> ok).result = Some Concurrency_contract.Cancelled);
  let duplicate =
    Structured_scope.deliver_cancel scope ~point:Concurrency_contract.Routed_effect sender
      ~drop:(fun _ -> incr dropped)
    |> ok
  in
  Alcotest.(check int) "duplicate cancellation wakes nobody" 0 (List.length duplicate);
  Alcotest.(check int) "duplicate cancellation drops nothing" 0 !dropped;
  Structured_scope.close scope ~reason:Structured_scope.Normal ~escaping:[] ~drop:ignore |> ok;
  check_zero_metrics "channel cancellation preflight" scope

let test_channel_open_refusal_domains () =
  let exhausted, _ = Structured_scope.create ~body_resume:1 |> ok in
  Obj.set_field (Obj.repr exhausted) 3 (Obj.repr (Int64.to_int 0x1_0000_0000L));
  Alcotest.(check string)
    "ChannelId exhaustion is scheduler refusal" "E0908"
    (Structured_scope.channel_open exhausted ~capacity:1 |> error_code);
  Obj.set_field (Obj.repr exhausted) 3 (Obj.repr 0);
  ignore (opened_channel exhausted 1);
  Structured_scope.close exhausted ~reason:Structured_scope.Normal ~escaping:[] ~drop:ignore |> ok;
  Alcotest.(check string)
    "closed scope is not invalid capacity" "E0907"
    (Structured_scope.channel_open exhausted ~capacity:1 |> error_code)

let prop_recursive_close_restores_baseline =
  QCheck.Test.make ~count:200 ~name:"recursive scope close restores every ownership counter"
    QCheck.nat_small (fun seed ->
      let depth = seed mod 16 in
      let root, _ = Structured_scope.create ~body_resume:0 |> ok in
      let current = ref root in
      for index = 1 to depth do
        let child, _ = Structured_scope.nest !current ~body_resume:((index * 2) - 1) |> ok in
        ignore (Structured_scope.spawn child ~resume:(index * 2) |> ok);
        current := child
      done;
      let dropped = ref 0 in
      Structured_scope.close root ~reason:Structured_scope.Normal ~escaping:[] ~drop:(fun _ ->
          incr dropped)
      |> ok;
      let after = Structured_scope.metrics root in
      !dropped = (2 * depth) + 1
      && after.open_scopes = 0 && after.live_tasks = 0 && after.runnable_tasks = 0
      && after.owned_resumes = 0)

let run () =
  test_join_and_forgotten_child_cleanup ();
  test_nested_lineage_and_recursive_cleanup ();
  test_returned_stored_and_ancestor_handles ();
  test_bracket_cleans_normal_abort_and_exception ();
  test_cleanup_exception_precedence ();
  test_checkout_bracket_restores_error_and_exception ();
  test_dynamic_escape_graph_scan ();
  test_scoped_channel_ownership_and_cancellation ();
  test_closed_channel_remains_live_until_scope_teardown ();
  test_channel_transition_preflight_is_atomic ();
  test_channel_close_preflights_every_waiter ();
  test_channel_cancellation_preflight_and_drop_exception ();
  test_channel_open_refusal_domains ();
  QCheck.Test.check_exn prop_recursive_close_restores_baseline

let suite = [ Alcotest.test_case "nested ownership, cleanup, and escape" `Quick run ]
