open Jacquard

let expect_eval_e1202 label = function
  | Error (Runtime_err.Type_error message) ->
      Alcotest.(check bool) label true (String.starts_with ~prefix:"E1202:" message)
  | Error error -> Alcotest.failf "%s: unexpected error: %s" label (Runtime_err.to_string error)
  | Ok _ -> Alcotest.failf "%s: marked state reached evaluation" label

(* --- W2.1: value constructors and stable show output (golden) --- *)

let test_value_show_goldens () =
  let h = Eval_support.make () in
  let cases =
    [
      (Value.VInt 42, "42");
      (Value.VInt (-7), "-7");
      (Value.VReal 3.14, "3.14");
      (Value.VReal nan, "+nan.0");
      (Value.VText "a\nb\"c", "\"a\\nb\\\"c\"");
      (Value.VTuple [], "()");
      (Value.VTuple [ Value.VInt 1; Value.VText "x" ], "(1, \"x\")");
      (Value.VCon { con = h.Eval_support.true_con; name = "true"; args = [] }, "true");
      ( Value.VCon
          {
            con = h.Eval_support.some_con;
            name = "some";
            args = [ Value.VTuple [ Value.VInt 1; Value.VInt 2 ] ];
          },
        "some((1, 2))" );
      ( Value.VConstructor { con = h.Eval_support.some_con; name = "some"; arity = 1 },
        "<constructor some/1>" );
      (Value.VBuiltin ("add", fun _ -> Ok Value.unit_v), "<builtin add>");
      (Value.VResume [], "<resume>");
    ]
  in
  List.iter (fun (v, expected) -> Alcotest.(check string) expected expected (Value.show v)) cases

(* --- W2.2: evaluator core --- *)

let test_literals_and_data () =
  let h = Eval_support.make () in
  Alcotest.(check string) "int" "5" (Value.show (Eval_support.eval_ok h "(lit 5)"));
  Alcotest.(check string)
    "tuple" "(1, 2)"
    (Value.show (Eval_support.eval_ok h "(tuple (lit 1) (lit 2))"));
  Alcotest.(check string) "unit" "()" (Value.show (Eval_support.eval_ok h "(tuple)"));
  Alcotest.(check string) "nullary con" "true" (Value.show (Eval_support.eval_ok h "(var true)"));
  Alcotest.(check string)
    "saturated con" "some(3)"
    (Value.show (Eval_support.eval_ok h "(app (var some) (lit 3))"))

let test_lam_let_apply () =
  let h = Eval_support.make () in
  Alcotest.(check string)
    "identity" "9"
    (Value.show (Eval_support.eval_ok h "(app (lam ((pvar x)) (var x)) (lit 9))"));
  Alcotest.(check string)
    "thunk force" "7"
    (Value.show (Eval_support.eval_ok h "(app (lam () (lit 7)))"));
  Alcotest.(check string)
    "let" "3"
    (Value.show (Eval_support.eval_ok h "(let nonrec (pvar x) (lit 3) (var x))"));
  Alcotest.(check string)
    "tuple binder" "2"
    (Value.show
       (Eval_support.eval_ok h
          "(let nonrec (ptuple (pvar a) (pvar b)) (tuple (lit 1) (lit 2)) (var b))"));
  Alcotest.(check string)
    "shadowing" "2"
    (Value.show
       (Eval_support.eval_ok h "(let nonrec (pvar x) (lit 1) (let nonrec (pvar x) (lit 2) (var x)))"))

let test_let_rec_knot () =
  let h = Eval_support.make () in
  Alcotest.(check string)
    "local recursion" "120"
    (Value.show
       (Eval_support.eval_ok h
          "(let rec (pvar f) (lam ((pvar n)) (match (var n) (clause (plit 0) (lit 1)) (clause \
           (pvar m) (app (var mul) (var m) (app (var f) (app (var sub) (var m) (lit 1))))))) (app \
           (var f) (lit 5)))"))

