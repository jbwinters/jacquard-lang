open Jacquard

let recover source = Surface_parse.recover_string ~file:"recover.jac" source

let diagnostic_codes recovered =
  List.map (fun diagnostic -> diagnostic.Diag.code) recovered.Surface_ast.diagnostics

let rendered_diagnostics recovered = List.map Diag.to_string recovered.Surface_ast.diagnostics

let metadata_golden id meta =
  let span = Option.fold ~none:"<missing>" ~some:Span.to_string (Meta.span meta) in
  let surface_form = Option.value ~default:"<missing>" (Meta.surface_form meta) in
  let surface_hole = Option.value ~default:"<missing>" (Meta.surface_hole meta) in
  Printf.sprintf "%d|%s|%s|%s" id span surface_form surface_hole

let test_recovery_golden () =
  let recovered = recover "(\n)\n|\n{\n[\n}\n" in
  Alcotest.(check (list string))
    "all parser diagnostics"
    [
      "recover.jac:3:1-2: error[E1220]: stray `|` at top level";
      "recover.jac:5:1-2: error[E1220]: expected an expression, found [";
    ]
    (rendered_diagnostics recovered);
  match recovered.items with
  | [
   { it = TopExpr { it = Tuple []; _ }; _ };
   { it = TopHole first; meta = first_meta };
   {
     it =
       TopExpr { it = Block [ Expr { it = Hole second; meta = second_meta } ]; meta = block_meta };
     _;
   };
  ] ->
      Alcotest.(check (list string))
        "hole metadata"
        [ "0|recover.jac:3:1-2|recovery-hole|0"; "1|recover.jac:5:1-2|recovery-hole|1" ]
        [ metadata_golden first first_meta; metadata_golden second second_meta ];
      Alcotest.(check (option string))
        "block span" (Some "recover.jac:4:1-6:2")
        (Option.map Span.to_string (Meta.span block_meta))
  | _ -> Alcotest.fail "recovery golden produced an unexpected partial tree"

let test_each_synchronization_boundary () =
  let cases = [ ("newline", "[\nafter\n"); ("semicolon", "[;after\n") ] in
  List.iter
    (fun (label, source) ->
      let recovered = recover source in
      Alcotest.(check (list string))
        (label ^ " diagnostics") [ "E1220" ] (diagnostic_codes recovered);
      match recovered.items with
      | [ { it = TopExpr { it = Hole 0; _ }; _ }; { it = TopExpr { it = Name "after"; _ }; _ } ] ->
          ()
      | _ -> Alcotest.failf "%s: synchronization lost the later item" label)
    cases;
  let closing = recover "{ [ }" in
  Alcotest.(check (list string)) "closing brace diagnostics" [ "E1220" ] (diagnostic_codes closing);
  (match closing.items with
  | [ { it = TopExpr { it = Block [ Expr { it = Hole 0; _ } ]; _ }; _ } ] -> ()
  | _ -> Alcotest.fail "closing-brace synchronization lost the containing block");
  let bar = recover "[\n|\nafter\n" in
  Alcotest.(check (list string)) "bar diagnostics" [ "E1220"; "E1220" ] (diagnostic_codes bar);
  match bar.items with
  | [
   { it = TopExpr { it = Hole 0; _ }; _ };
   { it = TopHole 1; _ };
   { it = TopExpr { it = Name "after"; _ }; _ };
  ] ->
      ()
  | _ -> Alcotest.fail "bar synchronization lost a surrounding item"

let test_later_items_and_errors_survive () =
  let recovered = recover "f(,)\n42\n}\nafter\n" in
  Alcotest.(check (list string))
    "both errors survive" [ "E1220"; "E1220" ] (diagnostic_codes recovered);
  match recovered.items with
  | [
   { it = TopExpr { it = Call ({ it = Name "f"; _ }, [ { it = Hole 0; _ } ]); _ }; _ };
   { it = TopExpr { it = Lit (LInt 42); _ }; _ };
   { it = TopHole 1; _ };
   { it = TopExpr { it = Name "after"; _ }; _ };
  ] ->
      ()
  | _ -> Alcotest.fail "recovery discarded valid items after a malformed expression"

