open Jacquard

let fail_diags label diagnostics =
  Alcotest.failf "%s: %s" label (String.concat "; " (List.map Diag.to_string diagnostics))

let parse_surface_expr ?(file = "surface.jac") source =
  match Surface_parse.parse_string ~file source with
  | Ok [ { Surface_ast.it = TopExpr expression; _ } ] -> expression
  | Ok items ->
      Alcotest.failf "expected one surface expression, got %d top-level items" (List.length items)
  | Error diagnostics -> fail_diags "surface parse" diagnostics

let lower ?file source =
  match Surface_lower.lower_expr (parse_surface_expr ?file source) with
  | Ok expression -> expression
  | Error diagnostics -> fail_diags "surface lower" diagnostics

let bootstrap source =
  match Reader.parse_one ~file:"equivalent.jqd" source with
  | Error diagnostics -> fail_diags "bootstrap parse" diagnostics
  | Ok form -> (
      match Kernel.expr_of_form form with
      | Ok expression -> expression
      | Error diagnostics -> fail_diags "bootstrap validate" diagnostics)

let check_equivalent label surface jqd =
  let actual = Kernel.expr_to_form (lower surface) in
  let expected = Kernel.expr_to_form (bootstrap jqd) in
  Alcotest.(check bool) label true (Form.equal_ignoring_meta expected actual)

let error_codes source =
  match Surface_parse.parse_string ~file:"bad.jac" source with
  | Ok _ -> Alcotest.failf "expected %S to fail surface parsing" source
  | Error diagnostics -> List.map (fun diagnostic -> diagnostic.Diag.code) diagnostics

let lower_error source =
  let expression = parse_surface_expr source in
  match Surface_lower.lower_expr expression with
  | Ok _ -> Alcotest.failf "expected %S to fail lowering" source
  | Error diagnostics -> diagnostics

let test_atoms () =
  let zeros = String.make 64 '0' in
  check_equivalent "integer" "42" "(lit 42)";
  check_equivalent "real" "-2.5" "(lit -2.5)";
  check_equivalent "text" {|"ok"|} {|(lit "ok")|};
  check_equivalent "lower name" "code.un-form" "(var code.un-form)";
  check_equivalent "D34 uppercase name" "MkFleet" "(var mk-fleet)";
  check_equivalent "hash ref" (Printf.sprintf "#%s:op" zeros) (Printf.sprintf "(ref #%s op)" zeros);
  check_equivalent "group ref" "#group[7]" "(groupref 7)"

let test_calls () =
  check_equivalent "zero arguments" "f()" "(app (var f))";
  check_equivalent "multiline arguments" "f(\n  1,\n  2\n)" "(app (var f) (lit 1) (lit 2))";
  check_equivalent "postfix left associativity" "f()(1)(2, 3)"
    "(app (app (app (var f)) (lit 1)) (lit 2) (lit 3))"

let test_functions_and_patterns () =
  check_equivalent "function and irrefutable patterns" "fn (_, (x, y)) -> x"
    "(lam ((pwild) (ptuple (pvar x) (pvar y))) (var x))";
  check_equivalent "zero argument function" "fn () -> ()" "(lam () (tuple))";
  List.iter
    (fun source ->
      Alcotest.(check bool)
        (source ^ " is rejected during lowering")
        true
        (List.exists (fun diagnostic -> diagnostic.Diag.code = "E0205") (lower_error source)))
    [ "fn (1) -> 2"; "fn (Some(x)) -> 2" ];
  Alcotest.(check bool)
    "refutable let is rejected during lowering" true
    (List.exists
       (fun diagnostic -> diagnostic.Diag.code = "E0206")
       (lower_error "{ let 1 = 2; 3 }"));
  check_equivalent "irrefutable as parameter" "fn (x as whole) -> whole"
    "(lam ((pas whole (pvar x))) (var whole))"

let test_parentheses_and_tuples () =
  check_equivalent "grouping" "(1)" "(lit 1)";
  check_equivalent "unit" "()" "(tuple)";
  check_equivalent "singleton" "(1,)" "(tuple (lit 1))";
  check_equivalent "multi" "(1, 2, f(3))" "(tuple (lit 1) (lit 2) (app (var f) (lit 3)))"

