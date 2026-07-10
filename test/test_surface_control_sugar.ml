open Jacquard

let fail_diags label diagnostics =
  Alcotest.failf "%s: %s" label (String.concat "; " (List.map Diag.to_string diagnostics))

let parse ?(file = "ss13.jac") source =
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

let bootstrap source =
  match Reader.parse_one ~file:"ss13.jqd" source with
  | Error diagnostics -> fail_diags "bootstrap parse" diagnostics
  | Ok form -> (
      match Kernel.expr_of_form form with
      | Ok expression -> expression
      | Error diagnostics -> fail_diags "bootstrap validate" diagnostics)

let print ?width ?(trivia = false) tops =
  let result =
    if trivia then Surface_print.print_file_with_trivia ?width tops
    else Surface_print.print_file ?width tops
  in
  match result with Ok text -> text | Error diagnostics -> fail_diags "surface print" diagnostics

let hash_of label expression =
  match Canon.hash_expr expression with
  | Ok hash -> hash
  | Error diagnostics -> fail_diags label diagnostics

let true_hash = Hash.of_string "ss13:true"
let false_hash = Hash.of_string "ss13:false"
let cons_hash = Hash.of_string "ss13:cons"
let nil_hash = Hash.of_string "ss13:nil"

let names =
  Resolve.of_alist
    [
      ("true", { Resolve.hash = true_hash; kind = Resolve.KCon });
      ("false", { Resolve.hash = false_hash; kind = Resolve.KCon });
      ("cons", { Resolve.hash = cons_hash; kind = Resolve.KCon });
      ("nil", { Resolve.hash = nil_hash; kind = Resolve.KCon });
      ("c", { Resolve.hash = Hash.of_string "ss13:c"; kind = Resolve.KTerm });
      ("c1", { Resolve.hash = Hash.of_string "ss13:c1"; kind = Resolve.KTerm });
      ("c2", { Resolve.hash = Hash.of_string "ss13:c2"; kind = Resolve.KTerm });
      ("c3", { Resolve.hash = Hash.of_string "ss13:c3"; kind = Resolve.KTerm });
      ("x", { Resolve.hash = Hash.of_string "ss13:x"; kind = Resolve.KTerm });
      ("a", { Resolve.hash = Hash.of_string "ss13:a"; kind = Resolve.KTerm });
      ("b", { Resolve.hash = Hash.of_string "ss13:b"; kind = Resolve.KTerm });
      ("f", { Resolve.hash = Hash.of_string "ss13:f"; kind = Resolve.KTerm });
      ("g", { Resolve.hash = Hash.of_string "ss13:g"; kind = Resolve.KTerm });
      ("h", { Resolve.hash = Hash.of_string "ss13:h"; kind = Resolve.KTerm });
    ]

let resolve_with resolver label expression =
  match Resolve.resolve_expr resolver expression with
  | Ok expression -> expression
  | Error diagnostics -> fail_diags label diagnostics

let check_twin label surface_source bootstrap_source =
  let surface = lower_expr surface_source in
  let kernel = bootstrap bootstrap_source in
  Alcotest.(check bool)
    (label ^ " exact form") true
    (Form.equal_ignoring_meta (Kernel.expr_to_form kernel) (Kernel.expr_to_form surface));
  let surface = resolve_with names (label ^ " surface resolve") surface in
  let kernel = resolve_with names (label ^ " bootstrap resolve") kernel in
  Alcotest.(check bool)
    (label ^ " canonical hash") true
    (Hash.equal
       (hash_of (label ^ " surface hash") surface)
       (hash_of (label ^ " kernel hash") kernel))

let test_if_exact_and_nested () =
  check_twin "if" "if c then a else b"
    "(match (var c) (clause (pcon true) (var a)) (clause (pcon false) (var b)))";
  check_twin "nested if" "if c1 then if c2 then a else b else x"
    "(match (var c1) (clause (pcon true) (match (var c2) (clause (pcon true) (var a)) (clause \
     (pcon false) (var b)))) (clause (pcon false) (var x)))";
  match (lower_expr "if c then a else b").it with
  | Match
      ( _,
        [
          { cpat = { it = PCon (Named "true", []); _ }; _ };
          { cpat = { it = PCon (Named "false", []); _ }; _ };
        ] ) ->
      ()
  | _ -> Alcotest.fail "if did not retain named True/False constructor intent"

