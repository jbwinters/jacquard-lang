open Jacquard

let test_name_projection () =
  Alcotest.(check (option string)) "mk-fleet" (Some "MkFleet") (Surface_name.to_pascal "mk-fleet");
  Alcotest.(check (option string)) "roundtrip" (Some "mk-fleet") (Surface_name.of_pascal "MkFleet");
  Alcotest.(check (option string))
    "acronym roundtrip" (Some "h-t-t-p-request")
    (Surface_name.of_pascal "HTTPRequest");
  Alcotest.(check (option string))
    "repeated hyphen needs escape" None (Surface_name.to_pascal "a--b");
  Alcotest.(check (option string)) "trailing hyphen needs escape" None (Surface_name.to_pascal "a-");
  Alcotest.(check string)
    "constructor" "MkFleet"
    (Surface_print.render_name Surface_name.Con "mk-fleet");
  Alcotest.(check string)
    "dotted term" "code.un-form"
    (Surface_print.render_name Surface_name.Term "code.un-form");
  Alcotest.(check (option string))
    "parser shares projection" (Some "mk-fleet")
    (Surface_parse.kernel_name_of_pascal "MkFleet")

let pp_kind fmt kind =
  Format.pp_print_string fmt
    (match kind with
    | Surface_name.Term -> "term"
    | Surface_name.Op -> "op"
    | Surface_name.Type -> "type"
    | Surface_name.Con -> "con"
    | Surface_name.Effect -> "effect"
    | Surface_name.Tvar -> "tvar"
    | Surface_name.Rvar -> "rvar")

let test_name_fallbacks () =
  Alcotest.(check string) "keyword" "`term:match`" (Surface_name.render Surface_name.Term "match");
  List.iter
    (fun keyword ->
      if String.equal keyword (String.lowercase_ascii keyword) then
        List.iter
          (fun (kind, tag) ->
            Alcotest.(check string)
              (Printf.sprintf "%s keyword %s" tag keyword)
              (Printf.sprintf "`%s:%s`" tag keyword)
              (Surface_name.render kind keyword))
          [
            (Surface_name.Term, "term");
            (Surface_name.Op, "op");
            (Surface_name.Tvar, "tvar");
            (Surface_name.Rvar, "rvar");
          ])
    Surface_lex.keywords;
  Alcotest.(check string)
    "non-invertible constructor" "`con:a--b`"
    (Surface_name.render Surface_name.Con "a--b");
  Alcotest.(check (option (pair (testable pp_kind ( = )) string)))
    "decode"
    (Some (Surface_name.Con, "a--b"))
    (Surface_name.decode_escaped "`con:a--b`");
  let invert source =
    let original =
      match Reader.parse_one ~file:"reserved-name.jqd" source with
      | Ok form -> (
          match Kernel.of_form form with
          | Ok top -> top
          | Error diagnostics -> Eval_support.fail_diags "reserved-name kernel" diagnostics)
      | Error diagnostics -> Eval_support.fail_diags "reserved-name bootstrap" diagnostics
    in
    let rendered =
      match Surface_print.print_top original with
      | Ok text -> text ^ "\n"
      | Error diagnostics -> Eval_support.fail_diags "reserved-name print" diagnostics
    in
    match Surface_parse.parse_string ~file:"reserved-name.jac" rendered with
    | Error diagnostics -> Eval_support.fail_diags "reserved-name parse" diagnostics
    | Ok tops -> (
        match Surface_lower.lower_tops tops with
        | Error diagnostics -> Eval_support.fail_diags "reserved-name lower" diagnostics
        | Ok [ reparsed ] ->
            Alcotest.(check bool)
              (source ^ " print/parse inversion")
              true
              (Form.equal_ignoring_meta (Kernel.to_form original) (Kernel.to_form reparsed))
        | Ok _ -> Alcotest.fail "reserved-name inversion changed the top count")
  in
  List.iter invert
    [
      "(defterm ((binding once () (lit 1)) (binding multi () (lit 2))))";
      "(defeffect modes ((tvar once) (tvar multi)) (op once once ((tvar multi)) (tvar once)) (op \
       multi ((tvar once)) (tvar multi)))";
      "(defterm ((binding once ((tarrow () (row once) (ttuple))) (lit 1))))";
      "(defterm ((binding multi ((tarrow () (row multi) (ttuple))) (lit 2))))";
    ]

let test_surface_metadata () =
  let meta =
    Meta.empty |> Meta.with_surface_form "if"
    |> Meta.with_surface_generated "accessor"
    |> Meta.with_surface_hole "7" |> Meta.with_surface_ref_kind "con"
  in
  Alcotest.(check (option string)) "surface form" (Some "if") (Meta.surface_form meta);
  Alcotest.(check (option string)) "generated shape" (Some "accessor") (Meta.surface_generated meta);
  Alcotest.(check (option string)) "hole shape" (Some "7") (Meta.surface_hole meta);
  Alcotest.(check (option string)) "reference kind" (Some "con") (Meta.surface_ref_kind meta)

let test_holes_stop_at_strict_boundary () =
  let hole = Surface_ast.node (Surface_ast.Hole 1) in
  let top = Surface_ast.node (Surface_ast.TopExpr hole) in
  let recovered =
    Surface_ast.{ items = [ top ]; diagnostics = []; meta = Meta.empty; source = "" }
  in
  Alcotest.(check bool) "hole detected" true (Surface_ast.has_holes_top top);
  match Surface_parse.strict recovered with
  | Error [ diagnostic ] when Diag.code diagnostic = Some "E1202" -> ()
  | _ -> Alcotest.fail "strict parsing must reject holes before lowering or hashing"

let test_entry_point_contract () =
  (match Surface_parse.parse_string ~file:"empty.jac" "" with
  | Ok [] -> ()
  | _ -> Alcotest.fail "empty surface source should parse as an empty file");
  match Surface_parse.parse_string ~file:"future.jac" "x = 1" with
  | Ok
      [
        {
          Surface_ast.it =
            Surface_ast.Definition
              { name = "x"; equation = false; params = []; value = { it = Lit (LInt 1); _ } };
          _;
        };
      ] ->
      ()
  | _ -> Alcotest.fail "the SS.8 entry point must parse a complete value definition"

let test_printer_contract () =
  let top = Kernel.Expr { Kernel.it = Kernel.Lit (Kernel.LInt 1); meta = Meta.empty } in
  match Surface_print.print_top top with
  | Ok "1" -> ()
  | _ -> Alcotest.fail "surface printer module must stay wired through its public contract"

let suite =
  [
    Alcotest.test_case "D34 projection" `Quick test_name_projection;
    Alcotest.test_case "name fallbacks" `Quick test_name_fallbacks;
    Alcotest.test_case "surface metadata" `Quick test_surface_metadata;
    Alcotest.test_case "holes stop at strict boundary" `Quick test_holes_stop_at_strict_boundary;
    Alcotest.test_case "entry-point contract" `Quick test_entry_point_contract;
    Alcotest.test_case "printer contract" `Quick test_printer_contract;
  ]