let test_annotations_and_complete_types () =
  let zeros = String.make 64 '0' in
  let surface =
    Printf.sprintf "(x : forall a | e. (List a, #%s:type) ->{Console, #%s:effect | e} (a,))" zeros
      zeros
  in
  let jqd =
    Printf.sprintf
      "(ann (var x) (tforall ((tvar a)) ((rvar e)) (tarrow ((tapp (tref list) (tvar a)) (tref \
       #%s)) (row (eref console) (eref #%s) e) (ttuple (tvar a)))))"
      zeros zeros
  in
  check_equivalent "forall/application/tuple/arrow/row/hash" surface jqd;
  check_equivalent "empty forall and empty row" "(x : forall . () ->{} Unit)"
    "(ann (var x) (tforall () () (tarrow () (row) (tref unit))))";
  check_equivalent "multiline forall continuation"
    "(x : forall a\n | e.\n(a) ->{\n  Console\n| e\n}\na)"
    "(ann (var x) (tforall ((tvar a)) ((rvar e)) (tarrow ((tvar a)) (row (eref console) e) (tvar \
     a))))";
  check_equivalent "grouped type" "(x : (List a))" "(ann (var x) (tapp (tref list) (tvar a)))";
  Alcotest.(check bool)
    "row trailing comma rejected" true
    (List.mem "E1220" (error_codes "(x : () ->{Console,} Unit)"))

let test_forall_row_var_requirement () =
  check_equivalent "vacuous forall" "(x : forall . T)" "(ann (var x) (tforall () () (tref t)))";
  check_equivalent "type variables only" "(x : forall a. T)"
    "(ann (var x) (tforall ((tvar a)) () (tref t)))";
  check_equivalent "row variables only" "(x : forall | e. T)"
    "(ann (var x) (tforall () ((rvar e)) (tref t)))";
  check_equivalent "type and row variables" "(x : forall a | e. T)"
    "(ann (var x) (tforall ((tvar a)) ((rvar e)) (tref t)))";
  List.iter
    (fun source ->
      match Surface_parse.parse_string ~file:"forall.jac" source with
      | Error diagnostics -> (
          match List.find_opt (fun diagnostic -> diagnostic.Diag.code = "E1220") diagnostics with
          | Some { Diag.span = Some span; _ } ->
              let dot = String.index source '.' in
              Alcotest.(check int) (source ^ " diagnostic offset") dot span.Span.start_pos.offset
          | Some _ -> Alcotest.failf "%s: forall row-variable diagnostic has no span" source
          | None -> Alcotest.failf "%s: expected an E1220 parser diagnostic" source)
      | Ok _ -> Alcotest.failf "%s: accepted an empty row-variable section" source)
    [ "(x : forall a | . T)"; "(x : forall | . T)" ]

let test_blocks_and_lets () =
  check_equivalent "bare expression sequencing" "{ 1\n2 }" "(let nonrec (pwild) (lit 1) (lit 2))";
  check_equivalent "semicolon sequencing" "{ 1; 2 }" "(let nonrec (pwild) (lit 1) (lit 2))";
  check_equivalent "tuple local binding" "{ let (x, y) = (1, 2); x }"
    "(let nonrec (ptuple (pvar x) (pvar y)) (tuple (lit 1) (lit 2)) (var x))";
  check_equivalent "recursive local function" "{ let rec f(x) = f(x); f(1) }"
    "(let rec (pvar f) (lam ((pvar x)) (app (var f) (var x))) (app (var f) (lit 1)))";
  check_equivalent "nested block final value" "{ let x = { 1; 2 }; x }"
    "(let nonrec (pvar x) (let nonrec (pwild) (lit 1) (lit 2)) (var x))"

let test_newline_and_separator_rules () =
  check_equivalent "newline does not continue a call" "{ f\n(1) }"
    "(let nonrec (pwild) (var f) (lit 1))";
  Alcotest.(check (list string)) "missing block separator" [ "E1223" ] (error_codes "{ 1 2 }");
  Alcotest.(check bool)
    "call list permits newlines" true
    (match Surface_parse.parse_string ~file:"ok.jac" "f(\n1,\n2\n)" with
    | Ok _ -> true
    | Error _ -> false);
  check_equivalent "multiline list layout" "outer(\n  f(\n    x,\n    y\n  ),\n  z\n)"
    "(app (var outer) (app (var f) (var x) (var y)) (var z))";
  List.iter
    (fun source ->
      Alcotest.(check bool)
        (source ^ " rejects newline postfix attachment")
        true
        (List.mem "E1220" (error_codes source)))
    [ "outer(f\n(x), y)"; "(f\n(x), y)"; "(f\n(x) : T)"; "(f\n(x))" ]