let test_flat_else_if_printing () =
  let source = "if c1 then a else if c2 then b else if c3 then x else a" in
  let printed = print ~width:24 (lower source) in
  let else_lines =
    String.split_on_char '\n' printed
    |> List.filter (fun line -> String.starts_with ~prefix:"else" line)
  in
  Alcotest.(check int) "three flat continuations" 3 (List.length else_lines);
  Alcotest.(check bool)
    "no nested continuation indent" true
    (List.for_all (fun line -> String.starts_with ~prefix:"else" line) else_lines);
  Alcotest.(check string) "flat chain textual idempotence" printed (print ~width:24 (lower printed))

let test_list_shapes_and_hashes () =
  List.iter
    (fun (label, surface, twin) -> check_twin label surface twin)
    [
      ("empty list", "[]", "(var nil)");
      ("single list", "[a]", "(app (var cons) (var a) (var nil))");
      ( "non-empty list",
        "[a, b, x]",
        "(app (var cons) (var a) (app (var cons) (var b) (app (var cons) (var x) (var nil))))" );
      ( "nested lists",
        "[[a], [], [b, x]]",
        "(app (var cons) (app (var cons) (var a) (var nil)) (app (var cons) (var nil) (app (var \
         cons) (app (var cons) (var b) (app (var cons) (var x) (var nil))) (var nil))))" );
    ];
  match (lower_expr "[a]").it with
  | App ({ it = Var "cons"; meta = cons_meta }, [ _; { it = Var "nil"; meta = nil_meta } ]) ->
      Alcotest.(check (option string)) "Cons intent" (Some "con") (Meta.surface_ref_kind cons_meta);
      Alcotest.(check (option string)) "Nil intent" (Some "con") (Meta.surface_ref_kind nil_meta)
  | _ -> Alcotest.fail "list did not lower to unresolved Cons/Nil applications"

let test_pipe_shapes_and_hashes () =
  check_twin "bare pipe" "x |> f" "(app (var f) (var x))";
  check_twin "pipe call" "x |> f(a, b)" "(app (var f) (var x) (var a) (var b))";
  check_twin "pipe associativity" "x |> f(a) |> g(b)"
    "(app (var g) (app (var f) (var x) (var a)) (var b))";
  Alcotest.(check string)
    "ordinary pipe chain stays flat" "x |> f(a) |> g(b)\n"
    (print (lower "x |> f(a) |> g(b)"));
  check_twin "continued pipe" "x\n-- before pipe\n|>\n-- after pipe\nf(a)"
    "(app (var f) (var x) (var a))";
  (match parse "x\nafter = 7\n" with
  | [ { Surface_ast.it = TopExpr { it = Name "x"; _ }; _ }; { it = Definition _; _ } ] -> ()
  | _ -> Alcotest.fail "pipe lookahead swallowed a newline without a pipe");
  match (lower_expr "x |> f(a) |> g(b)").it with
  | App (_, [ { it = App (_, [ { it = Ref _ | Var "x"; _ }; _ ]); _ }; _ ]) -> ()
  | _ -> Alcotest.fail "pipe was not lowered left-associatively"

let test_pipe_rhs_source_call_distinction () =
  let cases =
    [
      ( "bare App-producing list",
        "x |> [f]",
        "(app (app (var cons) (var f) (var nil)) (var x))",
        "x |> [f]\n" );
      ( "bare App-producing block",
        "x |> { f(a) }",
        "(app (app (var f) (var a)) (var x))",
        "x |> {\n       f(a)}\n" );
      ("bare name", "x |> f", "(app (var f) (var x))", "x |> f\n");
      ("explicit empty call", "x |> f()", "(app (var f) (var x))", "x |> f()\n");
      ("nested postfix call", "x |> f()(a)", "(app (app (var f)) (var x) (var a))", "x |> f()(a)\n");
    ]
  in
  List.iter
    (fun (label, source, twin, expected_print) ->
      check_twin label source twin;
      let before = lower_expr source in
      let rendered = print [ Kernel.Expr before ] in
      Alcotest.(check string) (label ^ " exact print") expected_print rendered;
      let after = lower_expr rendered in
      Alcotest.(check bool)
        (label ^ " print Form round trip")
        true
        (Form.equal_ignoring_meta (Kernel.expr_to_form before) (Kernel.expr_to_form after));
      let before = resolve_with names (label ^ " before print resolve") before in
      let after = resolve_with names (label ^ " after print resolve") after in
      Alcotest.(check bool)
        (label ^ " print hash round trip")
        true
        (Hash.equal
           (hash_of (label ^ " before print hash") before)
           (hash_of (label ^ " after print hash") after)))
    cases;
  let quoted = lower_expr "quote { x |> [f] }" in
  let expected =
    bootstrap
      "(quote (app (app (surface-ref-v0 con cons) (var f) (surface-ref-v0 con nil)) (var x)))"
  in
  Alcotest.(check bool)
    "quoted bare list exact form" true
    (Form.equal_ignoring_meta (Kernel.expr_to_form expected) (Kernel.expr_to_form quoted));
  Alcotest.(check bool)
    "quoted bare list canonical hash" true
    (Hash.equal (hash_of "quoted expected hash" expected) (hash_of "quoted actual hash" quoted));
  Alcotest.(check string)
    "quoted bare list exact print round trip" "quote { x |> [f] }\n" (print [ Kernel.Expr quoted ])

