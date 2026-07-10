open Jacquard

let fail_diags label diagnostics =
  Alcotest.failf "%s: %s" label (String.concat "; " (List.map Diag.to_string diagnostics))

let parse_expr source =
  match Surface_parse.parse_string ~file:"patterns.jac" source with
  | Ok [ { Surface_ast.it = TopExpr expression; _ } ] -> expression
  | Ok items -> Alcotest.failf "expected one expression, got %d items" (List.length items)
  | Error diagnostics -> fail_diags "surface parse" diagnostics

let lower source =
  match Surface_lower.lower_expr (parse_expr source) with
  | Ok expression -> expression
  | Error diagnostics -> fail_diags "surface lower" diagnostics

let bootstrap source =
  match Reader.parse_one ~file:"patterns.jqd" source with
  | Error diagnostics -> fail_diags "bootstrap parse" diagnostics
  | Ok form -> (
      match Kernel.expr_of_form form with
      | Ok expression -> expression
      | Error diagnostics -> fail_diags "bootstrap validate" diagnostics)

let check_equivalent label surface jqd =
  let actual = Kernel.expr_to_form (lower surface) in
  let expected = Kernel.expr_to_form (bootstrap jqd) in
  Alcotest.(check bool) label true (Form.equal_ignoring_meta expected actual)

let parse_codes source =
  match Surface_parse.parse_string ~file:"bad-patterns.jac" source with
  | Ok _ -> Alcotest.failf "expected %S to fail parsing" source
  | Error diagnostics -> List.map (fun diagnostic -> diagnostic.Diag.code) diagnostics

let lower_codes source =
  match Surface_lower.lower_expr (parse_expr source) with
  | Ok _ -> Alcotest.failf "expected %S to fail lowering" source
  | Error diagnostics -> List.map (fun diagnostic -> diagnostic.Diag.code) diagnostics

let resolve names expression =
  match Resolve.resolve_expr names expression with
  | Ok expression -> expression
  | Error diagnostics -> fail_diags "resolve" diagnostics

let test_all_pattern_forms_and_literals () =
  check_equivalent "six pattern forms and match"
    {|match subject {
  | _ -> 0
  | binding -> binding
  | 1 -> 1
  | Some(value) -> value
  | (only) -> only
  | Pair(left, right) as whole -> whole
}|}
    {|(match (var subject)
  (clause (pwild) (lit 0))
  (clause (pvar binding) (var binding))
  (clause (plit 1) (lit 1))
  (clause (pcon some (pvar value)) (var value))
  (clause (ptuple (pvar only)) (var only))
  (clause (pas whole (pcon pair (pvar left) (pvar right))) (var whole)))|};
  check_equivalent "real and text literal patterns"
    {|match value { | -2.5 -> 1 | "ok" -> 2 | _ -> 3 }|}
    {|(match (var value) (clause (plit -2.5) (lit 1))
        (clause (plit "ok") (lit 2)) (clause (pwild) (lit 3)))|}

let test_d34_escapes_hashes_and_shape () =
  let zeros = String.make 64 '0' in
  check_equivalent "D34 Up versus up" "match value { | Up -> 1 | up -> up }"
    "(match (var value) (clause (pcon up) (lit 1)) (clause (pvar up) (var up)))";
  check_equivalent "escaped and hashed constructors"
    (Printf.sprintf "match value { | `con:a--b`(`term:field--name`) -> 1 | #%s:con -> 2 }" zeros)
    (Printf.sprintf
       "(match (var value) (clause (pcon a--b (pvar field--name)) (lit 1)) (clause (pcon #%s) (lit \
        2)))"
       zeros);
  check_equivalent "unit singleton nested as and five fields"
    "match value { | () -> 0 | (one) -> one | Outer(Inner(x) as inner) as outer -> outer | Five(a, \
     b, c, d, e) -> e }"
    "(match (var value) (clause (ptuple) (lit 0)) (clause (ptuple (pvar one)) (var one)) (clause \
     (pas outer (pcon outer (pas inner (pcon inner (pvar x))))) (var outer)) (clause (pcon five \
     (pvar a) (pvar b) (pvar c) (pvar d) (pvar e)) (var e)))";
  List.iter
    (fun source -> Alcotest.(check bool) source true (List.mem "E1220" (parse_codes source)))
    [
      "match x { | `op:not-a-con` -> 0 | _ -> 1 }";
      Printf.sprintf "match x { | #%s:term -> 0 | _ -> 1 }" zeros;
      "match x { | Some(x) as `con:not-a-binder` -> 0 | _ -> 1 }";
      "match x { | x as first as second -> 0 | _ -> 1 }";
    ]

