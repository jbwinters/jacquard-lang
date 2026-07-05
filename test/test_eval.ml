open Jacquard

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
    Alcotest.test_case "match failure prints scrutinee" `Quick test_match_failure_shows_scrutinee;
    Alcotest.test_case "arity and type errors" `Quick test_arity_and_type_errors;
    Alcotest.test_case "unresolved var at runtime" `Quick test_unresolved_var_at_runtime;
    Alcotest.test_case "ann transparent" `Quick test_ann_is_transparent;
  ]
