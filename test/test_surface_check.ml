open Jacquard

let fail_diags label diagnostics =
  Alcotest.failf "%s: %s" label (String.concat "; " (List.map Diag.to_string diagnostics))

let make () =
  let store, _ = Eval_support.make_prelude_ctx () in
  let context =
    match Check.make_ctx store with
    | Error diagnostics -> fail_diags "checker context" diagnostics
    | Ok context ->
        (match Prelude.builtin_signatures store with
        | Error diagnostics -> fail_diags "builtin signatures" diagnostics
        | Ok signatures -> Check.register_builtin_signatures context signatures);
        context
  in
  (store, context)

let analyze ?names ?(file = "surface-check.jac") source =
  let store, context = make () in
  let names = Option.value ~default:(Store.names_view store) names in
  Surface_check.analyze ~names context (Surface_parse.recover_string ~file source)

let analyze_with ?(file = "surface-check.jac") ~names context source =
  Surface_check.analyze ~names context (Surface_parse.recover_string ~file source)

let codes report =
  List.map (fun diagnostic -> diagnostic.Diag.code) report.Surface_check.diagnostics

let diagnostics code report =
  List.filter (fun diagnostic -> diagnostic.Diag.code = code) report.Surface_check.diagnostics

let contains needle text =
  let rec loop index =
    index + String.length needle <= String.length text
    && (String.sub text index (String.length needle) = needle || loop (index + 1))
  in
  loop 0

let signature_names report = List.map fst report.Surface_check.signatures

let diagnostic_golden diagnostic =
  let severity =
    match diagnostic.Diag.severity with Error -> "error" | Warning -> "warning" | Info -> "info"
  in
  Printf.sprintf "%s|%s|%s|%s|%s" severity diagnostic.code
    (Option.fold ~none:"<none>" ~some:Span.to_string diagnostic.span)
    diagnostic.message
    (Option.value ~default:"<none>" diagnostic.hint)

let report_golden report = List.map diagnostic_golden report.Surface_check.diagnostics

let test_hole_kinds_and_independent_islands () =
  let cases =
    [
      ( "expression",
        "broken = @\nlater = 42\n",
        [ "error|E1210|expression.jac:1:10-11|unexpected surface character `@`|<none>" ] );
      ( "pattern",
        "broken = match True { | @ -> 0 | _ -> 1 }\nlater = 42\n",
        [ "error|E1210|pattern.jac:1:25-26|unexpected surface character `@`|<none>" ] );
      ( "type",
        "broken : @\nbroken = 1\nlater = 42\n",
        [
          "error|E1210|type.jac:1:10-11|unexpected surface character `@`|<none>";
          "error|E1220|type.jac:1:10-11|expected a type, found invalid(E1210)|<none>";
        ] );
      ( "top",
        "@\nlater = 42\n",
        [ "error|E1210|top.jac:1:1-2|unexpected surface character `@`|<none>" ] );
      ( "nested",
        "broken = [1, if @ then 2 else 3]\nlater = 42\n",
        [ "error|E1210|nested.jac:1:17-18|unexpected surface character `@`|<none>" ] );
      ( "structural",
        "broken = match True {}\nlater = 42\n",
        [
          "error|E0209|structural.jac:1:10-23|`match` requires at least one clause|<none>";
          "error|E1220|structural.jac:1:22-23|a `match` requires at least one arm|<none>";
        ] );
      ( "row-missing-tail",
        "broken : () ->{|} Int\nbroken() = 1\nlater = 42\n",
        [
          "error|E1220|row-missing-tail.jac:1:17-18|expected a lowercase row variable after \
           `|`|<none>";
        ] );
      ( "row-trailing-comma",
        "broken : () ->{Net,} Int\nbroken() = 1\nlater = 42\n",
        [
          "error|E1220|row-trailing-comma.jac:1:20-21|effect rows do not permit a trailing \
           comma|<none>";
        ] );
    ]
  in
  List.iter
    (fun (label, source, expected) ->
      let report = analyze ~file:(label ^ ".jac") source in
      Alcotest.(check (list string))
        (label ^ " exact bounded cascade")
        expected (report_golden report);
      Alcotest.(check bool)
        (label ^ " preserves later definition")
        true
        (List.mem "later" (signature_names report)))
    cases

