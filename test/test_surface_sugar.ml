open Jacquard

let fail_diags label diagnostics =
  Alcotest.failf "%s: %s" label (String.concat "; " (List.map Diag.to_string diagnostics))

let parse ?(file = "ss12.jac") source =
  match Surface_parse.parse_string ~file source with
  | Ok tops -> tops
  | Error diagnostics -> fail_diags "surface parse" diagnostics

let lower ?file source =
  match Surface_lower.lower_tops (parse ?file source) with
  | Ok tops -> tops
  | Error diagnostics -> fail_diags "surface lower" diagnostics

let lower_expr ?file source =
  match lower ?file source with
  | [ Kernel.Expr expression ] -> expression
  | tops -> Alcotest.failf "expected one expression, got %d tops" (List.length tops)

let bootstrap_expr source =
  match Reader.parse_one ~file:"ss12.jqd" source with
  | Error diagnostics -> fail_diags "bootstrap parse" diagnostics
  | Ok form -> (
      match Kernel.expr_of_form form with
      | Ok expression -> expression
      | Error diagnostics -> fail_diags "bootstrap validate" diagnostics)

let print_file ?(trivia = false) tops =
  let result =
    if trivia then Surface_print.print_file_with_trivia tops else Surface_print.print_file tops
  in
  match result with Ok text -> text | Error diagnostics -> fail_diags "surface print" diagnostics

let contains text fragment =
  let fragment_length = String.length fragment in
  let rec loop offset =
    offset + fragment_length <= String.length text
    && (String.sub text offset fragment_length = fragment || loop (offset + 1))
  in
  fragment_length = 0 || loop 0

let count_occurrences text fragment =
  let fragment_length = String.length fragment in
  let rec loop offset count =
    if offset + fragment_length > String.length text then count
    else if String.sub text offset fragment_length = fragment then
      loop (offset + fragment_length) (count + 1)
    else loop (offset + 1) count
  in
  loop 0 0

let check_expr_equivalent label surface bootstrap =
  let actual = lower_expr surface in
  let expected = bootstrap_expr bootstrap in
  Alcotest.(check bool)
    (label ^ " form") true
    (Form.equal_ignoring_meta (Kernel.expr_to_form expected) (Kernel.expr_to_form actual));
  let free =
    Surface_lower.String_set.union (Surface_lower.free_names actual)
      (Surface_lower.free_names expected)
  in
  let names =
    Surface_lower.String_set.elements free
    |> List.map (fun name ->
        (name, { Resolve.hash = Hash.of_string ("ss12-global:" ^ name); kind = Resolve.KTerm }))
    |> Resolve.of_alist
  in
  let resolve expression =
    match Resolve.resolve_expr names expression with
    | Ok expression -> expression
    | Error diagnostics -> fail_diags (label ^ " resolve") diagnostics
  in
  let hash expression =
    match Canon.hash_expr (resolve expression) with
    | Ok hash -> hash
    | Error diagnostics -> fail_diags (label ^ " hash") diagnostics
  in
  Alcotest.(check bool) (label ^ " hash") true (Hash.equal (hash expected) (hash actual))

let only_binding source =
  match lower source with
  | [ Kernel.Decl { it = DefTerm [ binding ]; _ } ] -> binding
  | _ -> Alcotest.fail "expected one singleton term declaration"

let test_definition_shapes () =
  let value = only_binding "value = 1\n" in
  let annotated_value = only_binding "value : T\nvalue = 1\n" in
  let equation = only_binding "pick((x, y), z as whole) = whole\n" in
  let annotated_equation = only_binding "id : (a) ->{} a\nid(x) = x\n" in
  let authored_fn = only_binding "id = fn (x) -> x\n" in
  Alcotest.(check bool) "plain value" true (match value.value.it with Lit _ -> true | _ -> false);
  Alcotest.(check bool) "annotated value" true (Option.is_some annotated_value.annot);
  Alcotest.(check bool)
    "pattern equation" true
    (match equation.value.it with
    | Lam ([ { it = PTuple [ _; _ ]; _ }; { it = PAs ("whole", _); _ } ], _) -> true
    | _ -> false);
  Alcotest.(check bool) "annotated equation" true (Option.is_some annotated_equation.annot);
  Alcotest.(check (option string))
    "equation provenance" (Some "equation-definition")
    (Meta.surface_form equation.value.meta);
  Alcotest.(check (option string))
    "authored fn provenance" (Some "fn")
    (Meta.surface_form authored_fn.value.meta);
  Alcotest.(check bool)
    "SCC provenance" true
    (match lower "value = 1\n" with
    | [ Kernel.Decl declaration ] -> Meta.surface_form declaration.meta = Some "definition-scc"
    | _ -> false)

