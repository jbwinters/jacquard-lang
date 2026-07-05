open Jacquard

let expr_hash src =
  match Reader.parse_one ~file:"gauntlet-hash.jqd" src with
  | Error ds -> Eval_support.fail_diags "parse" ds
  | Ok f -> (
      match Kernel.expr_of_form f with
      | Error ds -> Eval_support.fail_diags "validate" ds
      | Ok e -> (
          match Resolve.resolve_expr Resolve.empty_names e with
          | Error ds -> Eval_support.fail_diags "resolve" ds
          | Ok e -> (
              match Canon.hash_expr e with
              | Ok h -> h
              | Error ds -> Eval_support.fail_diags "hash" ds)))

let show_eval src =
  let h = Eval_support.make () in
  Value.show (Eval_support.eval_ok h src)

let test_shadowing_sensitive_alpha_hash () =
  let outer_ignored_x = "(lam ((pvar x)) (let nonrec (pvar x) (lit 1) (var x)))" in
  let outer_ignored_y = "(lam ((pvar y)) (let nonrec (pvar x) (lit 1) (var x)))" in
  let outer_used = "(lam ((pvar x)) (let nonrec (pvar y) (lit 1) (var x)))" in
  Alcotest.(check bool)
    "renaming an ignored shadowed outer binder preserves hash" true
    (Hash.equal (expr_hash outer_ignored_x) (expr_hash outer_ignored_y));
  Alcotest.(check bool)
    "using the outer binder changes hash" false
    (Hash.equal (expr_hash outer_ignored_x) (expr_hash outer_used));
  Alcotest.(check string)
    "shadowed version returns local value" "1"
    (show_eval ("(app " ^ outer_ignored_x ^ " (lit 9))"));
  Alcotest.(check string)
    "outer-used version returns argument" "9"
    (show_eval ("(app " ^ outer_used ^ " (lit 9))"))

let hash_group_of_order members =
  let src = "(defterm (" ^ String.concat " " members ^ "))" in
  match Test_canon.resolved_tops ~what:"gauntlet-scc" src with
  | [ top ] ->
      let { Canon.decl_hash; named } = Test_canon.hash_of_top ~what:"gauntlet-scc" top in
      (decl_hash, List.sort compare (List.map (fun (n, h) -> (n, Hash.to_hex h)) named))
  | _ -> Alcotest.fail "expected one defterm group"

let test_three_member_scc_reorder_stable () =
  let members =
    [
      "(binding a () (lam ((pvar n)) (app (var b) (var n))))";
      "(binding b () (lam ((pvar n)) (app (var c) (var n))))";
      "(binding c () (lam ((pvar n)) (app (var a) (var n))))";
    ]
  in
  let reference = hash_group_of_order members in
  List.iteri
    (fun i order ->
      let this = hash_group_of_order order in
      Alcotest.(check bool)
        (Printf.sprintf "permutation %d group hash" i)
        true
        (Hash.equal (fst reference) (fst this));
      Alcotest.(check (list (pair string string)))
        (Printf.sprintf "permutation %d member hashes" i)
        (snd reference) (snd this))
    (Test_canon.permutations members)

let suite =
  [
    Alcotest.test_case "shadowing-sensitive alpha hash" `Quick test_shadowing_sensitive_alpha_hash;
    Alcotest.test_case "three-member SCC reorder stable" `Quick test_three_member_scc_reorder_stable;
  ]