let test_if_precedence_printing () =
  let cases =
    [
      ("pipe left", "(if c then f else g) |> h", "(if c then f else g) |> h\n");
      ("bare pipe RHS", "x |> if c then f else g", "x |> (if c then f else g)\n");
      ("explicit pipe RHS call head", "x |> (if c then f else g)()", "x |> (if c then f else g)()\n");
      ("nested pipe left", "(x |> if c then f else g) |> h", "(x |> (if c then f else g)) |> h\n");
      ("ordinary call head", "(if c then f else g)()", "(if c then f else g)()\n");
    ]
  in
  let check_round_trip label source expected =
    let before = lower_expr source in
    let rendered = print [ Kernel.Expr before ] in
    Alcotest.(check string) (label ^ " exact print") expected rendered;
    List.iter
      (fun (width_label, rendered) ->
        let after = lower_expr rendered in
        Alcotest.(check bool)
          (label ^ " " ^ width_label ^ " Form round trip")
          true
          (Form.equal_ignoring_meta (Kernel.expr_to_form before) (Kernel.expr_to_form after));
        let before = resolve_with names (label ^ " before print resolve") before in
        let after = resolve_with names (label ^ " after print resolve") after in
        Alcotest.(check bool)
          (label ^ " " ^ width_label ^ " hash round trip")
          true
          (Hash.equal
             (hash_of (label ^ " before print hash") before)
             (hash_of (label ^ " after print hash") after)))
      [ ("default width", rendered); ("narrow width", print ~width:18 [ Kernel.Expr before ]) ]
  in
  List.iter
    (fun (label, source, expected) ->
      check_round_trip label source expected;
      check_round_trip ("quoted " ^ label)
        ("quote { " ^ source ^ " }")
        ("quote { " ^ String.trim expected ^ " }\n"))
    cases

let test_noncallable_pipe_reaches_checker () =
  let expression = lower_expr "1 |> 2" in
  (match expression.it with
  | Kernel.App ({ it = Lit (LInt 2); _ }, [ { it = Lit (LInt 1); _ } ]) -> ()
  | _ -> Alcotest.fail "primary pipe RHS did not lower as an ordinary application");
  let store, _ = Eval_support.make_prelude_ctx () in
  let context =
    match Check.make_ctx store with
    | Ok context -> context
    | Error diagnostics -> fail_diags "checker context" diagnostics
  in
  match Check.check_top context (Kernel.Expr expression) with
  | Error [ diagnostic ] ->
      Alcotest.(check string) "normal not-callable diagnostic" "E0802" diagnostic.code
  | Error diagnostics -> fail_diags "non-callable pipe checker" diagnostics
  | Ok _ -> Alcotest.fail "calling an integer unexpectedly type checked"

let diagnostic_codes diagnostics = List.map (fun diagnostic -> diagnostic.Diag.code) diagnostics