let test_empty_and_malformed_inputs_do_not_raise () =
  let empty = recover "" in
  Alcotest.(check int) "empty items" 0 (List.length empty.items);
  Alcotest.(check int) "empty diagnostics" 0 (List.length empty.diagnostics);
  (match Surface_parse.parse_string ~file:"recover.jac" "" with
  | Ok [] -> ()
  | _ -> Alcotest.fail "strict empty parse should succeed");
  let malformed =
    [
      ("unmatched closing brace", "}", [ "E1220" ]);
      ("unmatched opening brace", "{", [ "E1221" ]);
      ("stray bar", "|", [ "E1220" ]);
      ("truncated string", "\"truncated", [ "E1213" ]);
    ]
  in
  List.iter
    (fun (label, source, expected_codes) ->
      let recovered = recover source in
      Alcotest.(check (list string)) label expected_codes (diagnostic_codes recovered);
      match Surface_parse.parse_string ~file:"recover.jac" source with
      | Error diagnostics ->
          Alcotest.(check (list string))
            (label ^ " strict") expected_codes
            (List.map (fun diagnostic -> diagnostic.Diag.code) diagnostics)
      | Ok _ -> Alcotest.failf "%s: strict parsing accepted malformed input" label)
    malformed

let test_lexical_hole_metadata () =
  let recovered = recover "\"truncated" in
  match recovered.items with
  | [ { it = TopHole id; meta } ] ->
      Alcotest.(check string)
        "lexical hole metadata" "0|recover.jac:1:1-11|recovery-hole|0" (metadata_golden id meta)
  | _ -> Alcotest.fail "truncated string did not produce one top-level recovery hole"

let test_mixed_lexical_and_parser_recovery () =
  let source = "before\n@\n}\nafter\n" in
  let recovered = recover source in
  Alcotest.(check (list string))
    "mixed diagnostics"
    [
      "recover.jac:2:1-2: error[E1210]: unexpected surface character `@`";
      "recover.jac:3:1-2: error[E1220]: unmatched `}` at top level";
    ]
    (rendered_diagnostics recovered);
  (match recovered.items with
  | [
   { it = TopExpr { it = Name "before"; _ }; _ };
   { it = TopHole lexical_id; meta = lexical_meta };
   { it = TopHole parser_id; meta = parser_meta };
   { it = TopExpr { it = Name "after"; _ }; _ };
  ] ->
      Alcotest.(check (list string))
        "mixed hole metadata"
        [ "0|recover.jac:2:1-2|recovery-hole|0"; "1|recover.jac:3:1-2|recovery-hole|1" ]
        [ metadata_golden lexical_id lexical_meta; metadata_golden parser_id parser_meta ]
  | _ -> Alcotest.fail "mixed recovery lost valid surrounding expressions");
  match Surface_parse.parse_string ~file:"recover.jac" source with
  | Error diagnostics ->
      Alcotest.(check (list string))
        "strict mixed diagnostics" [ "E1210"; "E1220" ]
        (List.map (fun diagnostic -> diagnostic.Diag.code) diagnostics)
  | Ok _ -> Alcotest.fail "strict parsing accepted a mixed-damage partial tree"