let test_factorial_from_corpus () =
  let h = Eval_support.make () in
  let src = Corpus_support.read_file "../corpus/valid/fact.jqd" in
  (match Reader.parse_string ~file:"fact.jqd" src with
  | Ok [ f ] -> (
      match Kernel.decl_of_form f with
      | Ok d -> (
          match Resolve.resolve_decl h.Eval_support.names d with
          | Ok d -> ignore (Result.get_ok (Store.put_decl h.Eval_support.store d))
          | Error _ -> Alcotest.fail "fact resolve failed")
      | Error _ -> Alcotest.fail "fact validate failed")
  | _ -> Alcotest.fail "fact.jqd should hold one decl");
  Alcotest.(check string)
    "fact 5" "120"
    (Value.show (Eval_support.eval_ok h "(app (var fact) (lit 5))"));
  Alcotest.(check string)
    "fact 0" "1"
    (Value.show (Eval_support.eval_ok h "(app (var fact) (lit 0))"))

let test_even_odd_mutual_group () =
  let h = Eval_support.make () in
  ignore
    (Eval_support.put_src h.Eval_support.store h.Eval_support.names
       "(defterm ((binding even () (lam ((pvar n)) (match (var n) (clause (plit 0) (var true)) \
        (clause (pvar m) (app (var odd) (app (var sub) (var m) (lit 1))))))) (binding odd () (lam \
        ((pvar n)) (match (var n) (clause (plit 0) (var false)) (clause (pvar m) (app (var even) \
        (app (var sub) (var m) (lit 1)))))))))");
  Alcotest.(check string)
    "even 4" "true"
    (Value.show (Eval_support.eval_ok h "(app (var even) (lit 4))"));
  Alcotest.(check string)
    "odd 4" "false"
    (Value.show (Eval_support.eval_ok h "(app (var odd) (lit 4))"));
  Alcotest.(check string)
    "odd 7" "true"
    (Value.show (Eval_support.eval_ok h "(app (var odd) (lit 7))"))

let test_left_to_right_order () =
  let h = Eval_support.make () in
  ignore
    (Eval_support.eval_ok h
       "(app (app (var pick) (lit 1)) (app (var note) (lit 2)) (app (var note) (lit 3)))");
  Alcotest.(check (list string))
    "fn evaluated first, then args left to right" [ "1"; "2"; "3"; "\"applied\"" ]
    (List.map Value.show (Eval_support.recorded h));
  (* tuples too *)
  let h2 = Eval_support.make () in
  ignore
    (Eval_support.eval_ok h2
       "(tuple (app (var note) (lit 1)) (app (var note) (lit 2)) (app (var note) (lit 3)))");
  Alcotest.(check (list string))
    "tuple elements left to right" [ "1"; "2"; "3" ]
    (List.map Value.show (Eval_support.recorded h2))

let test_ref_memoization () =
  let h = Eval_support.make () in
  ignore
    (Eval_support.put_src h.Eval_support.store h.Eval_support.names
       "(defterm ((binding cell () (app (var bump)))))");
  Alcotest.(check string)
    "same memoized value twice" "(1, 1)"
    (Value.show (Eval_support.eval_ok h "(tuple (var cell) (var cell))"));
  Alcotest.(check int) "bump ran once" 1 !(h.Eval_support.bumps)

let test_internal_memoized_closure_fast_path () =
  let h = Eval_support.make () in
  ignore
    (Eval_support.put_src h.Eval_support.store h.Eval_support.names
       "(defterm ((binding memo-identity () (lam ((pvar x)) (var x)))))");
  Alcotest.(check string)
    "first application" "17"
    (Value.show (Eval_support.eval_ok h "(app (var memo-identity) (lit 17))"));
  Alcotest.(check string)
    "memoized closure application" "23"
    (Value.show (Eval_support.eval_ok h "(app (var memo-identity) (lit 23))"))

