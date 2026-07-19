open Jacquard

let nested_form head count leaf =
  let form = ref leaf in
  for _ = 1 to count do
    form := Form.form head [ Form.F !form ]
  done;
  !form

let nested_source ~open_text ~close_text count leaf =
  let length =
    (count * (String.length open_text + String.length close_text)) + String.length leaf
  in
  let buffer = Buffer.create length in
  for _ = 1 to count do
    Buffer.add_string buffer open_text
  done;
  Buffer.add_string buffer leaf;
  for _ = 1 to count do
    Buffer.add_string buffer close_text
  done;
  Buffer.contents buffer

let repeated_suffix prefix suffix count =
  let buffer = Buffer.create (String.length prefix + (count * String.length suffix)) in
  Buffer.add_string buffer prefix;
  for _ = 1 to count do
    Buffer.add_string buffer suffix
  done;
  Buffer.contents buffer

let expect_code label code = function
  | Error diagnostics
    when List.exists
           (fun diagnostic -> String.equal (Diag.code_or_uncoded diagnostic) code)
           diagnostics ->
      ()
  | Error diagnostics ->
      Alcotest.failf "%s: expected %s, got %s" label code
        (String.concat "; " (List.map Diag.to_string diagnostics))
  | Ok _ -> Alcotest.failf "%s: expected %s, got success" label code

let expect_ok label = function
  | Ok _ -> ()
  | Error diagnostics ->
      Alcotest.failf "%s: expected success, got %s" label
        (String.concat "; " (List.map Diag.to_string diagnostics))

let expect_exact_e1227 label diagnostics =
  match diagnostics with
  | [ diagnostic ] ->
      Alcotest.(check string) (label ^ " code") "E1227" (Diag.code_or_uncoded diagnostic);
      Alcotest.(check string)
        (label ^ " wording") "Surface syntax nesting exceeds the limit of 10000."
        (Diag.cause diagnostic)
  | diagnostics ->
      Alcotest.failf "%s: expected exactly one diagnostic, got %s" label
        (String.concat "; " (List.map Diag.to_string diagnostics))

let expect_quarantined_analysis label source =
  let recovered = Surface_parse.recover_string ~file:(label ^ ".jac") (source ^ "\nlater = 42\n") in
  expect_exact_e1227 (label ^ " recovery") recovered.diagnostics;
  (match recovered.items with
  | [
   { Surface_ast.it = Surface_ast.TopHole _; _ };
   { Surface_ast.it = Surface_ast.Definition { name = "later"; _ }; _ };
  ] ->
      ()
  | _ -> Alcotest.failf "%s: over-deep top was not quarantined before recovery" label);
  let store, _ = Eval_support.make_prelude_ctx () in
  let context =
    match Check.make_ctx store with
    | Ok context -> context
    | Error diagnostics ->
        Alcotest.failf "%s: checker context failed: %s" label
          (String.concat "; " (List.map Diag.to_string diagnostics))
  in
  let report = Surface_check.analyze ~names:(Store.names_view store) context recovered in
  expect_exact_e1227 (label ^ " analysis") report.diagnostics;
  Alcotest.(check (list string))
    (label ^ " later recovery") [ "later" ] (List.map fst report.signatures)

let test_kernel_expression_boundary () =
  let leaf = Form.form "lit" [ Form.Int 0 ] in
  let at_limit = nested_form "tuple" (Kernel.max_nesting_depth - 1) leaf in
  let over_limit = nested_form "tuple" Kernel.max_nesting_depth leaf in
  expect_ok "kernel expression at limit" (Kernel.expr_of_form at_limit);
  expect_code "kernel expression over limit" "E0214" (Kernel.expr_of_form over_limit)

let test_kernel_other_recursive_sorts () =
  let pat_leaf = Form.form "pwild" [] in
  let pat = nested_form "ptuple" Kernel.max_nesting_depth pat_leaf in
  expect_code "kernel pattern over limit" "E0214" (Kernel.pat_of_form pat);
  let ty_leaf = Form.form "tref" [ Form.Sym "int" ] in
  let ty = nested_form "ttuple" Kernel.max_nesting_depth ty_leaf in
  expect_code "kernel type over limit" "E0214" (Kernel.ty_of_form ty);
  let payload = nested_form "data" Kernel.max_nesting_depth (Form.form "atom" []) in
  let quote = Form.form "quote" [ Form.F payload ] in
  expect_code "kernel quote payload over limit" "E0214" (Kernel.expr_of_form quote)