let test_block_lowering_errors () =
  (match lower_error "{}" with
  | [ { Diag.code = "E1231"; span = Some span; _ } ] ->
      Alcotest.(check string) "empty block span" "surface.jac:1:1-3" (Span.to_string span)
  | diagnostics -> fail_diags "empty block diagnostic" diagnostics);
  (match lower_error "{ let x = 1 }" with
  | [ { Diag.code = "E1232"; span = Some span; _ } ] ->
      Alcotest.(check string) "final let span" "surface.jac:1:7-12" (Span.to_string span)
  | diagnostics -> fail_diags "final let diagnostic" diagnostics);
  match lower_error "{ let rec (f, g)(x) = x; f }" with
  | [ { Diag.code = "E1233"; span = Some _; _ } ] -> ()
  | diagnostics -> fail_diags "recursive binder diagnostic" diagnostics

let test_generated_spans_and_provenance () =
  let sequence = lower ~file:"span.jac" "{\n  1\n  2\n}" in
  (match sequence.Kernel.it with
  | Kernel.Let { binder; body; _ } ->
      Alcotest.(check (option string))
        "sequence provenance" (Some "block-sequence") (Meta.surface_form sequence.meta);
      Alcotest.(check (option string))
        "wildcard provenance" (Some "block-sequence-wildcard") (Meta.surface_form binder.meta);
      Alcotest.(check (option string))
        "sequence span" (Some "span.jac:2:3-3:4")
        (Option.map Span.to_string (Meta.span sequence.meta));
      Alcotest.(check bool) "body retains source span" true (Option.is_some (Meta.span body.meta))
  | _ -> Alcotest.fail "expected generated sequence let");
  let recursive = lower ~file:"span.jac" "{\n  let rec f(x) = x\n  f(1)\n}" in
  match recursive.Kernel.it with
  | Kernel.Let { value = { Kernel.it = Kernel.Lam _; meta = lambda_meta }; _ } ->
      Alcotest.(check (option string))
        "rec let provenance" (Some "let-rec")
        (Meta.surface_form recursive.meta);
      Alcotest.(check (option string))
        "generated lambda provenance" (Some "let-rec-fn") (Meta.surface_form lambda_meta);
      Alcotest.(check (option string))
        "generated lambda span" (Some "span.jac:2:11-19")
        (Option.map Span.to_string (Meta.span lambda_meta));
      Alcotest.(check (option string))
        "recursive let span" (Some "span.jac:2:11-3:7")
        (Option.map Span.to_string (Meta.span recursive.meta))
  | _ -> Alcotest.fail "expected recursive let with generated lambda"

let test_recovery_preserves_later_expression () =
  let recovered = Surface_parse.recover_string ~file:"recover.jac" "f(,)\n42\n" in
  Alcotest.(check bool)
    "diagnostic survives" true
    (List.exists (fun diagnostic -> diagnostic.Diag.code = "E1220") recovered.diagnostics);
  match List.rev recovered.items with
  | { Surface_ast.it = TopExpr { it = Lit (LInt 42); _ }; _ } :: _ -> ()
  | _ -> Alcotest.fail "call recovery discarded the later valid top-level expression"

let test_nested_lexical_recovery () =
  let recovered = Surface_parse.recover_string ~file:"recover.jac" "f(1, @, 2)\n42\n" in
  Alcotest.(check (list string))
    "nested lexical diagnostic retained" [ "E1210" ]
    (List.map (fun diagnostic -> diagnostic.Diag.code) recovered.diagnostics);
  match List.rev recovered.items with
  | { Surface_ast.it = TopExpr { it = Lit (LInt 42); _ }; _ } :: _ -> ()
  | _ -> Alcotest.fail "nested lexical recovery discarded the later expression"

let h name = Hash.of_string ("surface-stub:" ^ name)

let test_value_reference_kind_survives () =
  let term_hash = h "same-term" in
  let con_hash = h "same-con" in
  let op_hash = h "same-op" in
  let fleet_term_hash = h "fleet-term" in
  let fleet_con_hash = h "fleet-con" in
  let names =
    Resolve.of_alist
      [
        ("same", { Resolve.hash = term_hash; kind = Resolve.KTerm });
        ("same", { Resolve.hash = con_hash; kind = Resolve.KCon });
        ("same", { Resolve.hash = op_hash; kind = Resolve.KOp });
        ("mk-fleet", { Resolve.hash = fleet_term_hash; kind = Resolve.KTerm });
        ("mk-fleet", { Resolve.hash = fleet_con_hash; kind = Resolve.KCon });
      ]
  in
  let check source expected_hint expected_hash expected_kind =
    let lowered = lower source in
    Alcotest.(check (option string))
      (source ^ " lowering hint") expected_hint
      (Meta.surface_ref_kind lowered.Kernel.meta);
    let resolved =
      match Resolve.resolve_expr names lowered with
      | Ok expression -> expression
      | Error diagnostics -> fail_diags (source ^ " resolution") diagnostics
    in
    match resolved.Kernel.it with
    | Kernel.Ref (actual_hash, actual_kind) ->
        Alcotest.(check bool) (source ^ " hash") true (Hash.equal expected_hash actual_hash);
        Alcotest.(check bool) (source ^ " kind") true (expected_kind = actual_kind)
    | _ -> Alcotest.failf "%s did not resolve to an explicit reference" source
  in
  check "same" None term_hash Kernel.Term;
  check "`term:same`" (Some "term") term_hash Kernel.Term;
  check "`con:same`" (Some "con") con_hash Kernel.Con;
  check "`op:same`" (Some "op") op_hash Kernel.Op;
  check "MkFleet" (Some "con") fleet_con_hash Kernel.Con

