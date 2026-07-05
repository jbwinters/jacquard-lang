open Jacquard

(* SL.1: the library-name grammar (dotted segments, ?/! suffixes) and the kind-aware
   (name, kind) index with value-position precedence. *)

let test_grammar_accepts () =
  List.iter
    (fun n -> Alcotest.(check bool) (n ^ " accepted") true (Reader.valid_library_symbol n))
    [ "list.map"; "empty?"; "head!"; "deep.dotted.name"; "x"; "a-b.c-d"; "map.contains?"; "a1.b2!" ]

let test_grammar_rejects () =
  List.iter
    (fun n -> Alcotest.(check bool) (n ^ " rejected") false (Reader.valid_library_symbol n))
    [
      ".leading";
      "trailing.";
      "a..b";
      "mid?fix";
      "a!b";
      "double??";
      "bang!?";
      "?";
      "!";
      "";
      "Caps.x";
      "9x.y";
      "a.";
      "a.?";
    ]

let test_reader_parses_new_symbols () =
  (match Reader.parse_one ~file:"n.jqd" "(app (var list.map) (var xs.tail!))" with
  | Ok { Form.args = [ Form.F { Form.args = [ Form.Sym "list.map" ]; _ }; _ ]; _ } -> ()
  | _ -> Alcotest.fail "dotted symbols should parse as single atoms");
  (* heads keep the strict grammar *)
  match Reader.parse_one ~file:"n.jqd" "(list.map (lit 1))" with
  | Error [ d ] -> Alcotest.(check string) "dotted head rejected" "E0107" d.Diag.code
  | _ -> Alcotest.fail "a dotted head must be rejected"