let test_internal_memo_closure_rechecks_mutated_cell () =
  let h = Eval_support.make () in
  let hashes =
    Eval_support.put_src h.Eval_support.store h.Eval_support.names
      "(defterm ((binding guarded-loop () (let rec (pvar loop) (lam () (lit 7)) (var loop)))))"
  in
  let term_hash = List.assoc "guarded-loop" hashes.Canon.named in
  let closure = Eval_support.eval_ok h "(var guarded-loop)" in
  let cell =
    match closure with
    | Value.VClosure { scope; _ } -> Value.Env.find "loop" scope.env
    | value -> Alcotest.failf "expected memoized closure, got %s" (Value.show value)
  in
  let marker = Meta.empty |> Meta.with_surface_hole "mutated-memo-cell" in
  cell := Value.VCode Form.{ head = "lit"; meta = marker; args = [ Int 0 ] };
  let action_count = ref 0 in
  let action =
    Value.VBuiltin
      ( "memo-cell-following-action",
        fun _ ->
          incr action_count;
          Ok Value.unit_v )
  in
  let action_scope =
    Value.
      { empty_scope with env = Env.add "memo-cell-following-action" (ref action) empty_scope.env }
  in
  let continuation =
    [
      Value.FLet
        {
          binder = Kernel.{ it = PWild; meta = Meta.empty };
          body =
            Kernel.
              {
                it = App ({ it = Var "memo-cell-following-action"; meta = Meta.empty }, []);
                meta = Meta.empty;
              };
          scope = action_scope;
        };
    ]
  in
  let reference = Kernel.{ it = Ref (term_hash, Term); meta = Meta.empty } in
  expect_eval_e1202 "same-root memo closure with mutated cell"
    (Eval.run_state_capturing h.ctx (Eval.SEval (Value.empty_scope, reference, continuation)));
  Alcotest.(check int) "action after mutated memo closure" 0 !action_count

let test_native_mutation_rechecks_closure_argument () =
  let h = Eval_support.make () in
  let captured_cell = ref (Value.VInt 11) in
  let closure_scope =
    Value.{ empty_scope with env = Env.add "captured" captured_cell empty_scope.env }
  in
  let closure =
    Value.VClosure
      {
        scope = closure_scope;
        params = [];
        body = Kernel.{ it = Var "captured"; meta = Meta.empty };
      }
  in
  let marker = Meta.empty |> Meta.with_surface_hole "native-mutated-cell" in
  let marked = Value.VCode Form.{ head = "lit"; meta = marker; args = [ Int 0 ] } in
  let mutator =
    Value.VBuiltin
      ( "mutate-closure-cell",
        function
        | [ Value.VClosure { scope; _ } ] ->
            let cell = Value.Env.find "captured" scope.env in
            cell := marked;
            Ok Value.unit_v
        | args -> Alcotest.failf "mutator received %d arguments" (List.length args) )
  in
  let action_count = ref 0 in
  let action =
    Value.VBuiltin
      ( "native-following-action",
        fun _ ->
          incr action_count;
          Ok Value.unit_v )
  in
  let action_scope =
    Value.{ empty_scope with env = Env.add "native-following-action" (ref action) empty_scope.env }
  in
  let read_mutated_cell =
    Value.FLet
      {
        binder = Kernel.{ it = PWild; meta = Meta.empty };
        body = Kernel.{ it = Var "captured"; meta = Meta.empty };
        scope = closure_scope;
      }
  in
  let following_action =
    Value.FLet
      {
        binder = Kernel.{ it = PWild; meta = Meta.empty };
        body =
          Kernel.
            {
              it = App ({ it = Var "native-following-action"; meta = Meta.empty }, []);
              meta = Meta.empty;
            };
        scope = action_scope;
      }
  in
  let argument_scope =
    Value.{ empty_scope with env = Env.add "closure-argument" (ref closure) empty_scope.env }
  in
  let argument = Kernel.{ it = Var "closure-argument"; meta = Meta.empty } in
  expect_eval_e1202 "native-mutated closure argument"
    (Eval.run_state_capturing h.ctx
       (Eval.SApply
          ( mutator,
            Value.FAppFn { args = [ argument ]; scope = argument_scope }
            :: [ read_mutated_cell; following_action ] )));
  Alcotest.(check int) "action after native mutation" 0 !action_count