let test_d37_namespace_pun_resolves () =
  let names =
    Resolve.of_alist
      [
        ("code", { Resolve.hash = h "code"; kind = Resolve.KTerm });
        ("eval-code", { Resolve.hash = h "eval-code"; kind = Resolve.KOp });
        ("code.un-form", { Resolve.hash = h "code.un-form"; kind = Resolve.KTerm });
      ]
  in
  let lowered = lower "{ let code = eval-code(code); code.un-form(code) }" in
  let resolved =
    match Resolve.resolve_expr names lowered with
    | Ok expression -> expression
    | Error diagnostics -> fail_diags "D37 resolution" diagnostics
  in
  match resolved.Kernel.it with
  | Kernel.Let
      {
        binder = { it = Kernel.PVar "code"; _ };
        value =
          {
            it =
              Kernel.App
                ( { it = Kernel.Ref (eval_hash, Kernel.Op); _ },
                  [ { it = Kernel.Ref (outer_code_hash, Kernel.Term); _ } ] );
            _;
          };
        body =
          {
            it =
              Kernel.App
                ( { it = Kernel.Ref (unform_hash, Kernel.Term); meta = dotted_meta },
                  [ { it = Kernel.Var "code"; _ } ] );
            _;
          };
        _;
      } ->
      Alcotest.(check bool) "eval-code global" true (Hash.equal eval_hash (h "eval-code"));
      Alcotest.(check bool) "outer code global" true (Hash.equal outer_code_hash (h "code"));
      Alcotest.(check bool) "dotted global" true (Hash.equal unform_hash (h "code.un-form"));
      Alcotest.(check (option string))
        "dotted spelling remains atomic" (Some "code.un-form") (Meta.name dotted_meta)
  | _ -> Alcotest.fail "D37 did not preserve the local/root and dotted-global distinction"

let test_bootstrap_reader_unchanged () =
  let source = "(app (var f) (tuple) (lit 1))" in
  let before = bootstrap source |> Kernel.expr_to_form in
  match Reader.parse_one ~file:"still.jqd" source with
  | Ok after ->
      Alcotest.(check bool) ".jqd reader form" true (Form.equal_ignoring_meta before after)
  | Error diagnostics -> fail_diags "bootstrap regression" diagnostics

let suite =
  [
    Alcotest.test_case "atoms" `Quick test_atoms;
    Alcotest.test_case "postfix calls" `Quick test_calls;
    Alcotest.test_case "functions and patterns" `Quick test_functions_and_patterns;
    Alcotest.test_case "grouping and tuples" `Quick test_parentheses_and_tuples;
    Alcotest.test_case "annotations and complete types" `Quick test_annotations_and_complete_types;
    Alcotest.test_case "forall row-variable requirement" `Quick test_forall_row_var_requirement;
    Alcotest.test_case "blocks and local lets" `Quick test_blocks_and_lets;
    Alcotest.test_case "newline and separators" `Quick test_newline_and_separator_rules;
    Alcotest.test_case "block lowering errors" `Quick test_block_lowering_errors;
    Alcotest.test_case "generated spans and provenance" `Quick test_generated_spans_and_provenance;
    Alcotest.test_case "expression recovery" `Quick test_recovery_preserves_later_expression;
    Alcotest.test_case "nested lexical recovery" `Quick test_nested_lexical_recovery;
    Alcotest.test_case "value reference kind survives" `Quick test_value_reference_kind_survives;
    Alcotest.test_case "D37 namespace pun" `Quick test_d37_namespace_pun_resolves;
    Alcotest.test_case "bootstrap reader unchanged" `Quick test_bootstrap_reader_unchanged;
  ]