let test_malformed_row_checks_as_any_row () =
  let report =
    analyze ~file:"row-any.jac"
      "takes : (() ->{Net,} Int) ->{} Int\ntakes(thunk) = 1\nquiet() = 1\ntakes(quiet)\n"
  in
  Alcotest.(check (list string))
    "only the primary malformed-row diagnostic"
    [ "error|E1220|row-any.jac:1:20-21|effect rows do not permit a trailing comma|<none>" ]
    (report_golden report);
  Alcotest.(check (list string))
    "surrounding declarations still check" [ "takes"; "quiet"; "_" ] (signature_names report)

let test_primary_plus_later_type_error () =
  let report = analyze ~file:"bounded.jac" "broken = @\nif 1 then 2 else 3\ngood = 42\n" in
  Alcotest.(check (list string))
    "exact primary plus independent follow-on"
    [
      "error|E1210|bounded.jac:1:10-11|unexpected surface character `@`|<none>";
      "error|E0801|bounded.jac:2:4-5|if condition: expected int, got bool (type mismatch)|the \
       expected side comes from the surrounding context; make both sides agree";
    ]
    (report_golden report);
  Alcotest.(check bool) "later good island checked" true (List.mem "good" (signature_names report))

let one_error code source =
  let report = analyze ~file:"wording.jac" source in
  match diagnostics code report with
  | [ diagnostic ] -> diagnostic
  | found ->
      Alcotest.failf "expected one %s diagnostic, got %d: %s" code (List.length found)
        (String.concat "; " (List.map Diag.to_string report.diagnostics))

let test_surface_wording_and_spans () =
  let cases =
    [
      ( "if",
        "if 1 then 2 else 3\n",
        "error|E0801|wording.jac:1:4-5|if condition: expected int, got bool (type mismatch)|the \
         expected side comes from the surrounding context; make both sides agree" );
      ( "list",
        "[1, \"x\"]\n",
        "error|E0801|wording.jac:1:1-9|list elements: expected list int, got list text (type \
         mismatch)|the expected side comes from the surrounding context; make both sides agree" );
      ( "pipe",
        "1 |> 2\n",
        "error|E0802|wording.jac:1:6-7|the `|>` right-hand side has type int, which is not a \
         function|the right-hand side of `|>` must be callable" );
      ( "equation",
        "identity : (Int) ->{} Text\nidentity(value) = value\n",
        "error|E0804|wording.jac:2:1-24|equation definition `identity` does not match its \
         signature: expected (int) ->{} text, got (int) ->{} int (type mismatch)|<none>" );
    ]
  in
  List.iter
    (fun (label, source, expected) ->
      Alcotest.(check (list string))
        label [ expected ]
        (report_golden (analyze ~file:"wording.jac" source)))
    cases

let test_eta_guidance_matrix () =
  let positive_source = "condition = True\nbool.and-then(True, condition)\n" in
  let positive = one_error "E0807" positive_source in
  Alcotest.(check bool) "targeted wording" true (contains "wrap it in `fn () ->" positive.message);
  Alcotest.(check (option string))
    "bare reference span" (Some "wording.jac:2:21-30")
    (Option.map Span.to_string positive.span);
  let thunked = analyze "bool.and-then(True, fn () -> bool.not(True))\n" in
  Alcotest.(check bool) "already thunked does not fire" false (List.mem "E0807" (codes thunked));
  let arbitrary = analyze "bool.and(True, bool.not)\n" in
  Alcotest.(check bool) "ordinary mismatch stays ordinary" true (List.mem "E0801" (codes arbitrary));
  Alcotest.(check bool) "ordinary mismatch has no eta" false (List.mem "E0807" (codes arbitrary));
  let wrong_function = analyze "bool.and-then(True, bool.not)\n" in
  Alcotest.(check bool)
    "wrong function type stays ordinary" true
    (List.mem "E0801" (codes wrong_function));
  Alcotest.(check bool)
    "wrong function type has no eta" false
    (List.mem "E0807" (codes wrong_function));
  let function_result_thunk =
    analyze "takes : (() ->{} ((Bool) ->{} Bool)) ->{} Bool\ntakes(thunk) = True\ntakes(bool.not)\n"
  in
  Alcotest.(check (list string))
    "function in function-result thunk position stays ordinary" [ "E0801" ]
    (codes function_result_thunk);
  let value_result_thunk =
    analyze
      "takes : (() ->{} Bool) ->{} Bool\ntakes(thunk) = True\ncondition = True\ntakes(condition)\n"
  in
  Alcotest.(check (list string))
    "value in value-result thunk position gets eta guidance" [ "E0807" ] (codes value_result_thunk);
  let arity = analyze "bool.and-then(True)\n" in
  Alcotest.(check bool) "arity mismatch stays arity" true (List.mem "E0803" (codes arity));
  Alcotest.(check bool) "arity mismatch has no eta" false (List.mem "E0807" (codes arity))