let test_zero_argument_native_mutation_guards_continuation () =
  let run_case label install invoke_state =
    let h = Eval_support.make () in
    let marker = Meta.empty |> Meta.with_surface_hole (label ^ "-continuation-cell") in
    let marked = Value.VCode Form.{ head = "lit"; meta = marker; args = [ Int 0 ] } in
    let continuation_cell = ref (Value.VInt 11) in
    let continuation_scope =
      Value.{ empty_scope with env = Env.add "guarded-cell" continuation_cell empty_scope.env }
    in
    let following_calls = ref 0 in
    let following =
      Value.VBuiltin
        ( label ^ "-following",
          fun _ ->
            incr following_calls;
            Ok Value.unit_v )
    in
    let following_scope =
      Value.{ empty_scope with env = Env.add "following" (ref following) empty_scope.env }
    in
    let continuation =
      [
        Value.FLet
          {
            binder = Kernel.{ it = PWild; meta = Meta.empty };
            body = Kernel.{ it = Var "guarded-cell"; meta = Meta.empty };
            scope = continuation_scope;
          };
        Value.FLet
          {
            binder = Kernel.{ it = PWild; meta = Meta.empty };
            body =
              Kernel.
                { it = App ({ it = Var "following"; meta = Meta.empty }, []); meta = Meta.empty };
            scope = following_scope;
          };
      ]
    in
    let mutate _ =
      continuation_cell := marked;
      Ok Value.unit_v
    in
    let callable = install h mutate in
    expect_eval_e1202 label (Eval.run_state_capturing h.ctx (invoke_state callable continuation));
    Alcotest.(check int) (label ^ " following action") 0 !following_calls
  in
  run_case "zero-argument builtin mutation"
    (fun _ mutate -> Value.VBuiltin ("mutate-continuation", mutate))
    (fun builtin continuation ->
      Eval.SApply (builtin, Value.FAppFn { args = []; scope = Value.empty_scope } :: continuation));
  run_case "zero-argument root mutation"
    (fun h mutate ->
      let op = Hash.of_string "zero-argument-root-mutation" in
      Eval.register_root_handler h.Eval_support.ctx op mutate;
      Value.VOp { op; name = "zero-argument-root-mutation"; effect_ = "StateGuard" })
    (fun operation continuation ->
      Eval.SApply (operation, Value.FAppFn { args = []; scope = Value.empty_scope } :: continuation))

let test_clean_recursive_memo_closure_cycle () =
  let h = Eval_support.make () in
  ignore
    (Eval_support.put_src h.Eval_support.store h.Eval_support.names
       "(defterm ((binding recursive-countdown () (let rec (pvar loop) (lam ((pvar n)) (match (var \
        n) (clause (plit 0) (lit 0)) (clause (pvar m) (app (var loop) (app (var sub) (var m) (lit \
        1)))))) (var loop)))))");
  Alcotest.(check string)
    "first recursive memo application" "0"
    (Value.show (Eval_support.eval_ok h "(app (var recursive-countdown) (lit 8))"));
  Alcotest.(check string)
    "second recursive memo application" "0"
    (Value.show (Eval_support.eval_ok h "(app (var recursive-countdown) (lit 5))"))

