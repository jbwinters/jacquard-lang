open Jacquard

(* W3.5: exhaustiveness (error, with witness) and redundancy (warning). *)

let make = Test_check.make_cctx
let check_src = Test_check.check_src

let err_of h src =
  match check_src h src with
  | Ok _ -> Alcotest.failf "expected %s to fail" src
  | Error [ d ] -> d
  | Error _ -> Alcotest.fail "expected one diagnostic"

let contains ~needle haystack =
  let n = String.length needle and m = String.length haystack in
  let rec go i = i + n <= m && (String.sub haystack i n = needle || go (i + 1)) in
  go 0

let test_bool_missing_false () =
  let h = make () in
  let d = err_of h "(lam ((pvar b)) (match (var b) (clause (pcon true) (lit 1))))" in
  Alcotest.(check string) "code" "E0813" (Diag.code_or_uncoded d);
  Alcotest.(check bool) "witness prints false" true (contains ~needle:"false" (Diag.cause d))

(* the plan's nested witness: Option (Option Bool) missing Some (Some False) *)
let test_nested_witness () =
  let h = make () in
  let d =
    err_of h
      "(lam ((pvar o)) (match (var o) (clause (pcon none) (lit 0)) (clause (pcon some (pcon none)) \
       (lit 1)) (clause (pcon some (pcon some (pcon true))) (lit 2))))"
  in
  Alcotest.(check string) "code" "E0813" (Diag.code_or_uncoded d);
  Alcotest.(check bool)
    (Printf.sprintf "witness is some(some(false)) (got: %s)" (Diag.cause d))
    true
    (contains ~needle:"some(some(false))" (Diag.cause d))

let test_redundant_clause_warns () =
  let h = make () in
  match
    check_src h
      "(lam ((pvar b)) (match (var b) (clause (pwild) (lit 0)) (clause (pcon true) (lit 1))))"
  with
  | Ok { Check.warnings = [ w ]; _ } ->
      Alcotest.(check string) "warning code" "W0801" (Diag.code_or_uncoded w);
      Alcotest.(check bool) "is a warning" true (Diag.severity w = Diag.Warning)
  | Ok { Check.warnings; _ } -> Alcotest.failf "expected one warning, got %d" (List.length warnings)
  | Error ds -> Eval_support.fail_diags "should check (warning only)" ds

(* the review's repro: redundancy that hinges on the SECOND column *)
let test_redundancy_in_later_columns () =
  let h = make () in
  match
    check_src h
      "(lam ((pvar p)) (match (var p) (clause (ptuple (pwild) (pcon true)) (lit 0)) (clause \
       (ptuple (pwild) (pcon true)) (lit 1)) (clause (pwild) (lit 2))))"
  with
  | Ok { Check.warnings = [ w ]; _ } ->
      Alcotest.(check string) "code" "W0801" (Diag.code_or_uncoded w)
  | Ok { Check.warnings; _ } -> Alcotest.failf "expected one warning, got %d" (List.length warnings)
  | Error ds -> Eval_support.fail_diags "later-column redundancy" ds

let test_plit_scrutinee_needs_catch_all () =
  let h = make () in
  (* literals over an infinite type: rejected without a default *)
  let d = err_of h "(match (lit 5) (clause (plit 0) (lit 1)) (clause (plit 1) (lit 2)))" in
  Alcotest.(check string) "code" "E0813" (Diag.code_or_uncoded d);
  (* accepted with a variable default *)
  match
    check_src h "(match (lit 5) (clause (plit 0) (lit 1)) (clause (pvar other) (var other)))"
  with
  | Ok _ -> ()
  | Error ds -> Eval_support.fail_diags "catch-all accepted" ds

let test_tuple_patterns () =
  let h = make () in
  (* tuple wildcards are complete *)
  (match
     check_src h "(match (tuple (lit 1) (var true)) (clause (ptuple (pvar a) (pwild)) (var a)))"
   with
  | Ok _ -> ()
  | Error ds -> Eval_support.fail_diags "tuple wildcard complete" ds);
  (* a bool inside a tuple must still be covered *)
  let d =
    err_of h "(match (tuple (lit 1) (var true)) (clause (ptuple (pvar a) (pcon true)) (var a)))"
  in
  Alcotest.(check string) "code" "E0813" (Diag.code_or_uncoded d);
  Alcotest.(check bool) "tuple witness" true (contains ~needle:"(_, false)" (Diag.cause d))

let test_recursive_list () =
  let h = make () in
  (* nil + cons is complete *)
  (match
     check_src h
       "(lam ((pvar xs)) (match (ann (var xs) (tapp (tref list) (tref int))) (clause (pcon nil) \
        (lit 0)) (clause (pcon cons (pvar x) (pwild)) (var x))))"
   with
  | Ok _ -> ()
  | Error ds -> Eval_support.fail_diags "list complete" ds);
  (* missing cons names the constructor with wildcard args *)
  let d =
    err_of h
      "(lam ((pvar xs)) (match (ann (var xs) (tapp (tref list) (tref int))) (clause (pcon nil) \
       (lit 0))))"
  in
  Alcotest.(check string) "code" "E0813" (Diag.code_or_uncoded d);
  Alcotest.(check bool)
    (Printf.sprintf "witness names cons (got: %s)" (Diag.cause d))
    true
    (contains ~needle:"cons(_, _)" (Diag.cause d))

let test_as_patterns_transparent () =
  let h = make () in
  match
    check_src h
      "(lam ((pvar b)) (match (var b) (clause (pas w (pcon true)) (lit 1)) (clause (pcon false) \
       (lit 0))))"
  with
  | Ok _ -> ()
  | Error ds -> Eval_support.fail_diags "as-patterns are transparent" ds

let suite =
  [
    Alcotest.test_case "bool missing false" `Quick test_bool_missing_false;
    Alcotest.test_case "nested witness" `Quick test_nested_witness;
    Alcotest.test_case "redundant clause warns" `Quick test_redundant_clause_warns;
    Alcotest.test_case "redundancy in later columns" `Quick test_redundancy_in_later_columns;
    Alcotest.test_case "plit scrutinee needs catch-all" `Quick test_plit_scrutinee_needs_catch_all;
    Alcotest.test_case "tuple patterns" `Quick test_tuple_patterns;
    Alcotest.test_case "recursive list" `Quick test_recursive_list;
    Alcotest.test_case "as-patterns transparent" `Quick test_as_patterns_transparent;
  ]
