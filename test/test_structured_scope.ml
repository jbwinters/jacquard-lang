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
  (match
     Structured_scope.with_checkout raised body (fun _ -> raise (Failure "checkout host abort"))
   with
  | exception Failure message when String.equal message "checkout host abort" -> ()
  | exception exn -> Alcotest.failf "wrong checkout exception: %s" (Printexc.to_string exn)
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
  Eval.reject_task_escape ctx ~scope_path:[ 0; 1 ] (Value.VTuple [ outer_task ]) |> ok

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
  test_checkout_bracket_restores_error_and_exception ();
  test_dynamic_escape_graph_scan ();
  QCheck.Test.check_exn prop_recursive_close_restores_baseline

let suite = [ Alcotest.test_case "nested ownership, cleanup, and escape" `Quick run ]