let test_local_let_shapes () =
  check_expr_equivalent "ordinary let" "{ let (x, y) = (1, 2); x }"
    "(let nonrec (ptuple (pvar x) (pvar y)) (tuple (lit 1) (lit 2)) (var x))";
  check_expr_equivalent "zero rec params" "{ let rec go() = 1; go() }"
    "(let rec (pvar go) (lam () (lit 1)) (app (var go)))";
  check_expr_equivalent "multiple rec params" "{ let rec go(x, y) = x; go(1, 2) }"
    "(let rec (pvar go) (lam ((pvar x) (pvar y)) (var x)) (app (var go) (lit 1) (lit 2)))";
  check_expr_equivalent "tuple/as rec params" "{ let rec go((x, y) as pair) = pair; go((1, 2)) }"
    "(let rec (pvar go) (lam ((pas pair (ptuple (pvar x) (pvar y)))) (var pair)) (app (var go) \
     (tuple (lit 1) (lit 2))))"

let test_multistep_block_order () =
  check_expr_equivalent "exact nested sequencing" "{ a(); let x = b(); c(x); d() }"
    "(let nonrec (pwild) (app (var a)) (let nonrec (pvar x) (app (var b)) (let nonrec (pwild) (app \
     (var c) (var x)) (app (var d)))))";
  match (lower_expr "{ a(); let x = b(); c(x); d() }").it with
  | Let
      {
        binder = { it = PWild; _ };
        body =
          {
            it =
              Let
                {
                  binder = { it = PVar "x"; _ };
                  body = { it = Let { binder = { it = PWild; _ }; body = { it = App _; _ }; _ }; _ };
                  _;
                };
            _;
          };
        _;
      } ->
      ()
  | _ -> Alcotest.fail "block order/tree changed"

let test_wildcard_spelling () =
  let explicit = print_file (lower "{ let _ = 1; 2 }") in
  let sequence = print_file (lower "{ 1; 2 }") in
  Alcotest.(check bool) "explicit wildcard retained" true (contains explicit "let _ = 1");
  Alcotest.(check bool) "bare sequence retained" false (contains sequence "let _ = 1");
  Alcotest.(check (option string))
    "explicit provenance" (Some "let")
    (Meta.surface_form (lower_expr "{ let _ = 1; 2 }").meta);
  Alcotest.(check (option string))
    "sequence provenance" (Some "block-sequence")
    (Meta.surface_form (lower_expr "{ 1; 2 }").meta)

let diagnostic_codes source =
  match Surface_parse.parse_string ~file:"bad-ss12.jac" source with
  | Ok _ -> []
  | Error diagnostics -> List.map (fun diagnostic -> diagnostic.Diag.code) diagnostics

let diagnostic_strings source =
  match Surface_parse.parse_string ~file:"bad-ss12.jac" source with
  | Ok _ -> []
  | Error diagnostics -> List.map Diag.to_string diagnostics

let lowering_codes source =
  match Surface_lower.lower_tops (parse source) with
  | Ok _ -> []
  | Error diagnostics -> List.map (fun diagnostic -> diagnostic.Diag.code) diagnostics

let test_block_edges_and_diagnostics () =
  Alcotest.(check bool)
    "singleton block" true
    (match (lower_expr "{ 1 }").it with Lit (LInt 1) -> true | _ -> false);
  Alcotest.(check (list string)) "empty block" [ "E1231" ] (lowering_codes "{}");
  Alcotest.(check (list string)) "final let" [ "E1232" ] (lowering_codes "{ let x = 1 }");
  Alcotest.(check (list string))
    "missing rec params" [ "E1233" ]
    (diagnostic_codes "{ let rec go = 1; go }");
  Alcotest.(check (list string))
    "missing rec params text"
    [
      "bad-ss12.jac:1:14-15: error[E1233]: `let rec` requires a lowercase name followed by a \
       parameter list";
    ]
    (diagnostic_strings "{ let rec go = 1; go }");
  Alcotest.(check (list string))
    "bad rec binder" [ "E1233" ]
    (lowering_codes "{ let rec (f, g)(x) = x; f }")