let test_validation_caches_survive_wide_graphs_gc_and_lru_pressure () =
  let h = Eval_support.make () in
  let nested = Value.VTuple [ Value.VInt 1 ] in
  let wide = Value.VTuple (nested :: List.init 1_000_000 (fun index -> Value.VInt (index + 2))) in
  let validate value =
    match Eval.run_state_capturing h.ctx (Eval.SApply (value, [])) with
    | Ok (Eval.CValue result) -> result
    | Ok (Eval.COp _) -> Alcotest.fail "cache probe unexpectedly performed an operation"
    | Error error -> Alcotest.failf "cache probe failed: %s" (Runtime_err.to_string error)
  in
  ignore (validate wide);
  Gc.compact ();
  let before = Gc.allocated_bytes () in
  for _ = 1 to 5 do
    ignore (validate wide)
  done;
  let allocated = Gc.allocated_bytes () -. before in
  Alcotest.(check bool) "wide cache-hit allocation remains bounded" true (allocated <= 4_096.);
  let roots =
    Array.init 65 (fun index ->
        let scope =
          Value.{ empty_scope with env = Env.add "cell" (ref (VInt index)) empty_scope.env }
        in
        Value.VClosure { scope; params = []; body = Kernel.{ it = Var "cell"; meta = Meta.empty } })
  in
  let guarded = Value.VBuiltin ("lru-pressure", fun _ -> Ok Value.unit_v) in
  Array.iter
    (fun root ->
      match Eval.call h.ctx guarded [ root ] with
      | Ok _ -> ()
      | Error error -> Alcotest.failf "LRU pressure call failed: %s" (Runtime_err.to_string error))
    roots;
  let marker = Meta.empty |> Meta.with_surface_hole "evicted-root-mutation" in
  (match roots.(0) with
  | Value.VClosure { scope; _ } ->
      let cell = Value.Env.find "cell" scope.env in
      cell := Value.VCode Form.{ head = "lit"; meta = marker; args = [ Int 0 ] }
  | _ -> assert false);
  match Eval.call h.ctx guarded [ roots.(0) ] with
  | Error (Runtime_err.Type_error message) ->
      Alcotest.(check bool)
        "mutation after LRU pressure is rejected" true
        (String.starts_with ~prefix:"E1202:" message)
  | Error error -> Alcotest.failf "unexpected LRU mutation error: %s" (Runtime_err.to_string error)
  | Ok _ -> Alcotest.fail "mutation after LRU pressure escaped validation"

let test_coverage_gate () =
  (* PF.2 phase 2: coverage tracking is on by default and skippable; the run path
     turns it off because it never reads the table and the write costs per term
     reference are measurable *)
  let h = Eval_support.make () in
  ignore
    (Eval_support.put_src h.Eval_support.store h.Eval_support.names
       "(defterm ((binding forty-two () (lit 42))))");
  let _, covered =
    Eval.with_fresh_coverage h.ctx (fun () -> Eval_support.eval_ok h "(var forty-two)")
  in
  Alcotest.(check bool) "tracked by default" true (covered <> []);
  let h2 = Eval_support.make () in
  Eval.set_coverage_tracking h2.Eval_support.ctx false;
  ignore
    (Eval_support.put_src h2.Eval_support.store h2.Eval_support.names
       "(defterm ((binding forty-two () (lit 42))))");
  let _, covered =
    Eval.with_fresh_coverage h2.ctx (fun () -> Eval_support.eval_ok h2 "(var forty-two)")
  in
  Alcotest.(check (list string)) "untracked when gated off" [] (List.map Hash.to_hex covered)

let test_match_failure_shows_scrutinee () =
  let h = Eval_support.make () in
  match Eval_support.eval_err h "(match (lit 5) (clause (plit 0) (lit 1)))" with
  | Runtime_err.Match_failure shown -> Alcotest.(check string) "scrutinee printed" "5" shown
  | e -> Alcotest.failf "expected Match_failure, got %s" (Runtime_err.to_string e)

let test_arity_and_type_errors () =
  let h = Eval_support.make () in
  (match Eval_support.eval_err h "(app (lam ((pvar x)) (var x)) (lit 1) (lit 2))" with
  | Runtime_err.Arity _ -> ()
  | e -> Alcotest.failf "expected Arity, got %s" (Runtime_err.to_string e));
  (match Eval_support.eval_err h "(app (var some) (lit 1) (lit 2))" with
  | Runtime_err.Arity _ -> ()
  | e -> Alcotest.failf "expected constructor Arity, got %s" (Runtime_err.to_string e));
  (match Eval_support.eval_err h "(app (lit 3) (lit 1))" with
  | Runtime_err.Type_error _ -> ()
  | e -> Alcotest.failf "expected Type_error, got %s" (Runtime_err.to_string e));
  match Eval_support.eval_err h "(app (var div) (lit 1) (lit 0))" with
  | Runtime_err.Arithmetic msg -> Alcotest.(check string) "div by zero" "division by zero" msg
  | e -> Alcotest.failf "expected Arithmetic, got %s" (Runtime_err.to_string e)