let test_resolution_diagnostics () =
  let check source resolver expected_names =
    match Resolve.resolve_expr resolver (lower_expr source) with
    | Ok _ -> Alcotest.failf "%s unexpectedly resolved" source
    | Error diagnostics ->
        Alcotest.(check (list string))
          (source ^ " codes")
          (List.map (fun _ -> "E0301") expected_names)
          (diagnostic_codes diagnostics);
        let rendered = String.concat "\n" (List.map Diag.to_string diagnostics) in
        List.iter
          (fun name ->
            Alcotest.(check bool)
              ("mentions " ^ name) true
              (String.contains rendered '`'
              && String.split_on_char '`' rendered |> List.exists (String.equal name)))
          expected_names
  in
  check "[]" Resolve.empty_names [ "nil" ];
  check "[1]" Resolve.empty_names [ "cons"; "nil" ];
  check "[1]"
    (Resolve.of_alist [ ("nil", { Resolve.hash = nil_hash; kind = Resolve.KCon }) ])
    [ "cons" ];
  let terms =
    [
      ("c", { Resolve.hash = Hash.of_string "missing-bool:c"; kind = Resolve.KTerm });
      ("a", { Resolve.hash = Hash.of_string "missing-bool:a"; kind = Resolve.KTerm });
      ("b", { Resolve.hash = Hash.of_string "missing-bool:b"; kind = Resolve.KTerm });
    ]
  in
  check "if c then a else b" (Resolve.of_alist terms) [ "true"; "false" ];
  check "if c then a else b"
    (Resolve.of_alist (("true", { Resolve.hash = true_hash; kind = Resolve.KCon }) :: terms))
    [ "false" ]

let test_print_parse_lower_inversion () =
  let fixtures =
    [
      "if c then a else b";
      "if c1 then a else if c2 then b else if c3 then x else a";
      "[]";
      "[a]";
      "[[a, b], [], [x]]";
      "x |> f";
      "x |> f(a) |> g(b)";
      "if c then [a] else x |> f(b)";
      "quote { if c then a else b }";
      "quote { [a] }";
      "quote { x |> f }";
    ]
  in
  List.iter
    (fun source ->
      let before = lower_expr source in
      let rendered = print [ Kernel.Expr before ] in
      let after = lower_expr rendered in
      Alcotest.(check bool)
        (source ^ " form inversion") true
        (Form.equal_ignoring_meta (Kernel.expr_to_form before) (Kernel.expr_to_form after));
      let before = resolve_with names "before inversion resolve" before in
      let after = resolve_with names "after inversion resolve" after in
      Alcotest.(check bool)
        (source ^ " hash inversion") true
        (Hash.equal (hash_of "before inversion hash" before) (hash_of "after inversion hash" after)))
    fixtures

let source_slice source meta =
  match Meta.span meta with
  | None -> Alcotest.fail "missing SS.13 span"
  | Some span ->
      String.sub source span.Span.start_pos.offset (span.end_pos.offset - span.start_pos.offset)

let count text needle =
  let rec loop offset found =
    if offset + String.length needle > String.length text then found
    else if String.sub text offset (String.length needle) = needle then
      loop (offset + String.length needle) (found + 1)
    else loop (offset + 1) found
  in
  loop 0 0

let test_spans_trivia_and_provenance () =
  List.iter
    (fun source ->
      let expression = lower_expr ~file:"spans-ss13.jac" source in
      Alcotest.(check string) (source ^ " span") source (source_slice source expression.meta);
      Alcotest.(check bool)
        (source ^ " provenance") true
        (Option.is_some (Meta.surface_form expression.meta)))
    [ "if c then a else b"; "[a, [b]]"; "x |> f(a) |> g(b)" ];
  let source =
    "if c -- before-then\n\
     then -- after-then\n\
    \  [a,\n\
    \    -- nested\n\
    \    [b]\n\
    \    -- list-inner\n\
    \  ] -- before-else\n\
     else -- after-else\n\
    \  x -- before-pipe\n\
    \  |> -- after-pipe\n\
    \  f(\n\
    \    -- arg\n\
    \    a\n\
    \  )\n"
  in
  let recovered = Surface_parse.recover_string ~file:"trivia-ss13.jac" source in
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
  let rendered =
    match Surface_print.print_file_with_trivia ~file_meta:lowered.meta lowered.tops with
    | Ok text -> text
    | Error diagnostics -> fail_diags "print trivia" diagnostics
  in
  List.iter
    (fun comment -> Alcotest.(check int) comment 1 (count rendered comment))
    [
      "-- before-then";
      "-- after-then";
      "-- nested";
      "-- list-inner";
      "-- before-else";
      "-- after-else";
      "-- before-pipe";
      "-- after-pipe";
      "-- arg";
    ];
  let reparsed = Surface_parse.recover_string ~file:"trivia-ss13.jac" rendered in
  let reparsed =
    match Surface_parse.strict_file reparsed with
    | Ok file -> file
    | Error diagnostics -> fail_diags "reparse trivia" diagnostics
  in
  let relowered =
    match Surface_lower.lower_file reparsed with
    | Ok file -> file
    | Error diagnostics -> fail_diags "relower trivia" diagnostics
  in
  let rerendered =
    match Surface_print.print_file_with_trivia ~file_meta:relowered.meta relowered.tops with
    | Ok text -> text
    | Error diagnostics -> fail_diags "reprint trivia" diagnostics
  in
  Alcotest.(check string) "trivia-aware idempotence" rendered rerendered

