open Weft

(* W5.2: the semantic differ. *)

let mk_store srcs =
  let store =
    match Store.open_store (Eval_support.fresh_dir ()) with
    | Ok s -> s
    | Error ds -> Eval_support.fail_diags "open_store" ds
  in
  List.iter (fun src -> ignore (Eval_support.put_src store (Store.names_view store) src)) srcs;
  store

let fact_src ?(name = "fact") ?(base = 1) () =
  Printf.sprintf
    "(defterm ((binding %s ()\n\
    \  (lam ((pvar n))\n\
    \    (match (var n)\n\
    \      (clause (plit 0) (lit %d))\n\
    \      (clause (pvar m)\n\
    \        (app (var mul) (var m)\n\
    \          (app (var %s) (app (var sub) (var m) (lit 1))))))))))"
    name base name

let builtin_stub name = Printf.sprintf "(defterm ((binding %s () (quote (builtin %s)))))" name name
let base_srcs = [ builtin_stub "mul"; builtin_stub "sub" ]

let test_rename_only () =
  let a = mk_store (base_srcs @ [ fact_src () ]) in
  let b = mk_store (base_srcs @ [ fact_src () ]) in
  (match Store.rename b ~old_name:"fact" ~new_name:"factorial" with
  | Ok () -> ()
  | Error ds -> Eval_support.fail_diags "rename" ds);
  let report = Diff.diff ~old_side:a ~new_side:b in
  let renames =
    List.filter (fun (_, e) -> match e with Diff.Renamed _ -> true | _ -> false) report
  in
  let changes =
    List.filter (fun (_, e) -> match e with Diff.Changed _ -> true | _ -> false) report
  in
  Alcotest.(check int) "exactly one rename" 1 (List.length renames);
  (match renames with
  | [ (n, Diff.Renamed old_name) ] ->
      Alcotest.(check string) "new name" "factorial" n;
      Alcotest.(check string) "old name" "fact" old_name
  | _ -> Alcotest.fail "unexpected rename shape");
  Alcotest.(check int) "zero content changes" 0 (List.length changes)

let test_reformat_is_no_semantic_change () =
  (* same definition, different whitespace and comments *)
  let a = mk_store (base_srcs @ [ fact_src () ]) in
  let b =
    mk_store
      (base_srcs
      @ [
          "; a comment\n\
           (defterm ((binding fact () (lam ((pvar n)) (match (var n) (clause (plit 0) (lit 1)) \
           (clause (pvar m) (app (var mul) (var m) (app (var fact) (app (var sub) (var m) (lit \
           1))))))))))";
        ])
  in
  Alcotest.(check bool)
    "no semantic changes" true
    (Diff.render (Diff.diff ~old_side:a ~new_side:b) = None)

let test_literal_edit_localizes () =
  let a = mk_store (base_srcs @ [ fact_src ~base:1 () ]) in
  let b = mk_store (base_srcs @ [ fact_src ~base:2 () ]) in
  let report = Diff.diff ~old_side:a ~new_side:b in
  match List.assoc_opt "fact" report with
  | Some (Diff.Changed { divergences = [ d ]; _ }) ->
      (* the smallest disagreeing subtree is the literal scalar itself *)
      Alcotest.(check string) "old leaf" "1" d.Diff.a;
      Alcotest.(check string) "new leaf" "2" d.Diff.b;
      Alcotest.(check bool)
        (Printf.sprintf "path descends to the lit node (got %s)" d.Diff.path)
        true
        (let needle = "lit" and hay = d.Diff.path in
         let n = String.length needle and m = String.length hay in
         let rec go i = i + n <= m && (String.sub hay i n = needle || go (i + 1)) in
         go 0)
  | Some (Diff.Changed { divergences; _ }) ->
      Alcotest.failf "expected one divergence, got %d" (List.length divergences)
  | _ -> Alcotest.fail "fact should be Changed"

let test_helper_edit_lists_dependents () =
  let helper base =
    Printf.sprintf
      "(defterm ((binding helper () (lam ((pvar x)) (app (var mul) (var x) (lit %d))))))" base
  in
  let caller = "(defterm ((binding caller () (lam ((pvar y)) (app (var helper) (var y))))))" in
  let a = mk_store (base_srcs @ [ helper 2; caller ]) in
  let b = mk_store (base_srcs @ [ helper 3; caller ]) in
  let report = Diff.diff ~old_side:a ~new_side:b in
  (match List.assoc_opt "helper" report with
  | Some (Diff.Changed { dependents; _ }) ->
      Alcotest.(check (list string)) "dependents listed" [ "caller" ] dependents
  | _ -> Alcotest.fail "helper should be Changed");
  (* caller's own hash changed too (it embeds helper's hash) *)
  match List.assoc_opt "caller" report with
  | Some (Diff.Changed _) -> ()
  | _ -> Alcotest.fail "caller should be Changed (its reference moved)"

let test_added_removed () =
  let a = mk_store [ builtin_stub "mul" ] in
  let b = mk_store [ builtin_stub "sub" ] in
  let report = Diff.diff ~old_side:a ~new_side:b in
  Alcotest.(check bool) "sub added" true (List.assoc_opt "sub" report = Some Diff.Added);
  Alcotest.(check bool) "mul removed" true (List.assoc_opt "mul" report = Some Diff.Removed)

let suite =
  [
    Alcotest.test_case "rename only" `Quick test_rename_only;
    Alcotest.test_case "reformat is no semantic change" `Quick test_reformat_is_no_semantic_change;
    Alcotest.test_case "literal edit localizes" `Quick test_literal_edit_localizes;
    Alcotest.test_case "helper edit lists dependents" `Quick test_helper_edit_lists_dependents;
    Alcotest.test_case "added and removed" `Quick test_added_removed;
  ]