let test_printer_roundtrip_new_symbols () =
  let src = "(app (var list.map) (var pred?) (var force!))" in
  let f = Result.get_ok (Reader.parse_one ~file:"n.jqd" src) in
  let printed = Printer.print f in
  let f' = Result.get_ok (Reader.parse_one ~file:"n2.jqd" printed) in
  Alcotest.(check bool) "roundtrip" true (Form.equal_ignoring_meta f f')

(* --- kind-aware index --- *)

let fresh_store () =
  match Store.open_store (Eval_support.fresh_dir ()) with
  | Ok s -> s
  | Error ds -> Eval_support.fail_diags "open_store" ds

let put store src = ignore (Eval_support.put_src store (Store.names_view store) src)

let test_effect_and_op_share_a_name () =
  let store = fresh_store () in
  (* the ring 1 shape that used to collide: effect `signal` whose op is also `signal` *)
  put store "(deftype any-t () (con any-v))";
  put store "(defeffect signal () (op signal () (tref any-t)))";
  let kinds =
    List.map (fun e -> e.Resolve.kind) (Store.lookup_all store "signal") |> List.sort_uniq compare
  in
  Alcotest.(check int) "two bindings" 2 (List.length kinds);
  Alcotest.(check bool) "op present" true (Store.lookup_kind store "signal" Resolve.KOp <> None);
  Alcotest.(check bool)
    "effect present" true
    (Store.lookup_kind store "signal" Resolve.KEffect <> None);
  (* names.jqd round-trips duplicates through reopen *)
  let store2 =
    match Store.open_store store.Store.root with
    | Ok s -> s
    | Error ds -> Eval_support.fail_diags "reopen" ds
  in
  Alcotest.(check int) "persisted" 2 (List.length (Store.lookup_all store2 "signal"))

let test_kind_directed_resolution () =
  let store = fresh_store () in
  put store "(deftype any-t () (con any-v))";
  put store "(defeffect signal () (op signal () (tref any-t)))";
  (* an eref position picks the EFFECT binding; a var picks the OP (value precedence) *)
  let e =
    match
      Reader.parse_one ~file:"k.jqd"
        "(ann (var any-v) (tarrow () (row (eref signal)) (tref any-t)))"
    with
    | Ok f -> Result.get_ok (Kernel.expr_of_form f)
    | Error _ -> Alcotest.fail "parse"
  in
  (match Resolve.resolve_expr (Store.names_view store) e with
  | Ok _ -> ()
  | Error ds -> Eval_support.fail_diags "eref position resolves the effect" ds);
  let v =
    match Reader.parse_one ~file:"k.jqd" "(app (var signal))" with
    | Ok f -> Result.get_ok (Kernel.expr_of_form f)
    | Error _ -> Alcotest.fail "parse"
  in
  match Resolve.resolve_expr (Store.names_view store) v with
  | Ok { Kernel.it = Kernel.App ({ Kernel.it = Kernel.Ref (_, Kernel.Op); _ }, _); _ } -> ()
  | Ok _ -> Alcotest.fail "var position should resolve signal to the op"
  | Error ds -> Eval_support.fail_diags "var position" ds

let test_value_precedence_and_warning () =
  (* a term and a con sharing a name: term wins in value position, W0301 warns *)
  let store = fresh_store () in
  put store "(deftype wrap () (con boxed (field (tref wrap))))";
  put store "(defterm ((binding boxed () (lit 1))))";
  let e =
    match Reader.parse_one ~file:"w.jqd" "(var boxed)" with
    | Ok f -> Result.get_ok (Kernel.expr_of_form f)
    | Error _ -> Alcotest.fail "parse"
  in
  match Resolve.resolve_expr_w (Store.names_view store) e with
  | Ok ({ Kernel.it = Kernel.Ref (_, Kernel.Term); _ }, [ w ]) ->
      Alcotest.(check string) "warning code" "W0301" w.Diag.code
  | Ok (_, ws) -> Alcotest.failf "expected term ref + 1 warning, got %d warnings" (List.length ws)
  | Error ds -> Eval_support.fail_diags "resolve" ds

let test_rename_ambiguous_needs_kind () =
  let store = fresh_store () in
  put store "(deftype any-t () (con any-v))";
  put store "(defeffect signal () (op signal () (tref any-t)))";
  (match Store.rename store ~old_name:"signal" ~new_name:"sig2" () with
  | Error [ d ] -> Alcotest.(check string) "ambiguous" "E0607" d.Diag.code
  | _ -> Alcotest.fail "ambiguous rename must fail");
  (* with the kind it works and only moves that binding *)
  (match Store.rename store ~old_name:"signal" ~new_name:"sig-op" ~kind:Resolve.KOp () with
  | Ok () -> ()
  | Error ds -> Eval_support.fail_diags "kinded rename" ds);
  Alcotest.(check bool) "op moved" true (Store.lookup_kind store "sig-op" Resolve.KOp <> None);
  Alcotest.(check bool)
    "effect stayed" true
    (Store.lookup_kind store "signal" Resolve.KEffect <> None)

let test_dotted_names_in_store () =
  let store = fresh_store () in
  put store "(defterm ((binding list.map-stub () (lit 1))))";
  Alcotest.(check bool) "dotted binding" true (Store.lookup_name store "list.map-stub" <> None);
  match Store.rename store ~old_name:"list.map-stub" ~new_name:"list.map!" () with
  | Ok () ->
      Alcotest.(check bool) "marked name ok" true (Store.lookup_name store "list.map!" <> None)
  | Error ds -> Eval_support.fail_diags "rename to marked name" ds

let suite =
  [
    Alcotest.test_case "grammar accepts" `Quick test_grammar_accepts;
    Alcotest.test_case "grammar rejects" `Quick test_grammar_rejects;
    Alcotest.test_case "reader parses new symbols; heads stay strict" `Quick
      test_reader_parses_new_symbols;
    Alcotest.test_case "printer roundtrip" `Quick test_printer_roundtrip_new_symbols;
    Alcotest.test_case "effect and op share a name" `Quick test_effect_and_op_share_a_name;
    Alcotest.test_case "kind-directed resolution" `Quick test_kind_directed_resolution;
    Alcotest.test_case "value precedence warns W0301" `Quick test_value_precedence_and_warning;
    Alcotest.test_case "ambiguous rename needs --kind" `Quick test_rename_ambiguous_needs_kind;
    Alcotest.test_case "dotted names in the store" `Quick test_dotted_names_in_store;
  ]