let test_arm_bodies_and_spans () =
  check_equivalent "unbraced braced nested and multiline arms"
    {|match value {
  | First -> 1
  | Second -> {
      let x = 2
      x
    }
  | Third -> match other {
      | Inner ->
          3
    }
}|}
    {|(match (var value)
  (clause (pcon first) (lit 1))
  (clause (pcon second) (let nonrec (pvar x) (lit 2) (var x)))
  (clause (pcon third) (match (var other) (clause (pcon inner) (lit 3)))))|};
  let source = "match x {\n  | Some(y) as whole -> {\n    y\n  }\n}" in
  match parse_expr source with
  | {
   it =
     Match
       ( _,
         [
           {
             cpattern = { it = PAs ({ it = PCon (_, [ { it = PBind "y"; _ } ]); _ }, "whole"); _ };
             cbody;
             cmeta;
           };
         ] );
   meta;
  } ->
      let span meta = Option.get (Meta.span meta) in
      Alcotest.(check int) "match starts at keyword" 0 (span meta).Span.start_pos.offset;
      Alcotest.(check int)
        "match includes closing brace" (String.length source) (span meta).Span.end_pos.offset;
      Alcotest.(check bool)
        "clause includes body" true
        ((span cmeta).Span.end_pos.offset = (span cbody.meta).Span.end_pos.offset)
  | _ -> Alcotest.fail "unexpected match tree for span test"

let test_contextual_restrictions_and_duplicates () =
  Alcotest.(check (list string)) "refutable lambda" [ "E0205" ] (lower_codes "fn (Some(x)) -> x");
  Alcotest.(check (list string))
    "refutable let" [ "E0206" ]
    (lower_codes "{ let Some(x) = value; x }");
  ignore (lower "match value { | Some(x) -> x | _ -> 0 }");
  let duplicate = lower "match 0 { | (x, x) -> x }" in
  match Resolve.resolve_expr Resolve.empty_names duplicate with
  | Error diagnostics ->
      Alcotest.(check (list string))
        "duplicate remains resolver-owned" [ "E0304" ]
        (List.map (fun diagnostic -> diagnostic.Diag.code) diagnostics)
  | Ok _ -> Alcotest.fail "resolver accepted a duplicate match binder"

let test_resolved_hash_parity () =
  let value_hash = Hash.of_string "surface-pattern-value" in
  let some_hash = Hash.of_string "surface-pattern-some" in
  let none_hash = Hash.of_string "surface-pattern-none" in
  let names =
    Resolve.of_alist
      [
        ("value", { Resolve.hash = value_hash; kind = Resolve.KTerm });
        ("some", { Resolve.hash = some_hash; kind = Resolve.KCon });
        ("none", { Resolve.hash = none_hash; kind = Resolve.KCon });
      ]
  in
  let surface = resolve names (lower "match value { | Some(x) -> x | None -> 0 }") in
  let kernel =
    resolve names
      (bootstrap
         "(match (var value) (clause (pcon some (pvar x)) (var x)) (clause (pcon none) (lit 0)))")
  in
  let hash label expression =
    match Canon.hash_expr expression with
    | Ok hash -> hash
    | Error diagnostics -> fail_diags label diagnostics
  in
  Alcotest.(check bool)
    "resolved surface/bootstrap hash" true
    (Hash.equal (hash "surface hash" surface) (hash "bootstrap hash" kernel))

let later_arm_survives source =
  let recovered = Surface_parse.recover_string ~file:"recover-patterns.jac" source in
  Alcotest.(check bool) (source ^ " reports damage") true (recovered.diagnostics <> []);
  match recovered.items with
  | [ { Surface_ast.it = TopExpr { it = Match (_, clauses); _ }; _ } ] ->
      List.exists
        (function
          | {
              Surface_ast.cpattern = { it = PCon (Named "later", []); _ };
              cbody = { it = Lit (LInt 9); _ };
              _;
            } ->
              true
          | _ -> false)
        clauses
  | _ -> false