let test_reader_boundary () =
  let at_limit =
    nested_source ~open_text:"(tuple " ~close_text:")" (Reader.max_nesting_depth - 1) "(lit 0)"
  in
  let over_limit =
    nested_source ~open_text:"(tuple " ~close_text:")" Reader.max_nesting_depth "(lit 0)"
  in
  expect_ok "reader at limit" (Reader.parse_one ~file:"depth.jqd" at_limit);
  expect_code "reader over limit" "E0115" (Reader.parse_one ~file:"depth.jqd" over_limit)

let test_surface_boundary () =
  let at_limit =
    nested_source ~open_text:"(" ~close_text:")" (Surface_parse.max_nesting_depth - 1) "0"
  in
  let over_limit =
    nested_source ~open_text:"(" ~close_text:")" Surface_parse.max_nesting_depth "0"
  in
  expect_ok "surface expression at limit" (Surface_parse.parse_string ~file:"depth.jac" at_limit);
  expect_code "surface expression over limit" "E1227"
    (Surface_parse.parse_string ~file:"depth.jac" over_limit);
  let postfix_at = repeated_suffix "f" "()" (Surface_parse.max_nesting_depth - 1) in
  let postfix_over = repeated_suffix "f" "()" Surface_parse.max_nesting_depth in
  expect_ok "surface postfix chain at limit"
    (Surface_parse.parse_string ~file:"postfix-depth.jac" postfix_at);
  expect_code "surface postfix chain over limit" "E1227"
    (Surface_parse.parse_string ~file:"postfix-depth.jac" postfix_over);
  expect_quarantined_analysis "postfix-depth-analyze" postfix_over;
  let pipe_at = repeated_suffix "0" " |> f" (Surface_parse.max_nesting_depth - 1) in
  let pipe_over = repeated_suffix "0" " |> f" Surface_parse.max_nesting_depth in
  expect_ok "surface pipe chain at limit"
    (Surface_parse.parse_string ~file:"pipe-depth.jac" pipe_at);
  expect_code "surface pipe chain over limit" "E1227"
    (Surface_parse.parse_string ~file:"pipe-depth.jac" pipe_over);
  expect_quarantined_analysis "pipe-depth-analyze" pipe_over

let test_surface_pattern_and_type_paths () =
  let nested count leaf = nested_source ~open_text:"(" ~close_text:")" count leaf in
  let accepted_pattern =
    Printf.sprintf "fn (%s) -> 0" (nested (Surface_parse.max_nesting_depth - 2) "x")
  in
  let rejected_pattern =
    Printf.sprintf "fn (%s) -> 0" (nested (Surface_parse.max_nesting_depth - 1) "x")
  in
  expect_ok "surface pattern at limit"
    (Surface_parse.parse_string ~file:"pattern-depth.jac" accepted_pattern);
  expect_code "surface pattern over limit" "E1227"
    (Surface_parse.parse_string ~file:"pattern-depth.jac" rejected_pattern);
  let accepted_annotation =
    Printf.sprintf "(x : %s)" (nested (Surface_parse.max_nesting_depth - 2) "Int")
  in
  let rejected_annotation =
    Printf.sprintf "(x : %s)" (nested (Surface_parse.max_nesting_depth - 1) "Int")
  in
  expect_ok "surface type at limit"
    (Surface_parse.parse_string ~file:"type-depth.jac" accepted_annotation);
  expect_code "surface type over limit" "E1227"
    (Surface_parse.parse_string ~file:"type-depth.jac" rejected_annotation)

let kernel_diagnostic source =
  let form =
    match Reader.parse_one ~file:"dedup.jqd" source with
    | Ok form -> form
    | Error diagnostics ->
        Alcotest.failf "DX.7 fixture failed to parse: %s"
          (String.concat "; " (List.map Diag.to_string diagnostics))
  in
  match Kernel.of_form form with
  | Error [ diagnostic ] -> diagnostic
  | Error diagnostics -> Alcotest.failf "expected one diagnostic, got %d" (List.length diagnostics)
  | Ok _ -> Alcotest.fail "expected the DX.7 fixture to fail"