let resolved_hash top =
  let resolved =
    match Resolve.resolve Resolve.empty_names top with
    | Ok top -> top
    | Error diagnostics -> fail_diags "resolve inversion fixture" diagnostics
  in
  match Canon.hash_top resolved with
  | Ok hashes -> hashes.Canon.decl_hash
  | Error diagnostics -> fail_diags "hash inversion fixture" diagnostics

let test_print_parse_lower_inversion () =
  let fixtures =
    [
      "value = fn (x) -> x\n";
      "equation((x, y) as pair) = pair\n";
      "{ let x = 1; x }\n";
      "{ let rec go() = 0; go() }\n";
      "{ 1; 2 }\n";
      "{ let _ = 1; 2 }\n";
    ]
  in
  List.iter
    (fun source ->
      let before = lower source in
      let printed = print_file before in
      let after = lower printed in
      Alcotest.(check int) "roundtrip top count" (List.length before) (List.length after);
      List.iter2
        (fun before after ->
          Alcotest.(check bool)
            ("Form inversion: " ^ source) true
            (Form.equal_ignoring_meta (Kernel.to_form before) (Kernel.to_form after));
          Alcotest.(check bool)
            ("hash inversion: " ^ source) true
            (Hash.equal (resolved_hash before) (resolved_hash after)))
        before after)
    fixtures;
  let value_fn = print_file (lower "value = fn (x) -> x\n") in
  let equation = print_file (lower "equation(x) = x\n") in
  Alcotest.(check bool) "value fn remains value syntax" true (contains value_fn "= fn (");
  Alcotest.(check bool) "equation remains equation syntax" true (contains equation "equation(x) =")

let source_slice source meta =
  match Meta.span meta with
  | None -> Alcotest.fail "missing SS.12 source span"
  | Some span ->
      String.sub source span.Span.start_pos.offset (span.end_pos.offset - span.start_pos.offset)

let test_spans_provenance_and_trivia () =
  let source = "{\n  let rec go((x, y) as pair) = pair\n  go((1, 2))\n}" in
  let recursive = lower_expr ~file:"spans.jac" source in
  (match recursive.it with
  | Let { binder; value = { it = Lam (_, body); meta = lambda_meta }; _ } ->
      Alcotest.(check string)
        "full let span" "let rec go((x, y) as pair) = pair\n  go((1, 2))"
        (source_slice source recursive.meta);
      Alcotest.(check string)
        "lambda construct span" "go((x, y) as pair) = pair" (source_slice source lambda_meta);
      Alcotest.(check (option string))
        "let rec provenance" (Some "let-rec")
        (Meta.surface_form recursive.meta);
      Alcotest.(check (option string))
        "lambda provenance" (Some "let-rec-fn") (Meta.surface_form lambda_meta);
      Alcotest.(check bool) "binder span" true (Option.is_some (Meta.span binder.meta));
      Alcotest.(check bool) "body span" true (Option.is_some (Meta.span body.meta))
  | _ -> Alcotest.fail "recursive span fixture changed shape");
  let equation_source = "pair(x, y) = (x, y)\n" in
  let equation = only_binding equation_source in
  Alcotest.(check string)
    "equation lambda span" "pair(x, y) = (x, y)"
    (source_slice equation_source equation.value.meta);
  let trivia_source =
    "-- block-leading\n{\n  -- item-leading\n  1\n  -- final-leading\n  2\n  -- block-inner\n}\n"
  in
  let recovered = Surface_parse.recover_string ~file:"trivia-ss12.jac" trivia_source in
  let file =
    match Surface_parse.strict_file recovered with
    | Ok file -> file
    | Error diagnostics -> fail_diags "strict trivia" diagnostics
  in
  let lowered =
    match Surface_lower.lower_file file with
    | Ok file -> file
    | Error diagnostics -> fail_diags "lower trivia" diagnostics
  in
  let printed = Surface_print.print_file_with_trivia ~file_meta:lowered.meta lowered.tops in
  let printed =
    match printed with
    | Ok text -> text
    | Error diagnostics -> fail_diags "print trivia" diagnostics
  in
  List.iter
    (fun comment -> Alcotest.(check int) comment 1 (count_occurrences printed comment))
    [ "-- block-leading"; "-- item-leading"; "-- final-leading"; "-- block-inner" ];
  match lowered.tops with
  | [ Kernel.Expr expression ] ->
      let container = Meta.surface_container "block" expression.meta in
      Alcotest.(check bool)
        "container comment not moved" true
        (List.mem "-- block-inner" (Meta.comment_texts Meta.key_trivia_inner container))
  | _ -> Alcotest.fail "trivia fixture changed top shape"

