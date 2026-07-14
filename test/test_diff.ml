open Jacquard

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
  (match Store.rename b ~old_name:"fact" ~new_name:"factorial" () with
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

let test_literal_edit_surface_rendering () =
  let a = mk_store (base_srcs @ [ fact_src ~base:1 () ]) in
  let b = mk_store (base_srcs @ [ fact_src ~base:2 () ]) in
  let report = Diff.diff_with_syntax ~syntax:Diff.Surface ~old_side:a ~new_side:b in
  match List.assoc_opt "fact" report with
  | Some (Diff.Changed { divergences = [ d ]; _ }) ->
      Alcotest.(check string) "old surface leaf" "1" d.Diff.a;
      Alcotest.(check string) "new surface leaf" "2" d.Diff.b
  | Some (Diff.Changed { divergences; _ }) ->
      Alcotest.failf "expected one surface divergence, got %d" (List.length divergences)
  | _ -> Alcotest.fail "fact should be Changed in surface mode"

let test_bootstrap_rendering_remains_default () =
  let a = Form.form "lit" [ Form.Int 1 ] in
  let b = Form.form "tuple" [ Form.F (Form.form "lit" [ Form.Int 1 ]) ] in
  match Diff.form_divergences ~path:"root" a b with
  | [ { Diff.a; b; _ } ] ->
      Alcotest.(check string) "old bootstrap node" "(lit 1)" a;
      Alcotest.(check string) "new bootstrap node" "(tuple (lit 1))" b
  | _ -> Alcotest.fail "expected one whole-node bootstrap divergence"

let test_surface_mode_renders_kernel_nodes () =
  let a = Form.form "lit" [ Form.Int 1 ] in
  let b = Form.form "tuple" [ Form.F (Form.form "lit" [ Form.Int 1 ]) ] in
  match Diff.form_divergences ~syntax:Diff.Surface ~path:"root" a b with
  | [ { Diff.a; b; _ } ] ->
      Alcotest.(check string) "old surface node" "1" a;
      Alcotest.(check string) "new surface node" "(1,)" b
  | _ -> Alcotest.fail "expected one whole-node surface divergence"

let test_store_diff_surface_nodes () =
  let a = mk_store [ "(defterm ((binding changed () (lit 1))))" ] in
  let b = mk_store [ "(defterm ((binding changed () (tuple (lit 1)))))" ] in
  let report = Diff.diff_with_syntax ~syntax:Diff.Surface ~old_side:a ~new_side:b in
  match List.assoc_opt "changed" report with
  | Some (Diff.Changed { divergences = [ d ]; _ }) ->
      Alcotest.(check string) "old store subtree" "1" d.Diff.a;
      Alcotest.(check string) "new store subtree" "(1,)" d.Diff.b
  | _ -> Alcotest.fail "expected one surface-rendered store divergence"

let test_surface_fragment_rendering () =
  let form source =
    match Reader.parse_one ~file:"diff-fragment.jqd" source with
    | Ok form -> form
    | Error ds -> Eval_support.fail_diags "diff fragment read" ds
  in
  let cases =
    [
      ("(pcon some (pvar x))", "Some(x)");
      ("(tapp (tref list) (tref int))", "List Int");
      ("(row (eref net) e)", "->{Net | e}");
      ("(clause (pvar x) (tuple (var x)))", "| x -> (x,)");
      ("(ret (pvar x) (var x))", "| return x -> x");
      ("(opclause abort () k (app (var k) (lit 0)))", "| abort() resume k -> k(0)");
      ("(binding id () (lam ((pvar x)) (var x)))", "id(x) = x");
      ("(con some (field (tvar a)))", "Some a");
      ("(field value (tref int))", "value: Int");
      ("(op choose () (tref bool))", "multi choose : () -> Bool");
      ("(eref net)", "Net");
      ("(rvar e)", "e");
    ]
  in
  List.iter
    (fun (source, expected) ->
      Alcotest.(check string) source expected (Diff.render_form Diff.Surface (form source)))
    cases

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

(* SL.1 regression: a name bound to two kinds (effect + op) in identical stores must not
   be misreported as changed — each binding compares against its own kind's hash. *)
let rec test_multi_kind_name_identical () =
  let srcs =
    [ "(deftype any-t () (con any-v))"; "(defeffect signal () (op signal () (tref any-t)))" ]
  in
  let a = mk_store srcs and b = mk_store srcs in
  let report = Diff.diff ~old_side:a ~new_side:b in
  List.iter
    (fun (n, e) ->
      match e with
      | Diff.Identical -> ()
      | _ -> Alcotest.failf "identical stores must diff clean, but %s was not Identical" n)
    report;
  Alcotest.(check bool) "render is quiet" true (Diff.render report = None);
  test_operation_mode_interface_diff ()

and test_operation_mode_interface_diff () =
  let a = mk_store [ "(defeffect signal ((tvar a)) (op fetch ((tvar a)) (tvar a)))" ] in
  let b = mk_store [ "(defeffect signal ((tvar a)) (op fetch once ((tvar a)) (tvar a)))" ] in
  let check syntax =
    let report = Diff.diff_with_syntax ~syntax ~old_side:a ~new_side:b in
    match List.assoc_opt "signal" report with
    | Some (Diff.Changed { divergences = [ d ]; _ }) ->
        Alcotest.(check string) "old authority" "op `fetch`: multi" d.Diff.a;
        Alcotest.(check string)
          "new authority" "op `fetch`: once (handlers may no longer resume repeatedly)" d.Diff.b
    | _ -> Alcotest.fail "effect mode edit must be a localized interface change"
  in
  check Diff.Bootstrap;
  check Diff.Surface;
  Alcotest.(check string)
    "Once fragments retain the mode in surface syntax" "once fetch : (Int) -> Int"
    (Diff.render_form Diff.Surface
       (match Reader.parse_one ~file:"once-op.jqd" "(op fetch once ((tref int)) (tref int))" with
       | Ok form -> form
       | Error ds -> Eval_support.fail_diags "once op" ds))

let suite =
  [
    Alcotest.test_case "multi-kind name diffs clean" `Quick test_multi_kind_name_identical;
    Alcotest.test_case "rename only" `Quick test_rename_only;
    Alcotest.test_case "reformat is no semantic change" `Quick test_reformat_is_no_semantic_change;
    Alcotest.test_case "literal edit localizes" `Quick test_literal_edit_localizes;
    Alcotest.test_case "literal edit renders as surface" `Quick test_literal_edit_surface_rendering;
    Alcotest.test_case "bootstrap rendering stays default" `Quick
      test_bootstrap_rendering_remains_default;
    Alcotest.test_case "surface mode renders kernel nodes" `Quick
      test_surface_mode_renders_kernel_nodes;
    Alcotest.test_case "store diff renders surface nodes" `Quick test_store_diff_surface_nodes;
    Alcotest.test_case "surface fragment rendering" `Quick test_surface_fragment_rendering;
    Alcotest.test_case "helper edit lists dependents" `Quick test_helper_edit_lists_dependents;
    Alcotest.test_case "added and removed" `Quick test_added_removed;
  ]