let test_eta_exact_positive_and_negatives () =
  let positive =
    analyze ~file:"eta-positive.jac" "condition = True\nbool.and-then(True, condition)\n"
  in
  Alcotest.(check (list string))
    "positive golden"
    [
      "error|E0807|eta-positive.jac:2:21-30|this position expects a thunk, but `condition` is a \
       bare reference; wrap it in `fn () -> ...`|wrap the reference in `fn () -> ...` so the \
       computation is delayed";
    ]
    (report_golden positive);
  let store, context = make () in
  let names = Store.names_view store in
  let term_hash =
    match Store.lookup_kind store "bool.not" Resolve.KTerm with
    | Some entry -> Hash.to_hex entry.Resolve.hash
    | None -> Alcotest.fail "bool.not term missing"
  in
  let op_name =
    match Store.lookup_kind store "print" Resolve.KOp with
    | Some _ -> "print"
    | None -> Alcotest.fail "prelude print operation missing"
  in
  let cases =
    [
      ("constructor", "bool.and-then(True, True)\n", "E0801");
      ("escaped constructor", "bool.and-then(True, `con:true`)\n", "E0801");
      ("operation", Printf.sprintf "bool.and-then(True, `op:%s`)\n" op_name, "E0801");
      ("local", "{ let condition = True; bool.and-then(True, condition) }\n", "E0801");
      ("explicit hash", Printf.sprintf "bool.and-then(True, #%s:term)\n" term_hash, "E0801");
      ("call", "bool.and-then(True, bool.not(True))\n", "E0801");
      ("wrong function", "bool.and-then(True, bool.not)\n", "E0801");
      ("already thunked", "bool.and-then(True, fn () -> bool.not(True))\n", "<none>");
      ("wrong arity", "bool.and-then(True)\n", "E0803");
      ("wrong result", "number = 1\nbool.and-then(True, number)\n", "E0801");
    ]
  in
  List.iter
    (fun (label, source, expected) ->
      let report = analyze_with ~file:(label ^ ".jac") ~names context source in
      Alcotest.(check (list string))
        (label ^ " exact codes")
        (if expected = "<none>" then [] else [ expected ])
        (codes report);
      Alcotest.(check bool) (label ^ " has no eta advice") false (List.mem "E0807" (codes report)))
    cases;
  let row_mismatch =
    analyze_with ~file:"zero-row.jac" ~names context
      "noisy : () ->{Console} Bool\n\
       noisy() = True\n\
       takes : (() ->{} Bool) ->{} Bool\n\
       takes(thunk) = thunk()\n\
       takes(noisy)\n"
  in
  Alcotest.(check (list string)) "zero-arg row mismatch code" [ "E0801" ] (codes row_mismatch);
  Alcotest.(check bool)
    "zero-arg row mismatch has no eta" false
    (List.mem "E0807" (codes row_mismatch));
  let effectful_expected =
    analyze_with ~file:"effectful-eta.jac" ~names context
      "condition = True\n\
       takes : (() ->{Console} Bool) ->{} Bool\n\
       takes(thunk) = True\n\
       takes(condition)\n"
  in
  Alcotest.(check (list string))
    "effectful expected thunk diagnostic"
    [
      "error|E0807|effectful-eta.jac:4:7-16|this position expects a thunk, but `condition` is a \
       bare reference; wrap it in `fn () -> ...`|wrap the reference in `fn () -> ...` so the \
       computation is delayed";
    ]
    (report_golden effectful_expected);
  let repaired =
    analyze_with ~file:"effectful-eta-repaired.jac" ~names context
      "condition = True\n\
       takes : (() ->{Console} Bool) ->{} Bool\n\
       takes(thunk) = True\n\
       takes(fn () -> condition)\n"
  in
  Alcotest.(check (list string)) "effectful eta repair checks" [] (codes repaired)

