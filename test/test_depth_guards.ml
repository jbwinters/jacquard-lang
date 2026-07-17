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

let expect_code label code = function
  | Error diagnostics
    when List.exists (fun diagnostic -> String.equal diagnostic.Diag.code code) diagnostics ->
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
    (Surface_parse.parse_string ~file:"depth.jac" over_limit)

let test_surface_pattern_and_type_paths () =
  let nested count leaf = nested_source ~open_text:"(" ~close_text:")" count leaf in
  let pattern = Printf.sprintf "fn (%s) -> 0" (nested Surface_parse.max_nesting_depth "x") in
  expect_code "surface pattern over limit" "E1227"
    (Surface_parse.parse_string ~file:"pattern-depth.jac" pattern);
  let annotation = Printf.sprintf "(x : %s)" (nested Surface_parse.max_nesting_depth "Int") in
  expect_code "surface type over limit" "E1227"
    (Surface_parse.parse_string ~file:"type-depth.jac" annotation)

let kernel_message source =
  let form =
    match Reader.parse_one ~file:"dedup.jqd" source with
    | Ok form -> form
    | Error diagnostics ->
        Alcotest.failf "DX.7 fixture failed to parse: %s"
          (String.concat "; " (List.map Diag.to_string diagnostics))
  in
  match Kernel.of_form form with
  | Error [ diagnostic ] -> diagnostic.Diag.message
  | Error diagnostics -> Alcotest.failf "expected one diagnostic, got %d" (List.length diagnostics)
  | Ok _ -> Alcotest.fail "expected the DX.7 fixture to fail"

let test_variable_group_diagnostics_unchanged () =
  Alcotest.(check string)
    "tforall tvar wording" "type variables in `tforall` must be `tvar` forms"
    (kernel_message "(ann (lit 0) (tforall ((rvar a)) () (tvar a)))");
  Alcotest.(check string)
    "tforall rvar wording" "row variables in `tforall` must be `rvar` forms"
    (kernel_message "(ann (lit 0) (tforall () ((tvar e)) (tref int)))");
  Alcotest.(check string)
    "declaration tvar wording" "the type parameters must be `tvar` forms"
    (kernel_message "(deftype option ((rvar a)) (con none))")

let suite =
  [
    Alcotest.test_case "kernel expression boundary" `Quick test_kernel_expression_boundary;
    Alcotest.test_case "kernel recursive sorts" `Quick test_kernel_other_recursive_sorts;
    Alcotest.test_case "bootstrap reader boundary" `Quick test_reader_boundary;
    Alcotest.test_case "surface expression boundary" `Quick test_surface_boundary;
    Alcotest.test_case "surface pattern/type paths" `Quick test_surface_pattern_and_type_paths;
    Alcotest.test_case "DX.7 diagnostics unchanged" `Quick test_variable_group_diagnostics_unchanged;
  ]
