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

let test_patterns_and_match_arms () =
  let src =
    "(match (var subject) (clause (pwild) (lit 0)) (clause (pvar x) (var x)) (clause (plit \"ok\") \
     (lit 1)) (clause (pcon some (pvar value)) (var value)) (clause (ptuple (pvar only)) (var \
     only)) (clause (ptuple (pvar left) (pwild)) (var left)) (clause (pas whole (ptuple (pvar \
     first) (pvar second))) (var whole)))"
  in
  Alcotest.(check string)
    "all pattern forms"
    {|match subject {
  | _ -> 0
  | x -> x
  | "ok" -> 1
  | Some(value) -> value
  | (only) -> only
  | (left, _) -> left
  | (first, second) as whole -> whole
}|}
    (print (top_ok src));
  let sequenced =
    top_ok "(match (var x) (clause (pwild) (let nonrec (pwild) (app (var log) (var x)) (lit 1))))"
  in
  Alcotest.(check string)
    "sequencing arm braces" "match x {\n  | _ -> {\n    log(x)\n    1\n  }\n}" (print sequenced);
  let long_body =
    print ~width:35
      (top_ok
         "(match (var x) (clause (pwild) (app (var very-long-function-name) (lit \
          \"first-long-argument\") (lit \"second-long-argument\"))))")
  in
  let arm_start = String.index long_body '>' + 1 in
  let arm_text = String.sub long_body arm_start (String.length long_body - arm_start) in
  Alcotest.(check bool) "single expression stays unbraced" false (String.contains arm_text '{')

let test_handlers () =
  let atomic =
    top_ok "(handle (app (var body)) (ret (pvar x) (var x)) (opclause abort () unused (lit 0)))"
  in
  Alcotest.(check string)
    "atomic body" "handle body() {\n  | return x -> x\n  | abort() resume unused -> 0\n}"
    (print atomic);
  let underscore =
    match atomic with
    | Kernel.Expr ({ Kernel.it = Kernel.Handle { body; ret; ops }; _ } as expr) ->
        let ops = List.map (fun op -> { op with Kernel.resume = "_" }) ops in
        Kernel.Expr { expr with Kernel.it = Kernel.Handle { body; ret; ops } }
    | _ -> Alcotest.fail "handler fixture shape"
  in
  Alcotest.(check string)
    "unreferenceable resume" "handle body() {\n  | return x -> x\n  | abort() resume _ -> 0\n}"
    (print underscore);
  let group_body =
    match atomic with
    | Kernel.Expr ({ Kernel.it = Kernel.Handle { ret; ops; _ }; _ } as expr) ->
        let body = { Kernel.it = Kernel.GroupRef 0; meta = Meta.empty } in
        Kernel.Expr { expr with Kernel.it = Kernel.Handle { body; ret; ops } }
    | _ -> Alcotest.fail "handler fixture shape"
  in
  Alcotest.(check string)
    "internal reference uses D35 block"
    "handle {\n  #group[0]\n} {\n  | return x -> x\n  | abort() resume unused -> 0\n}"
    (print group_body);
  let non_atomic =
    top_ok
      "(handle (match (var direction) (clause (pcon up) (app (var risky))) (clause (pcon down) \
       (app (var safe)))) (ret (pvar x) (var x)) (opclause abort () unused (lit 0)))"
  in
  Alcotest.(check string)
    "D35 explicit body block"
    {|handle {
  match direction {
    | Up -> risky()
    | Down -> safe()
  }
} {
  | return x -> x
  | abort() resume unused -> 0
}|}
    (print non_atomic)

let test_quote_and_unquote () =
  Alcotest.(check string)
    "surface quote" "quote { unquote(f)(41) }"
    (print (top_ok "(quote (app (unquote (var f)) (lit 41)))"));
  Alcotest.(check string)
    "raw quoted triple" "quote { jqd { (mystery foo) } }"
    (print (top_ok "(quote (mystery foo))"));
  Alcotest.(check string)
    "nested quote staging" "quote { quote { unquote(f)(1) } }"
    (print (top_ok "(quote (quote (app (unquote (var f)) (lit 1))))"))

let test_declarations () =
  Alcotest.(check string)
    "annotated equation" "id : (a) ->{} a\nid(x) = x"
    (print
       (top_ok
          "(defterm ((binding id ((tarrow ((tvar a)) (row) (tvar a))) (lam ((pvar x)) (var x)))))"));
  Alcotest.(check string)
    "sum declaration" "type Option a = | None | Some a"
    (print (top_ok "(deftype option ((tvar a)) (con none) (con some (field (tvar a))))"));
  Alcotest.(check string)
    "labeled fields" "type Fleet = | MkFleet(inv: SvcMood, pay: SvcMood)"
    (print
       (top_ok
          "(deftype fleet () (con mk-fleet (field inv (tref svc-mood)) (field pay (tref \
           svc-mood))))"));
  Alcotest.(check string)
    "effect declaration" "effect Choice a where {\n  choose : () -> Bool\n}"
    (print (top_ok "(defeffect choice ((tvar a)) (op choose () (tref bool)))"));
  Alcotest.(check string)
    "mutually recursive group" "even(n) = #group[1](n)\nodd(n) = #group[0](n)"
    (print
       (top_ok
          "(defterm ((binding even () (lam ((pvar n)) (app (groupref 1) (var n)))) (binding odd () \
           (lam ((pvar n)) (app (groupref 0) (var n))))))"));
  let wrapped =
    print ~width:42
      (top_ok
         "(deftype outcome () (con completely-clear) (con unexpectedly-choppy) (con \
          total-blackout))")
  in
  Alcotest.(check string)
    "constructor list wraps one per line"
    "type Outcome =\n  | CompletelyClear\n  | UnexpectedlyChoppy\n  | TotalBlackout" wrapped