let test_unresolved_var_at_runtime () =
  let h = Eval_support.make () in
  (* skip resolution deliberately: a free Var reaching the machine is a runtime error *)
  let e =
    match Kernel.expr_of_form (Result.get_ok (Reader.parse_one ~file:"u.jqd" "(var ghost)")) with
    | Ok e -> e
    | Error _ -> Alcotest.fail "validate failed"
  in
  match Eval.run_expr h.Eval_support.ctx e with
  | Error (Runtime_err.Unresolved _) -> ()
  | Ok v -> Alcotest.failf "expected Unresolved, got %s" (Value.show v)
  | Error e -> Alcotest.failf "expected Unresolved, got %s" (Runtime_err.to_string e)

let test_ann_is_transparent () =
  let h = Eval_support.make () in
  Alcotest.(check string)
    "ann evaluates subject" "5"
    (Value.show (Eval_support.eval_ok h "(ann (lit 5) (tref bool))"))

let test_state_guard_precedes_effects_and_follows_resumptions () =
  let h = Eval_support.make () in
  let marker = Meta.empty |> Meta.with_surface_hole "hidden-state" in
  let marked = Kernel.{ it = Lit (LInt 0); meta = marker } in
  let op = Hash.of_string "state-guard-op" in
  let calls = ref 0 in
  Eval.register_root_handler h.ctx op (fun _ ->
      incr calls;
      Ok Value.unit_v);
  let operation = Value.VOp { op; name = "state-guard-op"; effect_ = "StateGuard" } in
  let effect_first =
    Eval.SApply
      ( operation,
        [
          Value.FAppFn { args = []; scope = Value.empty_scope };
          Value.FTuple { done_rev = []; pending = [ marked ]; scope = Value.empty_scope };
        ] )
  in
  expect_eval_e1202 "hidden frame" (Eval.run_state_capturing h.ctx effect_first);
  Alcotest.(check int) "root handler was not invoked" 0 !calls;
  let escaped =
    Value.VResume
      [ Value.FTuple { done_rev = []; pending = [ marked ]; scope = Value.empty_scope } ]
  in
  expect_eval_e1202 "captured resumption"
    (Eval.run_state_capturing h.ctx (Eval.resume_state [] escaped));
  let recursive =
    Eval_support.eval_ok h "(let rec (pvar loop) (lam () (app (var loop))) (var loop))"
  in
  match Eval.run_state_capturing h.ctx (Eval.SApply (recursive, [])) with
  | Ok (Eval.CValue _) -> ()
  | Ok (Eval.COp _) -> Alcotest.fail "recursive closure unexpectedly performed an operation"
  | Error error -> Alcotest.failf "clean state after rejection: %s" (Runtime_err.to_string error)