let test_raw_jqd_eta_stability () =
  let store, context = make () in
  let source = "(app (var bool.and-then) (var true) (var true))" in
  let result =
    match Reader.parse_one ~file:"eta.jqd" source with
    | Error diagnostics -> Error diagnostics
    | Ok form -> (
        match Kernel.expr_of_form form with
        | Error diagnostics -> Error diagnostics
        | Ok expression -> (
            match Resolve.resolve_expr (Store.names_view store) expression with
            | Error diagnostics -> Error diagnostics
            | Ok expression -> Check.check_top context (Kernel.Expr expression)))
  in
  match result with
  | Error [ diagnostic ] -> Alcotest.(check string) "raw code unchanged" "E0801" diagnostic.code
  | Error diagnostics -> fail_diags "raw eta check" diagnostics
  | Ok _ -> Alcotest.fail "raw eta mismatch unexpectedly checked"

let test_case_confusion_scope_and_namespace () =
  let con_names =
    Resolve.of_alist
      [ ("up", { Resolve.hash = Hash.of_string "up-constructor"; kind = Resolve.KCon }) ]
  in
  let term_names =
    Resolve.of_alist [ ("up", { Resolve.hash = Hash.of_string "up-term"; kind = Resolve.KTerm }) ]
  in
  let warning_count names source = List.length (diagnostics "W1201" (analyze ~names source)) in
  Alcotest.(check int)
    "constructor collision" 1
    (warning_count con_names "match 1 { | up -> up }\n");
  Alcotest.(check int)
    "term namespace is unrelated" 0
    (warning_count term_names "match 1 { | up -> up }\n");
  Alcotest.(check int)
    "unrelated binder" 0
    (warning_count con_names "match 1 { | other -> other }\n");
  Alcotest.(check int)
    "explicit term namespace suppresses" 0
    (warning_count con_names "match 1 { | `term:up` -> `term:up` }\n");
  let lexical = analyze "type Direction = | Up\nmatch 1 { | up -> up }\n" in
  Alcotest.(check int)
    "earlier surface constructor is in scope" 1
    (List.length (diagnostics "W1201" lexical));
  let before = analyze "match 1 { | up -> up }\ntype Direction = | Up\n" in
  Alcotest.(check int)
    "later constructor is not in scope" 0
    (List.length (diagnostics "W1201" before));
  Alcotest.(check int)
    "escaped constructor is a constructor pattern" 0
    (warning_count con_names "match 1 { | `con:up` -> 0 | _ -> 1 }\n")

let test_wide_pattern_boundary_and_coexistence () =
  let wide = analyze "match 1 { | Five(a, b, c, d, e) -> 0 | _ -> 1 }\n" in
  (match diagnostics "W1202" wide with
  | [ warning ] ->
      Alcotest.(check bool) "wide is warning" true (warning.severity = Diag.Warning);
      Alcotest.(check bool)
        "bounded guidance" true
        (Option.fold ~none:false
           ~some:(fun hint ->
             contains "D36" hint
             && contains "labeled constructor patterns unavailable" hint
             && contains "four fields or fewer" hint)
           warning.hint)
  | found -> Alcotest.failf "expected one wide warning, got %d" (List.length found));
  let boundary = analyze "match 1 { | Four(a, b, c, d) -> 0 | _ -> 1 }\n" in
  Alcotest.(check int) "four is allowed" 0 (List.length (diagnostics "W1202" boundary));
  let both = analyze "match 1 { | Five(a, b, c, d, e) -> 0 | _ -> 1 }\n1 |> 2\n" in
  Alcotest.(check bool)
    "warning survives errors" true
    (List.mem "W1202" (codes both)
    && List.exists (fun d -> d.Diag.severity = Diag.Error) both.diagnostics)

let test_warning_exact_order_nested_raw_and_redundancy () =
  let source =
    "match True { | _ -> 0 | _ -> 1 }\n\
     match True { | Missing(Five(a, b, c, d, e)) -> 0 | _ -> 1 }\n\
     1 |> 2\n"
  in
  let report = analyze ~file:"warnings.jac" source in
  Alcotest.(check (list string))
    "warning/error source order"
    [ "W0801"; "E0301"; "W1202"; "E0802" ]
    (codes report);
  let rendered = report_golden report in
  Alcotest.(check (list string))
    "exact warning/error golden"
    [
      "warning|W0801|warnings.jac:1:23-31|this clause is redundant: earlier clauses match \
       everything it does|<none>";
      "error|E0301|warnings.jac:2:16-44|unknown constructor `missing`|<none>";
      "warning|W1202|warnings.jac:2:24-43|this positional constructor pattern has 5 fields; \
       labeled constructor patterns are the future fix|D36 keeps labeled constructor patterns \
       unavailable for now; keep positional matches to four fields or fewer";
      "error|E0802|warnings.jac:3:6-7|the `|>` right-hand side has type int, which is not a \
       function|the right-hand side of `|>` must be callable";
    ]
    rendered;
  let nested = analyze "match 1 { | Outer(Five(a, b, c, d, e)) -> 0 | _ -> 1 }\n" in
  Alcotest.(check int) "nested wide warning" 1 (List.length (diagnostics "W1202" nested));
  let raw =
    analyze
      "jqd { (match (lit 1) (clause (pcon x (pvar a) (pvar b) (pvar c) (pvar d) (pvar e)) (lit \
       0))) }\n"
  in
  Alcotest.(check int) "raw jqd excluded" 0 (List.length (diagnostics "W1202" raw))

