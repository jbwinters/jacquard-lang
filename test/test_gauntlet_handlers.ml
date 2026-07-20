open Jacquard

let test_resumed_same_op_gives_four_leaves () =
  let h = Test_handlers.make () in
  let v =
    Eval_support.eval_ok h
      "(handle (let nonrec (pvar a) (app (var choose)) (let nonrec (pvar b) (app (var choose)) \
       (tuple (var a) (var b)))) (ret (pvar x) (var x)) (opclause choose () k (tuple (app (var k) \
       (var true)) (app (var k) (var false)))))"
  in
  Alcotest.(check string)
    "full choice tree" "(((true, true), (true, false)), ((false, true), (false, false)))"
    (Value.show v);
  match v with
  | Value.VTuple
      [
        Value.VTuple
          [
            Value.VTuple [ Value.VCon { name = "true"; _ }; Value.VCon { name = "true"; _ } ];
            Value.VTuple [ Value.VCon { name = "true"; _ }; Value.VCon { name = "false"; _ } ];
          ];
        Value.VTuple
          [
            Value.VTuple [ Value.VCon { name = "false"; _ }; Value.VCon { name = "true"; _ } ];
            Value.VTuple [ Value.VCon { name = "false"; _ }; Value.VCon { name = "false"; _ } ];
          ];
      ] ->
      ()
  | _ -> Alcotest.failf "expected exactly four choice leaves, got %s" (Value.show v)

let test_nested_same_op_handler_shadows_outer () =
  let h = Test_handlers.make () in
  Alcotest.(check string)
    "outer-inner-outer" "(1, 2, 1)"
    (Value.show
       (Eval_support.eval_ok h
          "(handle (tuple (app (var choose)) (handle (app (var choose)) (ret (pvar x) (var x)) \
           (opclause choose () k (app (var k) (lit 2)))) (app (var choose))) (ret (pvar x) (var \
           x)) (opclause choose () k (app (var k) (lit 1))))"))

let test_once_clause_same_op_perform_escapes_outward () =
  let h = Test_handlers.make () in
  let source =
    "(handle (handle (app (var signal)) (ret (pvar x) (var x)) "
    ^ "(opclause signal () inner-k (app (var inner-k) (app (var signal))))) "
    ^ "(ret (pvar x) (var x)) (opclause signal () outer-k " ^ "(app (var outer-k) (lit 17))))"
  in
  Alcotest.(check string)
    "outer handler catches the inner Once clause perform" "17"
    (Value.show (Eval_support.eval_ok h source))

let test_once_resumed_continuation_reinstalls_deep_handler () =
  let h = Test_handlers.make () in
  let source =
    "(handle (handle (tuple (app (var signal)) (app (var signal))) "
    ^ "(ret (pvar x) (var x)) (opclause signal () inner-k "
    ^ "(app (var inner-k) (app (var signal))))) (ret (pvar x) (var x)) "
    ^ "(opclause signal () outer-k (app (var outer-k) (app (var bump)))))"
  in
  Alcotest.(check string)
    "each forwarded Once request has an independent affine budget" "(1, 2)"
    (Value.show (Eval_support.eval_ok h source));
  Alcotest.(check int) "outer handler sees two dynamic requests" 2 !(h.bumps)

let test_return_clause_is_outside_handled_region () =
  let h = Test_handlers.make () in
  match
    Eval_support.eval_err h
      "(handle (lit 1) (ret (pvar x) (app (var choose))) (opclause choose () k (app (var k) (lit \
       9))))"
  with
  | Runtime_err.Unhandled { effect_ = "choice"; op = "choose" } -> ()
  | e -> Alcotest.failf "expected unhandled choice.choose, got %s" (Runtime_err.to_string e)

let test_abort_skips_pending_argument_evaluation () =
  let h = Test_handlers.make () in
  Alcotest.(check string)
    "abort result" "999"
    (Value.show
       (Eval_support.eval_ok h
          "(handle (app (var add) (app (var abort)) (app (var bump))) (ret (pvar x) (var x)) \
           (opclause abort () k (lit 999)))"));
  Alcotest.(check int) "right argument not evaluated" 0 !(h.bumps)

let test_escaped_resumption_is_multishot_and_immutable () =
  let h = Test_handlers.make () in
  Alcotest.(check string)
    "escaped resume twice" "(1, 2)"
    (Value.show
       (Eval_support.eval_ok h
          "(let nonrec (pvar r) (handle (app (var tick)) (ret (pvar x) (var x)) (opclause tick () \
           k (var k))) (tuple (app (var r) (lit 1)) (app (var r) (lit 2))))"))

let test_exhaustive_scheduler_choose_keeps_once_world_local () =
  let store, ctx = Eval_support.make_prelude_ctx () in
  let source =
    "(let nonrec (pwild)   (app (var async.spawn)     (lam () (let nonrec (pwild) (app (var \
     async.yield)) (lit 1))))   (lit 0))"
  in
  let expr =
    match Reader.parse_one ~file:"gauntlet-exhaustive.jqd" source with
    | Error diagnostics -> Eval_support.fail_diags "parse exhaustive gauntlet" diagnostics
    | Ok form -> (
        match Kernel.expr_of_form form with
        | Error diagnostics -> Eval_support.fail_diags "validate exhaustive gauntlet" diagnostics
        | Ok expr -> (
            match Resolve.resolve_expr (Store.names_view store) expr with
            | Ok expr -> expr
            | Error diagnostics -> Eval_support.fail_diags "resolve exhaustive gauntlet" diagnostics
            ))
  in
  match Exhaustive_schedule.run_expr ctx ~policy:Concurrency_contract.Collect expr with
  | Error diagnostics -> Eval_support.fail_diags "run exhaustive gauntlet" diagnostics
  | Ok report ->
      Alcotest.(check int) "one yield has three hand-counted schedules" 3 report.explored;
      Alcotest.(check bool)
        "multi-shot choice search is complete" true
        (report.completeness = Exhaustive_schedule.Complete);
      List.iter
        (fun world ->
          match world.Exhaustive_schedule.result with
          | Ok (Value.VInt 0) -> ()
          | Error Runtime_err.Once_resumed_twice ->
              Alcotest.fail "schedule choice duplicated an affine Async continuation"
          | Error error -> Alcotest.failf "schedule world failed: %s" (Runtime_err.to_string error)
          | Ok value -> Alcotest.failf "unexpected schedule result: %s" (Value.show value))
        report.worlds

let suite =
  [
    Alcotest.test_case "resumed same-op choose gives four leaves" `Quick
      test_resumed_same_op_gives_four_leaves;
    Alcotest.test_case "nested same-op handler shadows outer" `Quick
      test_nested_same_op_handler_shadows_outer;
    Alcotest.test_case "Once clause same-op perform escapes outward" `Quick
      test_once_clause_same_op_perform_escapes_outward;
    Alcotest.test_case "Once resumed continuation reinstalls deep handler" `Quick
      test_once_resumed_continuation_reinstalls_deep_handler;
    Alcotest.test_case "return clause is outside handled region" `Quick
      test_return_clause_is_outside_handled_region;
    Alcotest.test_case "abort skips pending argument evaluation" `Quick
      test_abort_skips_pending_argument_evaluation;
    Alcotest.test_case "escaped resumption is multi-shot and immutable" `Quick
      test_escaped_resumption_is_multishot_and_immutable;
    Alcotest.test_case "exhaustive schedule Choose keeps Once world-local" `Quick
      test_exhaustive_scheduler_choose_keeps_once_world_local;
  ]