let test_ambiguous_nested_recovery () =
  let block = "match x { | Bad -> { 1 | Later -> 9 }" in
  Alcotest.(check bool) "damaged block retains outer Later" true (later_arm_survives block);
  let recovered = Surface_parse.recover_string ~file:"recover-patterns.jac" block in
  Alcotest.(check bool)
    "damaged block reports missing structure" true
    (List.exists (fun diagnostic -> diagnostic.Diag.code = "E1221") recovered.diagnostics);
  let nested = "match x { | Bad -> match y { | Inner -> 1 | Later -> 9 }" in
  Alcotest.(check bool)
    "unterminated nested match retains outer Later" true (later_arm_survives nested);
  match parse_expr "match x { | Bad -> match y { | One -> 1 | Two -> 2 } | Later -> 9 }" with
  | {
   Surface_ast.it =
     Match
       ( _,
         [
           { cbody = { it = Match (_, [ _; _ ]); _ }; _ };
           { cpattern = { it = PCon (Named "later", []); _ }; _ };
         ] );
   _;
  } ->
      ()
  | _ -> Alcotest.fail "valid nested multi-arm match consumed the later outer arm"

let test_missing_match_before_definition () =
  let source = "match x { | Bad -> 1 | Later -> 9\nafter = 4\n" in
  let recovered = Surface_parse.recover_string ~file:"recover-patterns.jac" source in
  Alcotest.(check (list string))
    "ordered diagnostics" [ "E1221" ]
    (List.map (fun diagnostic -> diagnostic.Diag.code) recovered.diagnostics);
  match recovered.items with
  | [
   { it = TopExpr { it = Match (_, clauses); _ }; _ };
   { it = Definition { name = "after"; value = { it = Lit (LInt 4); _ }; _ }; _ };
  ] ->
      Alcotest.(check bool)
        "later arm survives before definition" true
        (List.exists
           (function
             | {
                 Surface_ast.cpattern = { it = PCon (Named "later", []); _ };
                 cbody = { it = Lit (LInt 9); _ };
                 _;
               } ->
                 true
             | _ -> false)
           clauses)
  | _ -> Alcotest.fail "missing match brace consumed the following definition"

let test_match_recovery () =
  List.iter
    (fun source -> Alcotest.(check bool) source true (later_arm_survives source))
    [
      "match x { Broken -> 0 | Later -> 9 }";
      "match x { | | Later -> 9 }";
      "match x { | Broken -> 0 | Later -> 9 | }";
      "match x { | -> 0 | Later -> 9 }";
      "match x { | Broken 0 | Later -> 9 }";
      "match x { | Broken -> | Later -> 9 }";
      "match x { | Broken(x -> 0 | Later -> 9 }";
      "match x { | Broken -> f(x | Later -> 9 }";
      "match x { | Broken -> (1, x | Later -> 9 }";
      "match x { | Broken as Later -> 0 | Later -> 9 }";
      "match x { | Broken -> 0 | Later -> 9";
    ];
  List.iter
    (fun source -> Alcotest.(check bool) source true (List.mem "E1220" (parse_codes source)))
    [ "match x {}"; "match x | Broken -> 0" ]

let suite =
  [
    Alcotest.test_case "forms and literals" `Quick test_all_pattern_forms_and_literals;
    Alcotest.test_case "D34 escapes hashes and shapes" `Quick test_d34_escapes_hashes_and_shape;
    Alcotest.test_case "arm bodies and spans" `Quick test_arm_bodies_and_spans;
    Alcotest.test_case "context restrictions and duplicates" `Quick
      test_contextual_restrictions_and_duplicates;
    Alcotest.test_case "resolved hash parity" `Quick test_resolved_hash_parity;
    Alcotest.test_case "ambiguous nested recovery" `Quick test_ambiguous_nested_recovery;
    Alcotest.test_case "missing match before definition" `Quick test_missing_match_before_definition;
    Alcotest.test_case "match recovery" `Quick test_match_recovery;
  ]