let test_cross_island_terms () =
  let report = analyze "a = 1\nb = a\nid(value) = value\nc = id(b)\n" in
  Alcotest.(check (list string))
    "dependency-ordered signatures" [ "a"; "b"; "id"; "c" ] (signature_names report);
  Alcotest.(check (list string)) "dependency-ordered diagnostics" [] (codes report)

let test_cross_island_type_dependency_is_explicitly_unsupported () =
  let report = analyze "type Local = | Local\nvalue = Local\nlater = 1\n" in
  Alcotest.(check (list string)) "type dependency diagnostic" [ "E0301" ] (codes report);
  Alcotest.(check (list string)) "later term still checks" [ "later" ] (signature_names report)

let test_analysis_isolation_repeatability_and_concurrency () =
  let store, context = make () in
  let names = Store.names_view store in
  let source = "a = 1\nb = a\nbool.and-then(True, b)\n" in
  let first = analyze_with ~names context source in
  let second = analyze_with ~names context source in
  Alcotest.(check (list string)) "repeat diagnostics" (report_golden first) (report_golden second);
  Alcotest.(check (list string))
    "repeat signatures" (signature_names first) (signature_names second);
  let synthetic = Hash.of_string "surface-recovery-member:0:0:a" in
  let forged = Kernel.{ it = Ref (synthetic, Term); meta = Meta.empty } in
  (match Check.check_top context (Kernel.Expr forged) with
  | Error [ diagnostic ] -> Alcotest.(check string) "forged synthetic ref" "E0805" diagnostic.code
  | Error diagnostics -> fail_diags "forged synthetic ref" diagnostics
  | Ok _ -> Alcotest.fail "forged synthetic ref reached the caller cache");
  let strict = Kernel.{ it = Lit (LInt 1); meta = Meta.empty } in
  (match Check.check_top context (Kernel.Expr strict) with
  | Ok _ -> ()
  | Error diagnostics -> fail_diags "strict after analysis" diagnostics);
  let left = Domain.spawn (fun () -> analyze_with ~names context source) in
  let right = Domain.spawn (fun () -> analyze_with ~names context source) in
  let left = Domain.join left and right = Domain.join right in
  Alcotest.(check (list string)) "concurrent diagnostics" (report_golden left) (report_golden right);
  Alcotest.(check (list string))
    "concurrent signatures" (signature_names left) (signature_names right)

