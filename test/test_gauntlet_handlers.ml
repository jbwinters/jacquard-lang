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

let suite =
  [
    Alcotest.test_case "resumed same-op choose gives four leaves" `Quick
      test_resumed_same_op_gives_four_leaves;
    Alcotest.test_case "nested same-op handler shadows outer" `Quick
      test_nested_same_op_handler_shadows_outer;
    Alcotest.test_case "return clause is outside handled region" `Quick
      test_return_clause_is_outside_handled_region;
    Alcotest.test_case "abort skips pending argument evaluation" `Quick
      test_abort_skips_pending_argument_evaluation;
    Alcotest.test_case "escaped resumption is multi-shot and immutable" `Quick
      test_escaped_resumption_is_multishot_and_immutable;
  ]