let test_kernel_form_inventory () =
  let sources =
    [
      "(lit 1)";
      "(var x)";
      "(ref #0000000000000000000000000000000000000000000000000000000000000000 term)";
      "(lam ((pvar x)) (var x))";
      "(app (var f) (lit 1))";
      "(let nonrec (pvar x) (lit 1) (var x))";
      "(match (lit 1) (clause (pwild) (lit 2)))";
      "(tuple (lit 1) (lit 2))";
      "(handle (lit 1) (ret (pvar x) (var x)))";
      "(quote (unquote (var x)))";
      "(ann (var x) (ttuple (tref int) (tvar a)))";
      "(defterm ((binding x () (lit 1))))";
      "(deftype option ((tvar a)) (con none) (con some (field (tvar a))))";
      "(defeffect choice () (op choose () (tref bool)))";
    ]
  in
  List.iter
    (fun source ->
      let output = print (top_ok source) in
      Alcotest.(check bool) (source ^ " is nonempty") false (String.equal output "");
      Alcotest.(check bool)
        (source ^ " is native surface") false
        (String.starts_with ~prefix:"jqd { " output))
    sources

let test_generated_accessors_print_once () =
  let type_decl = top_ok "(deftype fleet () (con mk-fleet (field inv (tref svc-mood))))" in
  let generated =
    match top_ok "(defterm ((binding fleet.inv () (lam ((pvar fleet)) (var fleet)))))" with
    | Kernel.Decl ({ Kernel.it = Kernel.DefTerm [ binding ]; _ } as decl) ->
        let binding =
          { binding with Kernel.bmeta = Meta.with_surface_generated "accessor" binding.bmeta }
        in
        Kernel.Decl { decl with Kernel.it = Kernel.DefTerm [ binding ] }
    | _ -> Alcotest.fail "generated accessor fixture shape"
  in
  Alcotest.(check string) "generated top omitted" "" (print generated);
  match Surface_print.print_file [ type_decl; generated ] with
  | Ok actual ->
      Alcotest.(check string)
        "type is the only emitted item" "type Fleet = | MkFleet(inv: SvcMood)\n" actual
  | Error ds -> Eval_support.fail_diags "surface print generated accessor" ds

let test_ambiguous_group_falls_back () =
  let top = top_ok "(defterm ((binding first () (lit 1)) (binding second () (lit 2))))" in
  let text = print top in
  Alcotest.(check bool) "raw prefix" true (String.starts_with ~prefix:"jqd { " text);
  let raw = String.sub text 6 (String.length text - 8) in
  let reparsed = top_ok raw in
  Alcotest.(check bool)
    "raw fallback preserves group boundary" true
    (Form.equal_ignoring_meta (Kernel.to_form top) (Kernel.to_form reparsed));
  let nested_as =
    print (top_ok "(match (var x) (clause (pas outer (pas inner (pvar value))) (var value)))")
  in
  Alcotest.(check bool)
    "nested as-pattern has total fallback" true
    (String.starts_with ~prefix:"jqd { " nested_as)

let suite =
  [
    Alcotest.test_case "core expressions" `Quick test_core_expressions;
    Alcotest.test_case "blocks" `Quick test_blocks;
    Alcotest.test_case "reference names" `Quick test_reference_names;
    Alcotest.test_case "metadata" `Quick test_metadata_does_not_change_semantics;
    Alcotest.test_case "file layout" `Quick test_file_layout;
    Alcotest.test_case "annotation inversion" `Quick test_annotation_inversion;
    Alcotest.test_case "wrapping" `Quick test_wrapping_is_stable;
    Alcotest.test_case "patterns and matches" `Quick test_patterns_and_match_arms;
    Alcotest.test_case "handlers" `Quick test_handlers;
    Alcotest.test_case "quote and unquote" `Quick test_quote_and_unquote;
    Alcotest.test_case "declarations" `Quick test_declarations;
    Alcotest.test_case "27-form inventory" `Quick test_kernel_form_inventory;
    Alcotest.test_case "generated accessors" `Quick test_generated_accessors_print_once;
    Alcotest.test_case "fallback" `Quick test_ambiguous_group_falls_back;
  ]