let test_state_guard_checks_machine_transition_results () =
  let h = Eval_support.make () in
  let marker = Meta.empty |> Meta.with_surface_hole "transition-result" in
  let marked_code = Value.VCode Form.{ head = "lit"; meta = marker; args = [ Int 0 ] } in
  let action_count = ref 0 in
  let action =
    Value.VBuiltin
      ( "observable-action",
        fun _ ->
          incr action_count;
          Ok Value.unit_v )
  in
  let action_scope =
    Value.{ empty_scope with env = Env.add "observable-action" (ref action) empty_scope.env }
  in
  let continue_with_action =
    [
      Value.FLet
        {
          binder = Kernel.{ it = PWild; meta = Meta.empty };
          body =
            Kernel.
              {
                it = App ({ it = Var "observable-action"; meta = Meta.empty }, []);
                meta = Meta.empty;
              };
          scope = action_scope;
        };
    ]
  in
  let producer = Value.VBuiltin ("marked-code", fun _ -> Ok marked_code) in
  expect_eval_e1202 "builtin transition result"
    (Eval.run_state_capturing h.ctx
       (Eval.SApply
          (producer, Value.FAppFn { args = []; scope = Value.empty_scope } :: continue_with_action)));
  Alcotest.(check int) "continuation action after builtin" 0 !action_count;
  let compound_marked =
    Value.VTuple
      [
        Value.VCon
          {
            con = Hash.of_string "compound-marked-result";
            name = "compound-marked-result";
            args = [ marked_code ];
          };
      ]
  in
  let compound_producer = Value.VBuiltin ("compound-marked-code", fun _ -> Ok compound_marked) in
  expect_eval_e1202 "compound builtin transition result"
    (Eval.run_state_capturing h.ctx
       (Eval.SApply
          ( compound_producer,
            Value.FAppFn { args = []; scope = Value.empty_scope } :: continue_with_action )));
  Alcotest.(check int) "continuation action after compound builtin" 0 !action_count;
  let op = Hash.of_string "marked-root-result" in
  Eval.register_root_handler h.ctx op (fun _ -> Ok marked_code);
  let operation = Value.VOp { op; name = "marked-root-result"; effect_ = "StateGuard" } in
  expect_eval_e1202 "root handler transition result"
    (Eval.run_state_capturing h.ctx
       (Eval.SApply
          (operation, Value.FAppFn { args = []; scope = Value.empty_scope } :: continue_with_action)));
  Alcotest.(check int) "continuation action after root handler" 0 !action_count

let suite =
  [
    Alcotest.test_case "value show goldens" `Quick test_value_show_goldens;
    Alcotest.test_case "literals and data" `Quick test_literals_and_data;
    Alcotest.test_case "lam, let, apply" `Quick test_lam_let_apply;
    Alcotest.test_case "let rec ties the knot" `Quick test_let_rec_knot;
    Alcotest.test_case "factorial from corpus" `Quick test_factorial_from_corpus;
    Alcotest.test_case "even/odd mutual group" `Quick test_even_odd_mutual_group;
    Alcotest.test_case "left-to-right strict order" `Quick test_left_to_right_order;
    Alcotest.test_case "store term memoization" `Quick test_ref_memoization;
    Alcotest.test_case "internal memoized closure fast path" `Quick
      test_internal_memoized_closure_fast_path;
    Alcotest.test_case "internal memo closure rechecks mutated cell" `Quick
      test_internal_memo_closure_rechecks_mutated_cell;
    Alcotest.test_case "native mutation rechecks closure argument" `Quick
      test_native_mutation_rechecks_closure_argument;
    Alcotest.test_case "zero-argument native mutation guards continuation" `Quick
      test_zero_argument_native_mutation_guards_continuation;
    Alcotest.test_case "clean recursive memo closure cycle" `Quick
      test_clean_recursive_memo_closure_cycle;
    Alcotest.test_case "validation caches survive wide graphs, GC, and LRU pressure" `Quick
      test_validation_caches_survive_wide_graphs_gc_and_lru_pressure;
    Alcotest.test_case "coverage tracking is gated" `Quick test_coverage_gate;
    Alcotest.test_case "match failure prints scrutinee" `Quick test_match_failure_shows_scrutinee;
    Alcotest.test_case "arity and type errors" `Quick test_arity_and_type_errors;
    Alcotest.test_case "unresolved var at runtime" `Quick test_unresolved_var_at_runtime;
    Alcotest.test_case "ann transparent" `Quick test_ann_is_transparent;
    Alcotest.test_case "state guard precedes effects and follows resumptions" `Quick
      test_state_guard_precedes_effects_and_follows_resumptions;
    Alcotest.test_case "state guard checks machine transition results" `Quick
      test_state_guard_checks_machine_transition_results;
  ]
