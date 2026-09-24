open Jacquard

(* SX.29 (D77): `try` block items elaborate to an ordinary two-armed Result match. The CLI
   behaviour (interpreter, native, hashes, formatter, diagnostics) is pinned by
   test/cli/surface-try.t; these cases pin the parse and lowering contract. *)

let fail_diags label diagnostics =
  Alcotest.failf "%s: %s" label (String.concat "; " (List.map Diag.to_string diagnostics))

let parse_expr source =
  match Surface_parse.parse_string ~file:"try.jac" source with
  | Ok [ { Surface_ast.it = TopExpr expression; _ } ] -> expression
  | Ok items -> Alcotest.failf "expected one expression, got %d items" (List.length items)
  | Error diagnostics -> fail_diags "surface parse" diagnostics

let lower source =
  match Surface_lower.lower_expr (parse_expr source) with
  | Ok expression -> expression
  | Error diagnostics -> fail_diags "surface lower" diagnostics

let form source = Kernel.expr_to_form (lower source)
let same label a b = Alcotest.(check bool) label true (Form.equal_ignoring_meta (form a) (form b))

let codes source =
  match Surface_parse.parse_string ~file:"try.jac" source with
  | Error diagnostics -> List.map Diag.code_or_uncoded diagnostics
  | Ok [ { Surface_ast.it = TopExpr expression; _ } ] -> (
      match Surface_lower.lower_expr expression with
      | Ok _ -> []
      | Error diagnostics -> List.map Diag.code_or_uncoded diagnostics)
  | Ok _ -> []

let test_binding_twin () =
  same "let x = try" "{\n  let x = try f(1)\n  Ok(g(x))\n}"
    "match f(1) {\n  | Ok(x) -> Ok(g(x))\n  | Err(error) -> Err(error)\n}"

let test_bare_twin () =
  same "bare try discards the payload" "{\n  try check(1)\n  Ok(2)\n}"
    "match check(1) {\n  | Ok(_) -> Ok(2)\n  | Err(error) -> Err(error)\n}"

let test_nested_steps_left_to_right () =
  same "each step nests the rest of the block in its Ok arm"
    "{\n  let a = try f(1)\n  let b = try g(a)\n  h(a, b)\n  Ok(b)\n}"
    "match f(1) {\n\
    \  | Ok(a) -> match g(a) {\n\
    \    | Ok(b) -> { h(a, b)\n\
    \  Ok(b) }\n\
    \    | Err(error) -> Err(error)\n\
    \  }\n\
    \  | Err(error) -> Err(error)\n\
     }"

let test_scope_is_the_innermost_block () =
  same "a try in a nested block ends only that block"
    "{\n  let r = {\n    let x = try f(1)\n    Ok(x)\n  }\n  Ok(r)\n}"
    "{\n\
    \  let r = match f(1) {\n\
    \    | Ok(x) -> Ok(x)\n\
    \    | Err(error) -> Err(error)\n\
    \  }\n\
    \  Ok(r)\n\
     }"

let test_refusals () =
  Alcotest.(check (list string)) "expression position" [ "E1242" ] (codes "f(try x)");
  Alcotest.(check (list string)) "tail position" [ "E1243" ] (codes "{\n  try f(1)\n}");
  Alcotest.(check bool)
    "let rec" true
    (List.mem "E1244" (codes "{\n  let rec h(y) = try f(y)\n  h(1)\n}"));
  Alcotest.(check (list string))
    "refutable binder" [ "E0206" ]
    (codes "{\n  let Some(x) = try f(1)\n  Ok(x)\n}")

let printed expression =
  match Surface_print.print_top (Kernel.Expr expression) with
  | Ok text -> text
  | Error diagnostics -> fail_diags "print" diagnostics

let contains ~sub text =
  let n = String.length sub in
  let rec go i = i + n <= String.length text && (String.sub text i n = sub || go (i + 1)) in
  go 0

let test_printer_round_trip () =
  let source = "{\n  let x = try f(1)\n  try g(x)\n  Ok(x)\n}" in
  let text = printed (lower source) in
  Alcotest.(check bool) "binding spelling kept" true (contains ~sub:"let x = try f(1)" text);
  Alcotest.(check bool) "bare spelling kept" true (contains ~sub:"try g(x)" text);
  same "reparsed print is the same program" source text

(* a tag alone must not re-sugar a match that is not the exact expansion *)
let test_printer_refuses_lookalikes () =
  (* tag the root and both clauses as the lowering would, so only the node-level checks decide *)
  let retag source =
    let expression = lower source in
    let it =
      match expression.Kernel.it with
      | Kernel.Match (subject, [ ok; err ]) ->
          Kernel.Match
            ( subject,
              [
                { ok with cmeta = Meta.with_surface_form "try-ok-clause" ok.Kernel.cmeta };
                { err with cmeta = Meta.with_surface_form "try-err-clause" err.Kernel.cmeta };
              ] )
      | it -> it
    in
    { Kernel.it; meta = Meta.with_surface_form "try" expression.Kernel.meta }
  in
  List.iter
    (fun (label, source) ->
      Alcotest.(check bool) label false (contains ~sub:"try" (printed (retag source))))
    [
      ("different Err arm", "match Err(1) {\n  | Ok(x) -> Ok(x)\n  | Err(e) -> Ok(42)\n}");
      ("different constructor", "match r {\n  | Some(x) -> Ok(x)\n  | Err(e) -> Err(e)\n}");
      ("hand-written expansion", "match f(1) {\n  | Ok(x) -> Ok(x)\n  | Err(error) -> Err(error)\n}");
      ("a term named err", "match Err(1) {\n  | Ok(x) -> Ok(x)\n  | Err(e) -> err(e)\n}");
      ("refutable payload", "match Ok(Box(1)) {\n  | Ok(Box(x)) -> Ok(x)\n  | Err(e) -> Err(e)\n}");
    ]

let suite =
  [
    Alcotest.test_case "let x = try e elaborates to a Result match" `Quick test_binding_twin;
    Alcotest.test_case "bare try discards the Ok payload" `Quick test_bare_twin;
    Alcotest.test_case "steps nest left to right" `Quick test_nested_steps_left_to_right;
    Alcotest.test_case "an Err ends the innermost block" `Quick test_scope_is_the_innermost_block;
    Alcotest.test_case "misplaced try is refused" `Quick test_refusals;
    Alcotest.test_case "the formatter keeps the try spelling" `Quick test_printer_round_trip;
    Alcotest.test_case "only the exact expansion prints as try" `Quick
      test_printer_refuses_lookalikes;
  ]