let comments key meta = Meta.comment_texts key meta

let test_list_container_ownership () =
  let source =
    "[ -- outer-open\n\
    \  [ -- inner-open\n\
    \    a -- item-trailing\n\
    \    -- inner-close\n\
    \  ] -- nested-trailing\n\
    \  -- outer-close\n\
     ]\n"
  in
  let recovered = Surface_parse.recover_string ~file:"list-owners.jac" source in
  let file =
    match Surface_parse.strict_file recovered with
    | Ok file -> file
    | Error diagnostics -> fail_diags "list owner parse" diagnostics
  in
  match file.tops with
  | [ { Surface_ast.it = TopExpr { it = List [ nested ]; meta = outer_meta }; _ } ] -> (
      match nested.it with
      | List [ item ] ->
          let outer = Meta.surface_container "list" outer_meta in
          let inner = Meta.surface_container "list" nested.meta in
          Alcotest.(check (list string))
            "outer opening belongs to nested list container" [ "-- outer-open" ]
            (comments Meta.key_trivia inner);
          Alcotest.(check (list string))
            "inner opening belongs to first item" [ "-- inner-open" ]
            (comments Meta.key_trivia item.meta);
          Alcotest.(check (list string))
            "item same-line comment" [ "-- item-trailing" ]
            (comments Meta.key_trivia_trailing item.meta);
          Alcotest.(check (list string))
            "nested closing bracket container" [ "-- inner-close" ]
            (comments Meta.key_trivia_inner inner);
          Alcotest.(check (list string))
            "nested closing same-line container" [ "-- nested-trailing" ]
            (comments Meta.key_trivia_trailing inner);
          Alcotest.(check (list string))
            "outer closing bracket container" [ "-- outer-close" ]
            (comments Meta.key_trivia_inner outer)
      | _ -> Alcotest.fail "nested list owner fixture changed shape")
  | _ -> Alcotest.fail "list owner fixture changed top-level shape"

let test_malformed_and_recovery () =
  let source = "[1,]\nif c a else b\nif c then a b\nafter = 7\n" in
  let recovered = Surface_parse.recover_string ~file:"bad-ss13.jac" source in
  Alcotest.(check (list string))
    "exact malformed diagnostics"
    [
      "bad-ss13.jac:1:4-5: error[E1220]: list literals do not permit a trailing comma";
      "bad-ss13.jac:2:6-7: error[E1220]: expected `then` after the condition, found ident(a)";
      "bad-ss13.jac:3:13-14: error[E1220]: expected `else` after the then branch, found ident(b)";
    ]
    (List.map Diag.to_string recovered.diagnostics);
  (match List.rev recovered.items with
  | { Surface_ast.it = Definition { name = "after"; _ }; _ } :: _ -> ()
  | _ -> Alcotest.fail "malformed sugars lost the later top");
  let missing = Surface_parse.recover_string ~file:"missing-list.jac" "[1" in
  Alcotest.(check (list string))
    "missing bracket exact diagnostic"
    [ "missing-list.jac:1:3-3: error[E1220]: expected `,` or `]`, found eof" ]
    (List.map Diag.to_string missing.diagnostics)