let test_semantic_boundaries_reject_nested_markers () =
  let marker = Meta.empty |> Meta.with_surface_hole "forged" in
  let leaf = Kernel.{ it = Lit (LInt 0); meta = marker } in
  let payload =
    Form.
      {
        head = "quote-data";
        meta = Meta.empty;
        args = [ F Form.{ head = "lit"; meta = marker; args = [ Int 0 ] } ];
      }
  in
  let quoted = Kernel.{ it = Quote payload; meta = Meta.empty } in
  let _, checker = make () in
  let store = Check.store checker in
  let expect_e1202 label = function
    | Error [ diagnostic ] -> Alcotest.(check string) label "E1202" diagnostic.Diag.code
    | Error diagnostics -> fail_diags label diagnostics
    | Ok _ -> Alcotest.failf "%s accepted a recovery marker" label
  in
  expect_e1202 "strict checker nested quote" (Check.check_top checker (Kernel.Expr quoted));
  expect_e1202 "canonical expression" (Canon.hash_expr quoted);
  let binding = Kernel.{ bname = "marked"; annot = None; value = leaf; bmeta = Meta.empty } in
  let declaration = Kernel.{ it = DefTerm [ binding ]; meta = Meta.empty } in
  expect_e1202 "canonical declaration" (Canon.hash_decl declaration);
  expect_e1202 "store insertion" (Store.put_decl store declaration);
  let evaluator = Eval.make_ctx store in
  (match Eval.run_expr evaluator quoted with
  | Error (Runtime_err.Type_error message) ->
      Alcotest.(check bool) "evaluation E1202" true (String.starts_with ~prefix:"E1202:" message)
  | Error error -> Alcotest.failf "unexpected evaluation error: %s" (Runtime_err.to_string error)
  | Ok _ -> Alcotest.fail "evaluation accepted a marked quote payload");
  let marked_pat = Kernel.{ it = PWild; meta = marker } in
  let marked_ty = Kernel.{ it = TVar "a"; meta = marker } in
  let handler =
    Kernel.
      {
        it =
          Handle
            {
              body = Kernel.{ it = Lit (LInt 0); meta = Meta.empty };
              ret =
                {
                  rbinder = Kernel.{ it = PWild; meta = Meta.empty };
                  rbody = Kernel.{ it = Lit (LInt 0); meta = Meta.empty };
                  rmeta = marker;
                };
              ops = [];
            };
        meta = Meta.empty;
      }
  in
  let lambda =
    Kernel.
      { it = Lam ([ marked_pat ], { it = Lit (LInt 0); meta = Meta.empty }); meta = Meta.empty }
  in
  let annotated =
    Kernel.{ it = Ann ({ it = Lit (LInt 0); meta = Meta.empty }, marked_ty); meta = Meta.empty }
  in
  expect_e1202 "strict checker nested pattern" (Check.check_top checker (Kernel.Expr lambda));
  expect_e1202 "strict checker nested type" (Check.check_top checker (Kernel.Expr annotated));
  expect_e1202 "strict checker handler auxiliary" (Check.check_top checker (Kernel.Expr handler))

let test_strict_boundaries_reject_recovery () =
  let recovered = Surface_parse.recover_string ~file:"strict.jac" "value = @\n" in
  (match Surface_parse.strict recovered with
  | Error diagnostics ->
      Alcotest.(check bool)
        "strict reports syntax" true
        (List.exists (fun diagnostic -> diagnostic.Diag.severity = Diag.Error) diagnostics)
  | Ok _ -> Alcotest.fail "strict parser accepted a recovered hole");
  let meta = Meta.empty |> Meta.with_surface_hole "manual" in
  let sentinel = Kernel.{ it = Lit (LInt 0); meta } in
  let _, context = make () in
  match Check.check_top context (Kernel.Expr sentinel) with
  | Error [ diagnostic ] -> Alcotest.(check string) "strict checker guard" "E1202" diagnostic.code
  | Error diagnostics -> fail_diags "strict checker sentinel" diagnostics
  | Ok _ -> Alcotest.fail "strict checker accepted an analysis sentinel"

let suite =
  [
    Alcotest.test_case "hole kinds and independent islands" `Quick
      test_hole_kinds_and_independent_islands;
    Alcotest.test_case "primary plus later type error" `Quick test_primary_plus_later_type_error;
    Alcotest.test_case "malformed row checks as any row" `Quick test_malformed_row_checks_as_any_row;
    Alcotest.test_case "surface wording and spans" `Quick test_surface_wording_and_spans;
    Alcotest.test_case "eta guidance matrix" `Quick test_eta_guidance_matrix;
    Alcotest.test_case "eta exact positive and negatives" `Quick
      test_eta_exact_positive_and_negatives;
    Alcotest.test_case "raw jqd eta stability" `Quick test_raw_jqd_eta_stability;
    Alcotest.test_case "case confusion scope and namespace" `Quick
      test_case_confusion_scope_and_namespace;
    Alcotest.test_case "wide pattern boundary and coexistence" `Quick
      test_wide_pattern_boundary_and_coexistence;
    Alcotest.test_case "warning exact order nested raw and redundancy" `Quick
      test_warning_exact_order_nested_raw_and_redundancy;
    Alcotest.test_case "cross-island terms" `Quick test_cross_island_terms;
    Alcotest.test_case "cross-island type dependency is explicitly unsupported" `Quick
      test_cross_island_type_dependency_is_explicitly_unsupported;
    Alcotest.test_case "analysis isolation repeatability and concurrency" `Quick
      test_analysis_isolation_repeatability_and_concurrency;
    Alcotest.test_case "semantic boundaries reject nested markers" `Quick
      test_semantic_boundaries_reject_nested_markers;
    Alcotest.test_case "strict boundaries reject recovery" `Quick
      test_strict_boundaries_reject_recovery;
  ]
