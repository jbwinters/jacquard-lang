open Jacquard

(* W2.5: quote, unquote, Code values, hygiene marks, and the gated eval effect. *)

let code_payload = function
  | Value.VCode f -> f
  | v -> Alcotest.failf "expected code, got %s" (Value.show v)

let parse_form src = Result.get_ok (Reader.parse_one ~file:"q.wft" src)

let check_payload what expected v =
  Alcotest.(check bool) what true (Form.equal_ignoring_meta (parse_form expected) (code_payload v))

let test_quote_basic () =
  let h = Eval_support.make () in
  check_payload "payload is the raw triple" "(lit 1)" (Eval_support.eval_ok h "(quote (lit 1))");
  check_payload "names stay unresolved data" "(app (var add) (lit 1))"
    (Eval_support.eval_ok h "(quote (app (var add) (lit 1)))")

(* Quote of quote nests correctly: the outer evaluation leaves the inner quote as data. *)
let test_quote_of_quote_nests () =
  let h = Eval_support.make () in
  check_payload "inner quote intact" "(quote (app (var f) (lit 1)))"
    (Eval_support.eval_ok h "(quote (quote (app (var f) (lit 1))))");
  (* an unquote under the nested quote is data for the outer quote... *)
  check_payload "nested unquote stays data" "(quote (unquote (var mk)))"
    (Eval_support.eval_ok h
       "(let nonrec (pvar mk) (quote (lit 9)) (quote (quote (unquote (var mk)))))");
  (* ...and becomes live when the produced code is evaluated one level down: the value of
     the OUTER quote evaluated as code yields the inner payload spliced *)
  ()

(* Splicing a computed form into a quoted app produces the expected triple. *)
let test_splice_computed_form () =
  let h = Eval_support.make () in
  check_payload "spliced fn position" "(app (var foo) (lit 1))"
    (Eval_support.eval_ok h
       "(let nonrec (pvar mk) (quote (var foo)) (quote (app (unquote (var mk)) (lit 1))))");
  (* two splices, order preserved *)
  check_payload "two splices in order" "(tuple (lit 10) (lit 20))"
    (Eval_support.eval_ok h
       "(let nonrec (pvar a) (quote (lit 10)) (let nonrec (pvar b) (quote (lit 20)) (quote (tuple \
        (unquote (var a)) (unquote (var b))))))");
  (* splices may compute *)
  check_payload "computed splice" "(lit 5)"
    (Eval_support.eval_ok h
       "(quote (unquote (match (lit 1) (clause (plit 1) (quote (lit 5))) (clause (pwild) (quote \
        (lit 0))))))")

let contains ~needle haystack =
  let n = String.length needle and m = String.length haystack in
  let rec go i = i + n <= m && (String.sub haystack i n = needle || go (i + 1)) in
  go 0

let test_splice_non_code_fails () =
  let h = Eval_support.make () in
  match Eval_support.eval_err h "(quote (app (unquote (lit 3)) (lit 1)))" with
  | Runtime_err.Type_error msg ->
      Alcotest.(check bool) "mentions splice" true (contains ~needle:"splice" msg)
  | e -> Alcotest.failf "expected Type_error, got %s" (Runtime_err.to_string e)

(* Hygiene scope marks (stubbed): each quote evaluation stamps a fresh mark under the
   reserved scopes key on every payload node; marks just travel. *)
let test_scope_marks_travel () =
  let h = Eval_support.make () in
  let marks v =
    match Meta.find Meta.key_scopes (code_payload v).Form.meta with
    | Some (Meta.List l) -> l
    | _ -> Alcotest.fail "expected a scopes list on the payload root"
  in
  let v1 = Eval_support.eval_ok h "(app (lam () (quote (var x))))" in
  let v2 = Eval_support.eval_ok h "(app (lam () (quote (var x))))" in
  Alcotest.(check int) "one mark per evaluation" 1 (List.length (marks v1));
  Alcotest.(check bool) "fresh marks are distinct across evaluations" false (marks v1 = marks v2);
  (* nested nodes carry the mark too *)
  match (code_payload (Eval_support.eval_ok h "(quote (app (var f) (lit 1)))")).Form.args with
  | Form.F inner :: _ -> (
      match Meta.find Meta.key_scopes inner.Form.meta with
      | Some (Meta.List [ _ ]) -> ()
      | _ -> Alcotest.fail "child nodes should carry the scope mark")
  | _ -> Alcotest.fail "unexpected payload shape"

(* --- the gated eval effect (first capability demo) --- *)

let put_fact store =
  let src = Corpus_support.read_file "../corpus/valid/fact.wft" in
  match Reader.parse_string ~file:"fact.wft" src with
  | Ok [ f ] ->
      let d = Result.get_ok (Kernel.decl_of_form f) in
      let d = Result.get_ok (Resolve.resolve_decl (Store.names_view store) d) in
      ignore (Result.get_ok (Store.put_decl store d))
  | _ -> Alcotest.fail "fact.wft should hold one decl"