let test_top_level_recovery_boundaries () =
  let list_source = "[1\nafter = 7\n" in
  let list_recovered = Surface_parse.recover_string ~file:"list-boundary.jac" list_source in
  Alcotest.(check (list string))
    "list boundary diagnostic"
    [ "list-boundary.jac:2:1-6: error[E1220]: expected `,` or `]` before the next top-level item" ]
    (List.map Diag.to_string list_recovered.diagnostics);
  (match list_recovered.items with
  | [
   { Surface_ast.it = TopExpr { it = List [ { it = Lit (LInt 1); _ }; { it = Hole 0; _ } ]; _ }; _ };
   { it = Definition { name = "after"; value = { it = Lit (LInt 7); _ }; _ }; _ };
  ] ->
      ()
  | _ -> Alcotest.fail "unterminated top-level list consumed the following definition");
  let if_source = "if c then a\nafter = 7\n" in
  let if_recovered = Surface_parse.recover_string ~file:"if-boundary.jac" if_source in
  Alcotest.(check (list string))
    "if boundary diagnostic"
    [
      "if-boundary.jac:2:1-6: error[E1220]: expected `else` after the then branch before the next \
       top-level item";
    ]
    (List.map Diag.to_string if_recovered.diagnostics);
  match if_recovered.items with
  | [
   {
     Surface_ast.it =
       TopExpr
         {
           it = If ({ it = Name "c"; _ }, { it = Name "a"; _ }, { it = Hole 0; meta = hole_meta });
           _;
         };
     _;
   };
   { it = Definition { name = "after"; value = { it = Lit (LInt 7); _ }; _ }; _ };
  ] ->
      Alcotest.(check (option string))
        "if recovery hole span" (Some "if-boundary.jac:1:12-2:1")
        (Option.map Span.to_string (Meta.span hole_meta))
  | _ -> Alcotest.fail "incomplete top-level if consumed the following definition"

let test_nested_recovery_boundaries () =
  List.iter
    (fun source -> ignore (parse ~file:"nested-valid.jac" source))
    [
      "{\n[1,\n2]\nif c\nthen a\nelse b\n}";
      "f([1,\n2], if c\nthen a\nelse b)";
      "match c { | x -> if c\nthen [a,\nb]\nelse [] }";
      "([1,\n2], if c\nthen a\nelse b)";
    ];
  let cases =
    [
      ( "nested-list-call.jac",
        "f([1\n)\nafter = 7\n",
        "nested-list-call.jac:2:1-2: error[E1220]: expected `,` or `]`, found )" );
      ( "nested-if-call.jac",
        "f(if c then a\n)\nafter = 7\n",
        "nested-if-call.jac:2:1-2: error[E1220]: expected `else` after the then branch, found )" );
      ( "nested-list-block.jac",
        "{\n[1\n}\nafter = 7\n",
        "nested-list-block.jac:3:1-2: error[E1220]: expected `,` or `]`, found }" );
    ]
  in
  List.iter
    (fun (file, source, expected_diagnostic) ->
      let recovered = Surface_parse.recover_string ~file source in
      Alcotest.(check (list string))
        (file ^ " diagnostic") [ expected_diagnostic ]
        (List.map Diag.to_string recovered.diagnostics);
      match List.rev recovered.items with
      | { Surface_ast.it = Definition { name = "after"; _ }; _ } :: _ -> ()
      | _ -> Alcotest.failf "%s: malformed nested form escaped its containing delimiter" file)
    cases

let quote_payload source =
  match (lower_expr source).it with
  | Kernel.Quote payload -> payload
  | _ -> Alcotest.fail "expected a quote expression"

let parse_form source =
  match Reader.parse_one ~file:"ss13-quote.jqd" source with
  | Ok form -> form
  | Error diagnostics -> fail_diags "quoted expected form" diagnostics