let term_group_names = function
  | Kernel.Decl { it = DefTerm bindings; _ } ->
      List.map (fun binding -> binding.Kernel.bname) bindings
  | _ -> Alcotest.fail "expected term group"

let test_top_boundaries_and_dependencies () =
  let tops = lower "a = b\n10\nb = 1\n20\nc = d\nd = 2\n" in
  (match tops with
  | [ first; Kernel.Expr _; third; Kernel.Expr _; fifth; sixth ] ->
      Alcotest.(check (list string)) "first run isolated" [ "a" ] (term_group_names first);
      Alcotest.(check (list string)) "second run isolated" [ "b" ] (term_group_names third);
      Alcotest.(check (list string))
        "dependency first after boundary" [ "d" ] (term_group_names fifth);
      Alcotest.(check (list string)) "dependent second" [ "c" ] (term_group_names sixth)
  | _ -> Alcotest.fail "top expressions were folded or ceased to be hard run boundaries");
  let groups = lower "consumer((target, x) as pair) = pair\ntarget = 1\n" in
  Alcotest.(check (list (list string)))
    "tuple/as parameters shadow top names" [ [ "consumer" ]; [ "target" ] ]
    (List.map term_group_names groups);
  let local = lower_expr "{ let rec walk((target, x) as pair) = walk(pair); walk((1, 2)) }" in
  Alcotest.(check (list string))
    "local recursive and parameter shadowing" []
    (Surface_lower.String_set.elements (Surface_lower.free_names local))

let raw_error_code source =
  match Reader.parse_one ~file:"bad-rec.jqd" source with
  | Error diagnostics -> fail_diags "raw rec parse" diagnostics
  | Ok form -> (
      match Kernel.expr_of_form form with
      | Ok _ -> Alcotest.fail "invalid raw recursive let validated"
      | Error [ diagnostic ] -> diagnostic.Diag.code
      | Error diagnostics -> fail_diags "raw rec validation" diagnostics)

let test_raw_rec_validation_and_printer () =
  Alcotest.(check string)
    "raw rec binder" "E0207"
    (raw_error_code "(let rec (ptuple (pvar f)) (lam () (lit 1)) (var f))");
  Alcotest.(check string)
    "raw rec value" "E0208"
    (raw_error_code "(let rec (pvar f) (lit 1) (var f))");
  let kernel = bootstrap_expr "(let rec (pvar f) (lam ((pvar x)) (var x)) (app (var f) (lit 1)))" in
  let printed = print_file [ Kernel.Expr kernel ] in
  Alcotest.(check bool)
    "recursive kernel let uses accepted syntax" true
    (contains printed "let rec f(x) = x");
  let reparsed = lower_expr printed in
  Alcotest.(check bool)
    "recursive kernel fallback inversion" true
    (Form.equal_ignoring_meta (Kernel.expr_to_form kernel) (Kernel.expr_to_form reparsed))

let suite =
  [
    Alcotest.test_case "definition shapes" `Quick test_definition_shapes;
    Alcotest.test_case "local let shapes" `Quick test_local_let_shapes;
    Alcotest.test_case "multi-step block order" `Quick test_multistep_block_order;
    Alcotest.test_case "wildcard spelling" `Quick test_wildcard_spelling;
    Alcotest.test_case "block edges and diagnostics" `Quick test_block_edges_and_diagnostics;
    Alcotest.test_case "print parse lower inversion" `Quick test_print_parse_lower_inversion;
    Alcotest.test_case "spans provenance and trivia" `Quick test_spans_provenance_and_trivia;
    Alcotest.test_case "top boundaries and dependencies" `Quick test_top_boundaries_and_dependencies;
    Alcotest.test_case "raw rec validation and printer" `Quick test_raw_rec_validation_and_printer;
  ]