let test_mixed_lexical_recovery_inside_block () =
  let recovered = recover "{ @\n3 }" in
  Alcotest.(check (list string)) "block lexical diagnostic" [ "E1210" ] (diagnostic_codes recovered);
  (match recovered.items with
  | [
   { it = TopExpr { it = Block [ Expr { it = Hole 0; _ }; Expr { it = Lit (LInt 3); _ } ]; _ }; _ };
  ] ->
      ()
  | _ -> Alcotest.fail "block lexical recovery lost its valid final expression");
  let later_damage = recover "{ @\n[\n3 }" in
  Alcotest.(check (list string))
    "block lexical and parser diagnostics" [ "E1210"; "E1220" ] (diagnostic_codes later_damage);
  match later_damage.items with
  | [
   {
     it =
       TopExpr
         {
           it =
             Block
               [ Expr { it = Hole 0; _ }; Expr { it = Hole 1; _ }; Expr { it = Lit (LInt 3); _ } ];
           _;
         };
     _;
   };
  ] ->
      ()
  | _ -> Alcotest.fail "mixed block recovery lost in-order holes or the final expression"

let test_string_recovery_preserves_surroundings () =
  let truncated = recover "before\n\"truncated\nafter\n" in
  Alcotest.(check (list string)) "truncated code" [ "E1213" ] (diagnostic_codes truncated);
  (match truncated.items with
  | [
   { it = TopExpr { it = Name "before"; _ }; _ };
   { it = TopHole id; meta };
   { it = TopExpr { it = Name "after"; _ }; _ };
  ] ->
      Alcotest.(check string)
        "truncated hole metadata" "0|recover.jac:2:1-11|recovery-hole|0" (metadata_golden id meta)
  | _ -> Alcotest.fail "truncated string recovery lost its surrounding expressions");
  let malformed = recover "before\n\"bad\\q\"\n}\nafter\n" in
  Alcotest.(check (list string))
    "malformed escape and later parser error" [ "E1214"; "E1220" ] (diagnostic_codes malformed);
  match malformed.items with
  | [
   { it = TopExpr { it = Name "before"; _ }; _ };
   { it = TopHole lexical_id; meta = lexical_meta };
   { it = TopHole parser_id; meta = parser_meta };
   { it = TopExpr { it = Name "after"; _ }; _ };
  ] ->
      Alcotest.(check (list string))
        "string recovery hole metadata"
        [ "0|recover.jac:2:5-6|recovery-hole|0"; "1|recover.jac:3:1-2|recovery-hole|1" ]
        [ metadata_golden lexical_id lexical_meta; metadata_golden parser_id parser_meta ]
  | _ -> Alcotest.fail "malformed escape recovery did not reach the later parser error"

let test_nested_unmatched_braces () =
  let recovered = recover "{{" in
  Alcotest.(check (list string))
    "one diagnostic per missing brace" [ "E1221"; "E1221" ] (diagnostic_codes recovered);
  match recovered.items with
  | [
   {
     it =
       TopExpr
         {
           it =
             Block [ Expr { it = Block [ Expr { it = Hole 0; _ } ]; _ }; Expr { it = Hole 1; _ } ];
           _;
         };
     _;
   };
  ] ->
      ()
  | _ -> Alcotest.fail "nested unmatched blocks did not recover recursively"

let suite =
  [
    Alcotest.test_case "diagnostic and hole golden" `Quick test_recovery_golden;
    Alcotest.test_case "all synchronization boundaries" `Quick test_each_synchronization_boundary;
    Alcotest.test_case "later items and errors survive" `Quick test_later_items_and_errors_survive;
    Alcotest.test_case "malformed inputs do not raise" `Quick
      test_empty_and_malformed_inputs_do_not_raise;
    Alcotest.test_case "lexical hole metadata" `Quick test_lexical_hole_metadata;
    Alcotest.test_case "mixed lexical and parser recovery" `Quick
      test_mixed_lexical_and_parser_recovery;
    Alcotest.test_case "mixed lexical recovery inside block" `Quick
      test_mixed_lexical_recovery_inside_block;
    Alcotest.test_case "string recovery preserves surroundings" `Quick
      test_string_recovery_preserves_surroundings;
    Alcotest.test_case "nested unmatched braces" `Quick test_nested_unmatched_braces;
  ]
