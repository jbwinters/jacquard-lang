open Jacquard

let top_ok src =
  match Reader.parse_one ~file:"surface-print.jqd" src with
  | Error ds -> Eval_support.fail_diags "read" ds
  | Ok form -> (
      match Kernel.of_form form with
      | Ok top -> top
      | Error ds -> Eval_support.fail_diags "validate" ds)

let print ?width top =
  match Surface_print.print_top ?width top with
  | Ok text -> text
  | Error ds -> Eval_support.fail_diags "surface print" ds

let test_core_expressions () =
  let cases =
    [
      ("(lit 1)", "1");
      ("(lit -2.5)", "-2.5");
      ("(lit \"a\\nb\")", "\"a\\nb\"");
      ("(var thing)", "thing");
      ("(app (var f) (lit 1) (lit 2))", "f(1, 2)");
      ("(lam ((pvar x) (pvar y)) (app (var add) (var x) (var y)))", "fn (x, y) -> add(x, y)");
      ("(tuple)", "()");
      ("(tuple (lit 1))", "(1,)");
      ("(tuple (lit 1) (lit 2))", "(1, 2)");
      ("(ann (lit 1) (tref int))", "(1 : Int)");
    ]
  in
  List.iter (fun (src, expected) -> Alcotest.(check string) src expected (print (top_ok src))) cases

let test_blocks () =
  Alcotest.(check string)
    "let block" "{\n  let x = 1\n  f(x)\n}"
    (print (top_ok "(let nonrec (pvar x) (lit 1) (app (var f) (var x)))"));
  Alcotest.(check string)
    "sequencing block" "{\n  f()\n  g()\n}"
    (print (top_ok "(let nonrec (pwild) (app (var f)) (app (var g)))"))

let expr_node ?(meta = Meta.empty) it = Kernel.Expr { Kernel.it; meta }

let test_reference_names () =
  let hash = Hash.of_string "display" in
  let term =
    expr_node ~meta:(Meta.with_name "code.un-form" Meta.empty) (Kernel.Ref (hash, Kernel.Term))
  in
  let con = expr_node ~meta:(Meta.with_name "some" Meta.empty) (Kernel.Ref (hash, Kernel.Con)) in
  Alcotest.(check string) "dotted term" "code.un-form" (print term);
  Alcotest.(check string) "constructor case" "Some" (print con);
  let constructor_call =
    expr_node
      (Kernel.App
         ( { Kernel.it = Kernel.Ref (hash, Kernel.Con); meta = Meta.with_name "some" Meta.empty },
           [ { Kernel.it = Kernel.Lit (Kernel.LInt 1); meta = Meta.empty } ] ))
  in
  Alcotest.(check string) "constructor call" "Some(1)" (print constructor_call);
  let bootstrap_constructor_call =
    expr_node
      (Kernel.App
         ( { Kernel.it = Kernel.Ref (hash, Kernel.Con); meta = Meta.empty },
           [ { Kernel.it = Kernel.Lit (Kernel.LInt 1); meta = Meta.empty } ] ))
  in
  let bootstrap_printed =
    Surface_print.print_top
      ~lookup:(fun kind got ->
        if kind = Surface_name.Con && Hash.equal got hash then Some "mk-fleet" else None)
      bootstrap_constructor_call
  in
  (match bootstrap_printed with
  | Ok actual -> Alcotest.(check string) "bootstrap constructor call" "MkFleet(1)" actual
  | Error ds -> Eval_support.fail_diags "surface print bootstrap constructor" ds);
  let looked_up =
    Surface_print.print_top
      ~lookup:(fun kind got ->
        if kind = Surface_name.Con && Hash.equal got hash then Some "some" else None)
      (expr_node (Kernel.Ref (hash, Kernel.Con)))
  in
  (match looked_up with
  | Ok actual -> Alcotest.(check string) "lookup" "Some" actual
  | Error ds -> Eval_support.fail_diags "surface print lookup" ds);
  let fallback = print (expr_node (Kernel.Ref (hash, Kernel.Con))) in
  Alcotest.(check bool) "hash fallback has kind" true (String.ends_with ~suffix:":con" fallback)