let test_quoted_list_provenance_and_identity () =
  List.iter
    (fun source ->
      Alcotest.(check string) (source ^ " round trip") (source ^ "\n") (print (lower source)))
    [ "quote { [a] }"; "quote { [[a], []] }"; "quote { if c then a else b }"; "quote { x |> f }" ];
  let same_term = Hash.of_string "ss13-collision-term" in
  let same_con = Hash.of_string "ss13-collision-con" in
  let xs_hash = Hash.of_string "ss13-xs" in
  let collision_names =
    Resolve.of_alist
      [
        ("same", { Resolve.hash = same_term; kind = Resolve.KTerm });
        ("same", { Resolve.hash = same_con; kind = Resolve.KCon });
        ("cons", { Resolve.hash = Hash.of_string "ss13-cons-term"; kind = Resolve.KTerm });
        ("cons", { Resolve.hash = cons_hash; kind = Resolve.KCon });
        ("nil", { Resolve.hash = Hash.of_string "ss13-nil-term"; kind = Resolve.KTerm });
        ("nil", { Resolve.hash = nil_hash; kind = Resolve.KCon });
        ("xs", { Resolve.hash = xs_hash; kind = Resolve.KTerm });
      ]
  in
  let quoted = lower_expr "quote { [[Same], unquote(xs)] }" in
  Alcotest.(check string)
    "nested quoted list canonical spelling" "quote { [[Same], unquote(xs)] }\n"
    (print [ Kernel.Expr quoted ]);
  let resolved = resolve_with collision_names "quoted collision resolve" quoted in
  let actual = match resolved.it with Kernel.Quote payload -> payload | _ -> assert false in
  let expected =
    parse_form
      (Printf.sprintf
         "(app (surface-ref-v0 con cons) (app (surface-ref-v0 con cons) (surface-ref-v0 con same) \
          (surface-ref-v0 con nil)) (app (surface-ref-v0 con cons) (unquote (ref #%s term)) \
          (surface-ref-v0 con nil)))"
         (Hash.to_hex xs_hash))
  in
  Alcotest.(check bool)
    "quote payload identity and live unquote resolution" true
    (Form.equal_ignoring_meta expected actual);
  match (resolve_with collision_names "ordinary list collision" (lower_expr "[Same]")).it with
  | Kernel.App
      ( { it = Ref (_, Kernel.Con); _ },
        [ { it = Ref (hash, Kernel.Con); _ }; { it = Ref (_, Kernel.Con); _ } ] ) ->
      Alcotest.(check bool) "ordinary constructor identity" true (Hash.equal same_con hash)
  | _ -> Alcotest.fail "ordinary list constructors did not resolve by constructor intent"

let test_raw_bootstrap_and_metadata_identity () =
  let raw_if =
    bootstrap "(match (var c) (clause (pcon true) (var a)) (clause (pcon false) (var b)))"
  in
  let raw_list = bootstrap "(app (var cons) (var a) (var nil))" in
  let raw_pipe = bootstrap "(app (var f) (var x) (var a))" in
  let rendered = print [ Expr raw_if; Expr raw_list; Expr raw_pipe ] in
  Alcotest.(check bool) "raw match remains match" true (String.starts_with ~prefix:"match" rendered);
  Alcotest.(check bool) "raw list remains Cons call" true (count rendered "cons(" = 1);
  Alcotest.(check int) "raw list does not gain bracket sugar" 0 (count rendered "[a]");
  Alcotest.(check bool) "raw app remains call" true (count rendered "f(x, a)" = 1);
  let sugared = resolve_with names "sugared resolve" (lower_expr "if c then [a] else x |> f(b)") in
  let twin =
    resolve_with names "twin resolve"
      (bootstrap
         "(match (var c) (clause (pcon true) (app (var cons) (var a) (var nil))) (clause (pcon \
          false) (app (var f) (var x) (var b))))")
  in
  Alcotest.(check bool)
    "metadata erasure identity" true
    (Hash.equal (hash_of "sugared" sugared) (hash_of "twin" twin))

let suite =
  [
    Alcotest.test_case "if exact and nested" `Quick test_if_exact_and_nested;
    Alcotest.test_case "flat else-if printing" `Quick test_flat_else_if_printing;
    Alcotest.test_case "list shapes and hashes" `Quick test_list_shapes_and_hashes;
    Alcotest.test_case "pipe shapes and hashes" `Quick test_pipe_shapes_and_hashes;
    Alcotest.test_case "pipe RHS source call distinction" `Quick
      test_pipe_rhs_source_call_distinction;
    Alcotest.test_case "if precedence printing" `Quick test_if_precedence_printing;
    Alcotest.test_case "non-callable pipe reaches checker" `Quick
      test_noncallable_pipe_reaches_checker;
    Alcotest.test_case "resolution diagnostics" `Quick test_resolution_diagnostics;
    Alcotest.test_case "print parse lower inversion" `Quick test_print_parse_lower_inversion;
    Alcotest.test_case "spans trivia and provenance" `Quick test_spans_trivia_and_provenance;
    Alcotest.test_case "list container ownership" `Quick test_list_container_ownership;
    Alcotest.test_case "malformed and recovery" `Quick test_malformed_and_recovery;
    Alcotest.test_case "top-level recovery boundaries" `Quick test_top_level_recovery_boundaries;
    Alcotest.test_case "nested recovery boundaries" `Quick test_nested_recovery_boundaries;
    Alcotest.test_case "quoted list provenance and identity" `Quick
      test_quoted_list_provenance_and_identity;
    Alcotest.test_case "raw bootstrap and metadata identity" `Quick
      test_raw_bootstrap_and_metadata_identity;
  ]