let test_eval_gated_pair () =
  (* WITH the grant: eval-code on quoted factorial applied to 5 yields 120 *)
  let store, ctx = Eval_support.make_prelude_ctx () in
  put_fact store;
  (match Prelude.install_eval ctx with
  | Ok () -> ()
  | Error ds -> Eval_support.fail_diags "install_eval" ds);
  (match
     Eval_support.eval_with ctx store "(app (var eval-code) (quote (app (var fact) (lit 5))))"
   with
  | Ok v -> Alcotest.(check string) "eval fact 5" "120" (Value.show v)
  | Error e -> Alcotest.failf "grant run failed: %s" (Runtime_err.to_string e));
  (* WITHOUT the grant: the same program dies with Unhandled naming the effect *)
  let store2, ctx2 = Eval_support.make_prelude_ctx () in
  put_fact store2;
  match
    Eval_support.eval_with ctx2 store2 "(app (var eval-code) (quote (app (var fact) (lit 5))))"
  with
  | Error (Runtime_err.Unhandled { effect_; op }) ->
      Alcotest.(check string) "effect" "eval" effect_;
      Alcotest.(check string) "op" "eval-code" op
  | Ok v -> Alcotest.failf "ungated eval should fail, got %s" (Value.show v)
  | Error e -> Alcotest.failf "expected Unhandled, got %s" (Runtime_err.to_string e)

let test_eval_boundary_rejects_garbage () =
  let store, ctx = Eval_support.make_prelude_ctx () in
  (match Prelude.install_eval ctx with
  | Ok () -> ()
  | Error ds -> Eval_support.fail_diags "install_eval" ds);
  (* not a kernel expression *)
  (match Eval_support.eval_with ctx store "(app (var eval-code) (quote (nonsense)))" with
  | Error (Runtime_err.Eval_error _) -> ()
  | Ok v -> Alcotest.failf "garbage code should fail, got %s" (Value.show v)
  | Error e -> Alcotest.failf "expected Eval_error, got %s" (Runtime_err.to_string e));
  (* validates but does not resolve *)
  (match Eval_support.eval_with ctx store "(app (var eval-code) (quote (var zz-unknown)))" with
  | Error (Runtime_err.Eval_error _) -> ()
  | Ok v -> Alcotest.failf "unresolvable code should fail, got %s" (Value.show v)
  | Error e -> Alcotest.failf "expected Eval_error, got %s" (Runtime_err.to_string e));
  (* not code at all *)
  match Eval_support.eval_with ctx store "(app (var eval-code) (lit 3))" with
  | Error (Runtime_err.Eval_error _) -> ()
  | Ok v -> Alcotest.failf "non-code should fail, got %s" (Value.show v)
  | Error e -> Alcotest.failf "expected Eval_error, got %s" (Runtime_err.to_string e)

(* the corpus carries the gated program (its named spot per the plan) *)
let test_gated_corpus_program () =
  let store, ctx = Eval_support.make_prelude_ctx () in
  let src = Corpus_support.read_file "../corpus/valid/eval-gated.wft" in
  (match Prelude.install_eval ctx with
  | Ok () -> ()
  | Error ds -> Eval_support.fail_diags "install_eval" ds);
  match Reader.parse_string ~file:"eval-gated.wft" src with
  | Ok [ f ] -> (
      let e = Result.get_ok (Kernel.expr_of_form f) in
      match Resolve.resolve_expr (Store.names_view store) e with
      | Ok e -> (
          match Eval.run_expr ctx e with
          | Ok v -> Alcotest.(check string) "42" "42" (Value.show v)
          | Error e -> Alcotest.failf "run failed: %s" (Runtime_err.to_string e))
      | Error ds -> Eval_support.fail_diags "resolve" ds)
  | _ -> Alcotest.fail "eval-gated.wft should hold one expression"

let suite =
  [
    Alcotest.test_case "quote yields raw triples" `Quick test_quote_basic;
    Alcotest.test_case "quote of quote nests" `Quick test_quote_of_quote_nests;
    Alcotest.test_case "splicing computed forms" `Quick test_splice_computed_form;
    Alcotest.test_case "splice of non-code fails" `Quick test_splice_non_code_fails;
    Alcotest.test_case "scope marks travel" `Quick test_scope_marks_travel;
    Alcotest.test_case "eval gated pair (capability demo)" `Quick test_eval_gated_pair;
    Alcotest.test_case "eval boundary rejects garbage" `Quick test_eval_boundary_rejects_garbage;
    Alcotest.test_case "gated corpus program" `Quick test_gated_corpus_program;
  ]