let test_metadata_does_not_change_semantics () =
  let bare = expr_node (Kernel.Lit (Kernel.LInt 7)) in
  let span =
    Span.make ~file:"x" ~start_pos:{ line = 1; col = 1; offset = 0 }
      ~end_pos:{ line = 1; col = 2; offset = 1 }
  in
  let decorated_meta =
    Meta.empty |> Meta.with_span span
    |> Meta.add Meta.key_origin (Meta.Text "agent:test")
    |> Meta.add Meta.key_doc (Meta.Text "seven")
  in
  let decorated = expr_node ~meta:decorated_meta (Kernel.Lit (Kernel.LInt 7)) in
  Alcotest.(check string) "span ignored" (print bare) (print decorated)

let test_file_layout () =
  let tops = [ top_ok "(lit 1)"; top_ok "(app (var f) (lit 2))" ] in
  (match Surface_print.print_file tops with
  | Ok actual -> Alcotest.(check string) "blank line and final newline" "1\n\nf(2)\n" actual
  | Error ds -> Eval_support.fail_diags "surface print file" ds);
  match Surface_print.print_file [] with
  | Ok actual -> Alcotest.(check string) "empty file" "" actual
  | Error ds -> Eval_support.fail_diags "surface print empty file" ds

let test_annotation_inversion () =
  let cases =
    [
      ("tail-only row", "(ann (var f) (tarrow () (row e) (tref int)))", "(f : () ->{| e} Int)");
      ( "nested type argument",
        "(ann (var x) (tapp (tref outer) (tapp (tref inner) (tref int))))",
        "(x : Outer (Inner Int))" );
      ( "nested type head",
        "(ann (var x) (tapp (tapp (tref outer) (tref inner)) (tref int)))",
        "(x : (Outer Inner) Int)" );
      ("empty forall", "(ann (var x) (tforall () () (tref int)))", "(x : forall . Int)");
    ]
  in
  List.iter
    (fun (label, src, expected) -> Alcotest.(check string) label expected (print (top_ok src)))
    cases;
  let net = Hash.of_string "net" in
  let fs = Hash.of_string "fs" in
  let row =
    Kernel.
      { effects = [ Hashed net; Hashed fs ]; rvar = None; wmeta = Meta.with_name "net" Meta.empty }
  in
  let ty =
    Kernel.
      { it = TArrow ([], row, { it = TRef (Named "int"); meta = Meta.empty }); meta = Meta.empty }
  in
  let annotated = expr_node (Kernel.Ann ({ Kernel.it = Kernel.Var "f"; meta = Meta.empty }, ty)) in
  let printed =
    Surface_print.print_top
      ~lookup:(fun kind hash ->
        if kind <> Surface_name.Effect then None
        else if Hash.equal hash net then Some "net"
        else if Hash.equal hash fs then Some "fs"
        else None)
      annotated
  in
  match printed with
  | Ok actual -> Alcotest.(check string) "row metadata not shared" "(f : () ->{Net, Fs} Int)" actual
  | Error ds -> Eval_support.fail_diags "surface print row metadata" ds

let test_wrapping_is_stable () =
  let src =
    "(app (var very-long-function-name) (lit \"first-long-argument\") (lit \
     \"second-long-argument\") (lit \"third-long-argument\"))"
  in
  let once = print ~width:40 (top_ok src) in
  let twice = print ~width:40 (top_ok src) in
  Alcotest.(check string) "deterministic" once twice;
  Alcotest.(check string)
    "canonical wrapping"
    "very-long-function-name(\n\
    \  \"first-long-argument\",\n\
    \  \"second-long-argument\",\n\
    \  \"third-long-argument\")"
    once

let test_unsupported_falls_back () =
  let top = top_ok "(match (lit 1) (clause (pwild) (lit 2)))" in
  let text = print top in
  Alcotest.(check bool) "raw prefix" true (String.starts_with ~prefix:"jqd { " text)

let suite =
  [
    Alcotest.test_case "core expressions" `Quick test_core_expressions;
    Alcotest.test_case "blocks" `Quick test_blocks;
    Alcotest.test_case "reference names" `Quick test_reference_names;
    Alcotest.test_case "metadata" `Quick test_metadata_does_not_change_semantics;
    Alcotest.test_case "file layout" `Quick test_file_layout;
    Alcotest.test_case "annotation inversion" `Quick test_annotation_inversion;
    Alcotest.test_case "wrapping" `Quick test_wrapping_is_stable;
    Alcotest.test_case "fallback" `Quick test_unsupported_falls_back;
  ]