let check_variable_group_diagnostic label ~wrong_form ~message source =
  let diagnostic = kernel_diagnostic source in
  Alcotest.(check string) (label ^ " code") "E0203" (Diag.code_or_uncoded diagnostic);
  Alcotest.(check string) (label ^ " wording") message (Diag.cause diagnostic);
  let expected_start = Str.search_forward (Str.regexp_string wrong_form) source 0 in
  match Diag.span diagnostic with
  | Some span ->
      Alcotest.(check int) (label ^ " span start") expected_start span.Span.start_pos.offset;
      Alcotest.(check int)
        (label ^ " span end")
        (expected_start + String.length wrong_form)
        span.Span.end_pos.offset
  | None -> Alcotest.failf "%s: diagnostic span is missing" label

let capture_entry ?render_diagnostic exception_value =
  let buffer = Buffer.create 128 in
  let formatter = Format.formatter_of_buffer buffer in
  let status =
    Cli_entry.run ~program:"jacquard" ~err:formatter ?render_diagnostic (fun () ->
        raise exception_value)
  in
  Format.pp_print_flush formatter ();
  (status, Buffer.contents buffer)

let test_variable_group_diagnostics_unchanged () =
  check_variable_group_diagnostic "tforall malformed tvar container" ~wrong_form:"(tvar a)"
    ~message:"the type variables in `tforall` must be a parenthesized group"
    "(ann (lit 0) (tforall (tvar a) () (tref int)))";
  check_variable_group_diagnostic "tforall malformed rvar container" ~wrong_form:"(rvar e)"
    ~message:"the row variables in `tforall` must be a parenthesized group"
    "(ann (lit 0) (tforall () (rvar e) (tref int)))";
  check_variable_group_diagnostic "tforall tvar" ~wrong_form:"(rvar a)"
    ~message:"type variables in `tforall` must be `tvar` forms"
    "(ann (lit 0) (tforall ((rvar a)) () (tvar a)))";
  check_variable_group_diagnostic "tforall rvar" ~wrong_form:"(tvar e)"
    ~message:"row variables in `tforall` must be `rvar` forms"
    "(ann (lit 0) (tforall () ((tvar e)) (tref int)))";
  check_variable_group_diagnostic "deftype tvar" ~wrong_form:"(rvar a)"
    ~message:"the type parameters must be `tvar` forms" "(deftype option ((rvar a)) (con none))";
  check_variable_group_diagnostic "defeffect tvar" ~wrong_form:"(rvar a)"
    ~message:"the effect parameters must be `tvar` forms"
    "(defeffect console ((rvar a)) (op print () (tref int)))";
  let stack_status, stack_output = capture_entry Stack_overflow in
  Alcotest.(check int) "entry stack exit" 1 stack_status;
  Alcotest.(check string)
    "entry stack classification"
    "error[E0003]: Input exhausted the host stack before a structural nesting guard\n\
    \  Cause: An unbounded internal traversal reached the host stack limit before Jacquard could \
     report its local depth boundary.\n\
    \  Next step: Reduce the input nesting and report the missing structural guard.\n"
    stack_output;
  let json_status, json_output =
    capture_entry ~render_diagnostic:Diag.to_json_string Stack_overflow
  in
  Alcotest.(check int) "entry JSON stack exit" 1 json_status;
  let json = Yojson.Safe.from_string json_output in
  Alcotest.(check string)
    "entry JSON domain" "process"
    Yojson.Safe.Util.(json |> member "domain" |> to_string);
  Alcotest.(check string)
    "entry JSON code" "E0003"
    Yojson.Safe.Util.(json |> member "code" |> to_string);
  let internal_status, internal_output = capture_entry (Failure "entry-probe") in
  Alcotest.(check int) "entry internal exit" 125 internal_status;
  Alcotest.(check bool)
    "entry internal report" true
    (String.starts_with
       ~prefix:"jacquard: internal error, uncaught exception:\nFailure(\"entry-probe\")"
       internal_output)

let suite =
  [
    Alcotest.test_case "kernel expression boundary" `Quick test_kernel_expression_boundary;
    Alcotest.test_case "kernel recursive sorts" `Quick test_kernel_other_recursive_sorts;
    Alcotest.test_case "bootstrap reader boundary" `Quick test_reader_boundary;
    Alcotest.test_case "surface expression boundary" `Quick test_surface_boundary;
    Alcotest.test_case "surface pattern/type paths" `Quick test_surface_pattern_and_type_paths;
    Alcotest.test_case "DX.7 diagnostics unchanged" `Quick test_variable_group_diagnostics_unchanged;
  ]
