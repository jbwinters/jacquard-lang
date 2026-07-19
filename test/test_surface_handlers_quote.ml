open Jacquard
open Surface_ast

let fail_diags label diagnostics =
  Alcotest.failf "%s: %s" label (String.concat "; " (List.map Diag.to_string diagnostics))

let parse_expr ?(file = "handlers-quote.jac") source =
  match Surface_parse.parse_string ~file source with
  | Ok [ { Surface_ast.it = TopExpr expression; _ } ] -> expression
  | Ok items -> Alcotest.failf "expected one expression, got %d top-level items" (List.length items)
  | Error diagnostics -> fail_diags "surface parse" diagnostics

let lower ?file source =
  match Surface_lower.lower_expr (parse_expr ?file source) with
  | Ok expression -> expression
  | Error diagnostics -> fail_diags "surface lower" diagnostics

let bootstrap source =
  match Reader.parse_one ~file:"handlers-quote.jqd" source with
  | Error diagnostics -> fail_diags "bootstrap parse" diagnostics
  | Ok form -> (
      match Kernel.expr_of_form form with
      | Ok expression -> expression
      | Error diagnostics -> fail_diags "bootstrap validate" diagnostics)

let check_equivalent label surface jqd =
  Alcotest.(check bool)
    label true
    (Form.equal_ignoring_meta
       (Kernel.expr_to_form (bootstrap jqd))
       (Kernel.expr_to_form (lower surface)))

let diagnostic_codes recovered =
  List.map (fun diagnostic -> Diag.code_or_uncoded diagnostic) recovered.Surface_ast.diagnostics

let parse_error_codes source =
  match Surface_parse.parse_string ~file:"bad-handler.jac" source with
  | Ok _ -> Alcotest.failf "expected %S to fail parsing" source
  | Error diagnostics -> List.map (fun diagnostic -> Diag.code_or_uncoded diagnostic) diagnostics

let test_handler_equivalence_and_clause_shapes () =
  check_equivalent "return-only handler" "handle body { | return Some(x) -> x }"
    "(handle (var body) (ret (pcon some (pvar x)) (var x)))";
  check_equivalent "zero and multiple operation parameters"
    {|handle body() {
  | return x -> x
  | ping() resume k -> k(0)
  | choose(Left(x), _, (a, b)) resume unused -> x
}|}
    {|(handle (app (var body))
  (ret (pvar x) (var x))
  (opclause ping () k (app (var k) (lit 0)))
  (opclause choose ((pcon left (pvar x)) (pwild) (ptuple (pvar a) (pvar b))) unused (var x)))|};
  let hash = Hash.of_string "surface-handler-op" in
  let source =
    Printf.sprintf
      "handle body() { | return x -> x | `op:a--b`() resume k -> k(x) | #%s:op() resume _ -> 0 }"
      (Hash.to_hex hash)
  in
  match (lower source).Kernel.it with
  | Kernel.Handle
      {
        ops =
          [
            { op = Kernel.Named "a--b"; resume = "k"; _ };
            { op = Kernel.Hashed actual; resume = "_"; _ };
          ];
        _;
      } ->
      Alcotest.(check bool) "hashed operation intent" true (Hash.equal hash actual)
  | _ -> Alcotest.fail "operation/ref intent or resume binders were not preserved"

let test_d35_wrapped_and_unwrapped_bodies () =
  check_equivalent "wrapped match body"
    {|handle { match direction { | Up -> risky() | down -> safe(down) } } {
  | return x -> x
  | abort() resume unused -> 0
}|}
    {|(handle
  (match (var direction)
    (clause (pcon up) (app (var risky)))
    (clause (pvar down) (app (var safe) (var down))))
  (ret (pvar x) (var x))
  (opclause abort () unused (lit 0)))|};
  check_equivalent "wrapped block body" "handle { let x = 1; x } { | return result -> result }"
    "(handle (let nonrec (pvar x) (lit 1) (var x)) (ret (pvar result) (var result)))";
  Alcotest.(check bool)
    "unwrapped match gets targeted D35 diagnostic" true
    (List.mem "E1226"
       (parse_error_codes "handle match direction { | Up -> risky() } { | return x -> x }"));
  List.iter
    (fun source ->
      Alcotest.(check bool)
        (source ^ " is non-atomic") true
        (List.mem "E1226" (parse_error_codes source)))
    [
      "handle (body()) { | return x -> x }";
      "handle fn (x) -> x { | return x -> x }";
      "handle 1() { | return x -> x }";
    ]

let find_following_definition recovered =
  List.exists
    (function
      | {
          Surface_ast.it = Definition { name = "after"; value = { it = Lit (Kernel.LInt 7); _ }; _ };
          _;
        } ->
          true
      | _ -> false)
    recovered.Surface_ast.items

let count_code code recovered =
  List.fold_left
    (fun count diagnostic ->
      if String.equal (Diag.code_or_uncoded diagnostic) code then count + 1 else count)
    0 recovered.Surface_ast.diagnostics

let count_diagnostic code diagnostics =
  List.fold_left
    (fun count diagnostic ->
      if String.equal (Diag.code_or_uncoded diagnostic) code then count + 1 else count)
    0 diagnostics

let count_reader_diagnostics diagnostics =
  List.fold_left
    (fun count diagnostic ->
      if String.starts_with ~prefix:"E01" (Diag.code_or_uncoded diagnostic) then count + 1
      else count)
    0 diagnostics

let raw_top_ints recovered =
  List.filter_map
    (function
      | { Surface_ast.it = RawTop { Form.head = "lit"; args = [ Form.Int value ]; _ }; _ } ->
          Some value
      | _ -> None)
    recovered.Surface_ast.items

let has_raw_top recovered =
  List.exists
    (function { Surface_ast.it = RawTop _; _ } -> true | _ -> false)
    recovered.Surface_ast.items

let rec has_quote_expr expression =
  match expression.Surface_ast.it with
  | Quote _ -> true
  | Call (fn, args) -> has_quote_expr fn || List.exists has_quote_expr args
  | Fn (_, body) | Unquote body | Ann (body, _) -> has_quote_expr body
  | Tuple items | List items -> List.exists has_quote_expr items
  | Block items ->
      List.exists
        (function
          | Let { value; _ } -> has_quote_expr value | Expr expression -> has_quote_expr expression)
        items
  | Match (subject, clauses) ->
      has_quote_expr subject || List.exists (fun clause -> has_quote_expr clause.cbody) clauses
  | If (condition, yes, no) -> has_quote_expr condition || has_quote_expr yes || has_quote_expr no
  | Pipe (left, right) -> has_quote_expr left || has_quote_expr right
  | Handle (body, ret, ops) ->
      has_quote_expr body || has_quote_expr ret.rbody
      || List.exists (fun op -> has_quote_expr op.obody) ops
  | Lit _ | Name _ | HashRef _ | GroupRef _ | Hole _ -> false

let has_quote recovered =
  List.exists
    (function
      | { Surface_ast.it = TopExpr expression; _ }
      | { Surface_ast.it = Definition { value = expression; _ }; _ } ->
          has_quote_expr expression
      | _ -> false)
    recovered.Surface_ast.items

let has_constructor_arm name recovered =
  List.exists
    (function
      | { Surface_ast.it = TopExpr { it = Match (_, clauses); _ }; _ } ->
          List.exists
            (fun clause ->
              match clause.Surface_ast.cpattern.it with
              | PCon (Named actual, _) -> String.equal actual name
              | _ -> false)
            clauses
      | _ -> false)
    recovered.Surface_ast.items

let find_operation name recovered =
  List.exists
    (function
      | { Surface_ast.it = TopExpr { it = Handle (_, _, operations); _ }; _ } ->
          List.exists
            (fun operation -> operation.Surface_ast.operation = Surface_ast.Named name)
            operations
      | _ -> false)
    recovered.Surface_ast.items

let test_missing_quote_brace_recovery () =
  let check_boundary label source =
    let recovered = Surface_parse.recover_string ~file:"missing-quote.jac" source in
    Alcotest.(check int) (label ^ " reports one E1221") 1 (count_code "E1221" recovered);
    Alcotest.(check int) (label ^ " reports no generic E1220") 0 (count_code "E1220" recovered);
    Alcotest.(check bool)
      (label ^ " preserves the following definition")
      true
      (find_following_definition recovered);
    (match
       List.find_opt
         (fun diagnostic -> Diag.code_or_uncoded diagnostic = "E1221")
         recovered.diagnostics
     with
    | Some diagnostic when Option.is_some (Diag.span diagnostic) ->
        let span = Option.get (Diag.span diagnostic) in
        Alcotest.(check string)
          (label ^ " boundary span") "missing-quote.jac:2:1-6" (Span.to_string span)
    | _ -> Alcotest.failf "%s did not retain the E1221 span" label);
    (match Surface_parse.parse_string ~file:"missing-quote.jac" source with
    | Error diagnostics ->
        Alcotest.(check int)
          (label ^ " strict reports one E1221")
          1
          (count_diagnostic "E1221" diagnostics);
        Alcotest.(check int)
          (label ^ " strict reports no generic E1220")
          0
          (count_diagnostic "E1220" diagnostics)
    | Ok _ -> Alcotest.failf "%s was accepted by the strict parser" label);
    recovered
  in
  let ordinary = check_boundary "ordinary top quote" "quote { 1\nafter = 7\n" in
  Alcotest.(check bool) "ordinary recovery retains a quote" true (has_quote ordinary);
  let raw = check_boundary "raw top quote" "quote { jqd { (lit 1) }\nafter = 7\n" in
  Alcotest.(check bool) "raw recovery retains a quote" true (has_quote raw);
  ignore (check_boundary "definition quote" "broken = quote { 1\nafter = 7\n");
  let commented =
    Surface_parse.recover_string ~file:"missing-commented-quote.jac"
      "quote { jqd { (lit 1) }\n-- quote closes above\nafter = 7\n"
  in
  Alcotest.(check (list string))
    "commented boundary has one stable diagnostic" [ "E1221" ] (diagnostic_codes commented);
  Alcotest.(check bool)
    "commented boundary preserves the following definition" true
    (find_following_definition commented);
  (match commented.diagnostics with
  | [ diagnostic ] when Option.is_some (Diag.span diagnostic) ->
      let span = Option.get (Diag.span diagnostic) in
      Alcotest.(check string)
        "commented boundary span" "missing-commented-quote.jac:3:1-6" (Span.to_string span)
  | _ -> Alcotest.fail "commented quote recovery produced an unexpected diagnostic shape");
  let handler =
    Surface_parse.recover_string ~file:"missing-handler-quote.jac"
      {|handle body() {
  | return x -> quote { jqd { (lit 1) }
  | abort() resume _ -> 0
}
after = 7
|}
  in
  Alcotest.(check int) "handler quote reports one E1221" 1 (count_code "E1221" handler);
  Alcotest.(check int) "handler quote reports no E1220" 0 (count_code "E1220" handler);
  Alcotest.(check bool)
    "handler quote preserves its next clause" true (find_operation "abort" handler);
  Alcotest.(check bool)
    "handler quote preserves its next top" true
    (find_following_definition handler);
  let matching =
    Surface_parse.recover_string ~file:"missing-match-quote.jac"
      {|match value {
  | A -> quote { 1
  | B -> 2
}
after = 7
|}
  in
  Alcotest.(check int) "match quote reports one E1221" 1 (count_code "E1221" matching);
  Alcotest.(check int) "match quote reports no E1220" 0 (count_code "E1220" matching);
  Alcotest.(check bool) "match quote preserves its next arm" true (has_constructor_arm "b" matching);
  Alcotest.(check bool)
    "match quote preserves its next top" true
    (find_following_definition matching);
  List.iter
    (fun (label, source) ->
      let recovered = Surface_parse.recover_string ~file:"valid-multiline-quote.jac" source in
      Alcotest.(check int) (label ^ " has no diagnostics") 0 (List.length recovered.diagnostics);
      Alcotest.(check bool)
        (label ^ " preserves the following definition")
        true
        (find_following_definition recovered);
      match Surface_parse.parse_string ~file:"valid-multiline-quote.jac" source with
      | Ok _ -> ()
      | Error diagnostics -> fail_diags (label ^ " strict parse") diagnostics)
    [
      ("ordinary multiline close", "quote {\n  1\n}\nafter = 7\n");
      ("raw multiline close", "quote {\n  jqd { (lit 1) }\n}\nafter = 7\n");
    ]

let test_handler_recovery_and_return_cardinality () =
  let missing =
    Surface_parse.recover_string ~file:"recover-handler.jac"
      "handle body() { | abort() resume _ -> 0 }\nafter = 7\n"
  in
  Alcotest.(check bool)
    "missing return is stable" true
    (List.mem "E0212" (diagnostic_codes missing));
  Alcotest.(check bool)
    "missing return preserves following top" true
    (find_following_definition missing);
  let duplicate =
    Surface_parse.recover_string ~file:"recover-handler.jac"
      "handle body() { | return x -> x | return y -> y | abort() resume _ -> 0 }\nafter = 7\n"
  in
  Alcotest.(check bool)
    "duplicate return is stable" true
    (List.mem "E0212" (diagnostic_codes duplicate));
  (match duplicate.items with
  | { Surface_ast.it = TopExpr { it = Handle (_, _, [ _ ]); _ }; _ } :: _ -> ()
  | _ -> Alcotest.fail "duplicate return recovery swallowed the later operation clause");
  Alcotest.(check bool)
    "duplicate return preserves following top" true
    (find_following_definition duplicate);
  let malformed =
    Surface_parse.recover_string ~file:"recover-handler.jac"
      "handle body() { | return x -> x | abort(x) k -> 0 | later(a, b) resume _ -> a }\nafter = 7\n"
  in
  Alcotest.(check bool)
    "malformed clause reports damage" true
    (List.mem "E1220" (diagnostic_codes malformed));
  (match malformed.items with
  | { Surface_ast.it = TopExpr { it = Handle (_, _, [ _; later ]); _ }; _ } :: _ ->
      Alcotest.(check string) "later operation survives" "_" later.Surface_ast.oresume
  | _ -> Alcotest.fail "malformed clause recovery swallowed the later clause");
  Alcotest.(check bool)
    "malformed clause preserves following top" true
    (find_following_definition malformed);
  let truncated =
    Surface_parse.recover_string ~file:"recover-handler.jac"
      "handle body() { | return x -> x\nafter = 7\n"
  in
  Alcotest.(check bool)
    "missing handler brace is stable" true
    (List.mem "E1221" (diagnostic_codes truncated));
  Alcotest.(check bool)
    "missing handler brace preserves following top" true
    (find_following_definition truncated);
  let raw_reader_damage =
    Surface_parse.recover_string ~file:"recover-handler.jac"
      {|handle body() {
  | return x -> quote { jqd { (lit 1) (lit 2) } }
  | abort() resume _ -> 0
}
after = 7
|}
  in
  Alcotest.(check int)
    "raw Reader diagnostic survives exactly once" 1
    (count_code "E0114" raw_reader_damage);
  (match
     List.find_opt
       (fun diagnostic -> String.equal (Diag.code_or_uncoded diagnostic) "E0114")
       raw_reader_damage.diagnostics
   with
  | Some diagnostic when Option.is_some (Diag.span diagnostic) ->
      let span = Option.get (Diag.span diagnostic) in
      Alcotest.(check string)
        "raw Reader diagnostic maps to the surface raw region" "recover-handler.jac:2:29-48"
        (Span.to_string span)
  | _ -> Alcotest.fail "mapped E0114 diagnostic was missing");
  Alcotest.(check bool)
    "operation after damaged return survives" true
    (find_operation "abort" raw_reader_damage);
  Alcotest.(check bool)
    "definition after damaged handler survives" true
    (find_following_definition raw_reader_damage)

let test_handler_spans_and_provenance () =
  let source = "handle body() {\n  | return Some(x) -> x\n  | abort() resume _ -> 0\n}" in
  match parse_expr ~file:"span-handler.jac" source with
  | {
   Surface_ast.it =
     Handle
       ( _,
         { rbinder = { it = PCon (Named "some", [ { it = PBind "x"; _ } ]); _ }; rmeta; _ },
         [ { oresume = "_"; ometa; _ } ] );
   meta;
  } ->
      Alcotest.(check (option string))
        "handler span" (Some "span-handler.jac:1:1-4:2")
        (Option.map Span.to_string (Meta.span meta));
      Alcotest.(check bool) "return clause span" true (Option.is_some (Meta.span rmeta));
      Alcotest.(check (option string))
        "operation intent provenance" (Some "op") (Meta.surface_ref_kind ometa)
  | _ -> Alcotest.fail "handler source spans or full return pattern were lost"

let payload = function
  | { Kernel.it = Kernel.Quote payload; _ } -> payload
  | _ -> Alcotest.fail "expected a kernel quote"

let test_quote_unquote_and_resolution () =
  check_equivalent "quote of call" "quote { f(1, x) }" "(quote (app (var f) (lit 1) (var x)))";
  check_equivalent "unquote splice" "quote { unquote(f)(41) }"
    "(quote (app (unquote (var f)) (lit 41)))";
  check_equivalent "nested quote and unquote" "quote { quote { unquote(f)(1) } }"
    "(quote (quote (app (unquote (var f)) (lit 1))))";
  check_equivalent "quote depth survives tuple traversal"
    "quote { (unquote(a), quote { unquote(b) }) }"
    "(quote (tuple (unquote (var a)) (quote (unquote (var b)))))";
  let f_hash = Hash.of_string "surface-quoted-f" in
  let x_hash = Hash.of_string "surface-live-x" in
  let names =
    Resolve.of_alist
      [
        ("f", { Resolve.hash = f_hash; kind = Resolve.KTerm });
        ("x", { Resolve.hash = x_hash; kind = Resolve.KTerm });
      ]
  in
  let resolved =
    match Resolve.resolve_expr names (lower "quote { f(unquote(x)) }") with
    | Ok expression -> expression
    | Error diagnostics -> fail_diags "quote resolution" diagnostics
  in
  let expected =
    Reader.parse_one ~file:"quote-resolution.jqd"
      (Printf.sprintf "(app (var f) (unquote (ref #%s term)))" (Hash.to_hex x_hash))
    |> Result.get_ok
  in
  Alcotest.(check bool)
    "quoted name stays unresolved and live splice resolves" true
    (Form.equal_ignoring_meta expected (payload resolved));
  match Surface_lower.lower_expr (parse_expr "unquote(x)") with
  | Error [ diagnostic ]
    when Diag.code diagnostic = Some "E0204" && Option.is_some (Diag.span diagnostic) ->
      ()
  | Error diagnostics -> fail_diags "unquote outside quote" diagnostics
  | Ok _ -> Alcotest.fail "unquote outside quote reached the kernel"

let parse_and_lower_tops source =
  match Surface_parse.parse_string ~file:"quote-depth.jac" source with
  | Error diagnostics -> fail_diags "quote-depth parse" diagnostics
  | Ok tops -> (
      match Surface_lower.lower_tops tops with
      | Ok tops -> tops
      | Error diagnostics -> fail_diags "quote-depth lower" diagnostics)

let test_double_unquote_depth_and_dependencies () =
  let source = "a = quote { quote { unquote(unquote(b)) } }\nb = a\n" in
  let declaration =
    match parse_and_lower_tops source with
    | [ Kernel.Decl declaration ] -> declaration
    | _ -> Alcotest.fail "mutual double-unquote definitions were not one declaration"
  in
  (match declaration.Kernel.it with
  | Kernel.DefTerm [ a; b ] ->
      Alcotest.(check string) "SCC keeps a first" "a" a.bname;
      Alcotest.(check string) "SCC keeps b second" "b" b.bname;
      Alcotest.(check (list string))
        "inner unquote is live relative to the outer quote" [ "b" ]
        (Surface_lower.String_set.elements (Surface_lower.free_names a.value))
  | _ -> Alcotest.fail "double-unquote cycle was not one source-ordered SCC");
  (match Resolve.resolve_decl Resolve.empty_names declaration with
  | Ok
      {
        Kernel.it =
          Kernel.DefTerm
            [
              { value = { it = Kernel.Quote resolved_payload; _ }; _ };
              { value = { it = Kernel.GroupRef 0; _ }; _ };
            ];
        _;
      } ->
      let expected =
        Reader.parse_one ~file:"quote-depth.jqd" "(quote (unquote (unquote (groupref 1))))"
        |> Result.get_ok
      in
      Alcotest.(check bool)
        "live nested splice resolves through the SCC" true
        (Form.equal_ignoring_meta expected resolved_payload)
  | Ok _ -> Alcotest.fail "double-unquote SCC resolved to the wrong shape"
  | Error diagnostics -> fail_diags "double-unquote resolve" diagnostics);
  let ordered =
    parse_and_lower_tops
      "dependent = quote { quote { unquote(unquote(dependency)) } }\ndependency = 1\n"
  in
  let names =
    List.map
      (function
        | Kernel.Decl { Kernel.it = DefTerm bindings; _ } ->
            List.map (fun binding -> binding.Kernel.bname) bindings
        | _ -> Alcotest.fail "expected only dependency declarations")
      ordered
  in
  Alcotest.(check (list (list string)))
    "double-unquote dependency is emitted first"
    [ [ "dependency" ]; [ "dependent" ] ]
    names

let parse_printed_expr source = lower ~file:"printed.jac" source

let print_expr expression =
  match Surface_print.print_top (Kernel.Expr expression) with
  | Ok source -> source
  | Error diagnostics -> fail_diags "surface print" diagnostics

let check_print_round_trip label expression =
  let printed = print_expr expression in
  let reparsed = parse_printed_expr printed in
  Alcotest.(check bool)
    (label ^ " form") true
    (Form.equal_ignoring_meta (Kernel.expr_to_form expression) (Kernel.expr_to_form reparsed));
  let hash expression =
    match Canon.hash_expr expression with
    | Ok hash -> hash
    | Error diagnostics -> fail_diags (label ^ " hash") diagnostics
  in
  Alcotest.(check bool) (label ^ " hash") true (Hash.equal (hash expression) (hash reparsed));
  printed

let parse_form source =
  match Reader.parse_one ~file:"surface-ref.jqd" source with
  | Ok form -> form
  | Error diagnostics -> fail_diags "surface-ref form" diagnostics

let hash_expr label expression =
  match Canon.hash_expr expression with
  | Ok hash -> hash
  | Error diagnostics -> fail_diags (label ^ " hash") diagnostics

let hash_top label top =
  match Canon.hash_top top with
  | Ok hashes -> hashes.Canon.decl_hash
  | Error diagnostics -> fail_diags (label ^ " hash") diagnostics

let check_top_print_round_trip label expected_print top =
  let printed =
    match Surface_print.print_top top with
    | Ok source -> source
    | Error diagnostics -> fail_diags (label ^ " print") diagnostics
  in
  Alcotest.(check string) (label ^ " raw print") expected_print printed;
  match parse_and_lower_tops printed with
  | [ reparsed ] ->
      Alcotest.(check bool)
        (label ^ " form") true
        (Form.equal_ignoring_meta (Kernel.to_form top) (Kernel.to_form reparsed));
      Alcotest.(check bool)
        (label ^ " hash") true
        (Hash.equal (hash_top label top) (hash_top (label ^ " reparsed") reparsed))
  | tops -> Alcotest.failf "%s: expected one reparsed top, got %d" label (List.length tops)

let rec perturb_form_meta (form : Form.t) =
  {
    form with
    Form.meta = Meta.add "test-perturbation" (Meta.Text form.head) form.meta;
    args =
      List.map
        (function Form.F child -> Form.F (perturb_form_meta child) | scalar -> scalar)
        form.args;
  }

let test_quoted_namespace_identity_and_printing () =
  let cases =
    [
      ("term", "quote { same }", "(var same)");
      ("constructor", "quote { Same }", "(surface-ref-v0 con same)");
      ("operation", "quote { `op:same` }", "(surface-ref-v0 op same)");
    ]
  in
  let expressions =
    List.map
      (fun (label, source, expected_payload) ->
        let expression = lower source in
        Alcotest.(check bool)
          (label ^ " structural payload") true
          (Form.equal_ignoring_meta (parse_form expected_payload) (payload expression));
        Alcotest.(check string)
          (label ^ " canonical print") source
          (check_print_round_trip (label ^ " quote") expression);
        let perturbed =
          match expression.Kernel.it with
          | Kernel.Quote quoted ->
              Kernel.
                {
                  it = Quote (perturb_form_meta quoted);
                  meta = Meta.add "test-outer-perturbation" (Meta.Text label) expression.meta;
                }
          | _ -> Alcotest.fail "namespace fixture was not a quote"
        in
        Alcotest.(check bool)
          (label ^ " metadata remains hash-excluded")
          true
          (Hash.equal (hash_expr label expression) (hash_expr label perturbed));
        expression)
      cases
  in
  let rec check_pairs = function
    | [] -> ()
    | expression :: rest ->
        List.iter
          (fun other ->
            Alcotest.(check bool)
              "namespace payloads differ structurally" false
              (Form.equal_ignoring_meta (payload expression) (payload other));
            Alcotest.(check bool)
              "namespace quote hashes differ" false
              (Hash.equal (hash_expr "namespace" expression) (hash_expr "namespace" other)))
          rest;
        check_pairs rest
  in
  check_pairs expressions

let test_quoted_namespace_eval_resolution () =
  let store, ctx = Eval_support.make_prelude_ctx () in
  let term_hashes =
    Eval_support.put_src store (Store.names_view store) "(defterm ((binding same () (lit 41))))"
  in
  let con_hashes =
    Eval_support.put_src store (Store.names_view store) "(deftype same-type () (con same))"
  in
  let op_hashes =
    Eval_support.put_src store (Store.names_view store)
      "(defeffect same-effect () (op same () (ttuple)))"
  in
  let term_hash = List.assoc "same" term_hashes.Canon.named in
  let con_hash = List.assoc "same" con_hashes.Canon.named in
  let op_hash = List.assoc "same" op_hashes.Canon.named in
  (match Prelude.install_eval ctx with
  | Ok () -> ()
  | Error diagnostics -> fail_diags "install eval" diagnostics);
  let eval_surface source =
    let expression = lower source in
    match Resolve.resolve_expr (Store.names_view store) expression with
    | Error diagnostics -> fail_diags "surface namespace resolve" diagnostics
    | Ok expression -> (
        match Eval.run_expr ctx expression with
        | Ok value -> value
        | Error error -> Alcotest.failf "surface namespace eval: %s" (Runtime_err.to_string error))
  in
  (match eval_surface "eval-code(quote { same })" with
  | Value.VInt 41 -> ()
  | value -> Alcotest.failf "term namespace resolved to %s" (Value.show value));
  (match eval_surface "eval-code(quote { Same })" with
  | Value.VCon { con; name = "same"; args = [] } ->
      Alcotest.(check bool) "constructor hash" true (Hash.equal con_hash con)
  | value -> Alcotest.failf "constructor namespace resolved to %s" (Value.show value));
  (match eval_surface "eval-code(quote { `op:same` })" with
  | Value.VOp { op; name = "same"; effect_ = "same-effect" } ->
      Alcotest.(check bool) "operation hash" true (Hash.equal op_hash op)
  | value -> Alcotest.failf "operation namespace resolved to %s" (Value.show value));
  Alcotest.(check bool) "term fixture has its own hash" false (Hash.equal term_hash con_hash)

let test_quoted_namespace_depth_and_raw_markers () =
  let staged = lower "quote { (Same, quote { `op:same` }, unquote(`con:same`)) }" |> payload in
  Alcotest.(check bool)
    "nested data encodes markers but the live splice stays an expression" true
    (Form.equal_ignoring_meta
       (parse_form
          "(tuple (surface-ref-v0 con same) (quote (surface-ref-v0 op same)) (unquote (var same)))")
       staged);
  Alcotest.(check (list string))
    "constructor data and a constructor live splice add no term dependency" []
    (Surface_lower.String_set.elements
       (Surface_lower.free_names (lower "quote { (Same, unquote(`con:same`)) }")));
  let live_quote = lower "quote { unquote(quote { Same }) }" |> payload in
  Alcotest.(check bool)
    "a quote evaluated by a live splice retains its own marker" true
    (Form.equal_ignoring_meta (parse_form "(unquote (quote (surface-ref-v0 con same)))") live_quote);
  let double = lower "quote { quote { unquote(unquote(Same)) } }" in
  Alcotest.(check bool)
    "double-unquote expression is not prematurely encoded" true
    (Form.equal_ignoring_meta
       (parse_form "(quote (unquote (unquote (var same))))")
       (payload double));
  let con_hash = Hash.of_string "surface-double-unquote-con" in
  let names = Resolve.of_alist [ ("same", { Resolve.hash = con_hash; kind = Resolve.KCon }) ] in
  let resolved =
    match Resolve.resolve_expr names double with
    | Ok expression -> payload expression
    | Error diagnostics -> fail_diags "double-unquote marker resolve" diagnostics
  in
  Alcotest.(check bool)
    "double-unquote resolves the intended constructor kind" true
    (Form.equal_ignoring_meta
       (parse_form
          (Printf.sprintf "(quote (unquote (unquote (ref #%s con))))" (Hash.to_hex con_hash)))
       resolved);
  let raw = lower "quote { jqd { (surface-ref-v0 con same) } }" in
  Alcotest.(check string)
    "raw marker prints canonically" "quote { Same }"
    (check_print_round_trip "raw marker" raw);
  let raw_op = lower "quote { jqd { (surface-ref-v0 op same) } }" in
  Alcotest.(check string)
    "raw operation marker in quote prints canonically" "quote { `op:same` }"
    (check_print_round_trip "raw operation marker quote" raw_op);
  List.iter
    (fun kind ->
      let form_source = Printf.sprintf "(surface-ref-v0 %s same)" kind in
      let top =
        match parse_and_lower_tops ("jqd { " ^ form_source ^ " }") with
        | [ (Kernel.Expr expression as top) ] ->
            Alcotest.(check (option string))
              (kind ^ " marker intent") (Some kind)
              (Meta.surface_ref_kind expression.meta);
            top
        | _ -> Alcotest.failf "%s raw marker did not lower as one expression" kind
      in
      let printed = Surface_print.print_top top |> Result.get_ok in
      Alcotest.(check string)
        (kind ^ " exact top-level inversion")
        ("jqd { " ^ form_source ^ " }")
        printed;
      match parse_and_lower_tops printed with
      | [ reparsed ] ->
          Alcotest.(check bool)
            (kind ^ " top-level form inversion")
            true
            (Form.equal_ignoring_meta (Kernel.to_form top) (Kernel.to_form reparsed))
      | _ -> Alcotest.failf "%s printed marker did not reparse as one top" kind)
    [ "con"; "op" ];
  let op_hash = Hash.of_string "surface-marker-handler-op" in
  let nested_form =
    Printf.sprintf
      "(lam ((pvar same)) (handle (surface-ref-v0 con same) (ret (pvar same) (surface-ref-v0 op \
       same)) (opclause #%s () same (ann (surface-ref-v0 con same) (tvar a)))))"
      (Hash.to_hex op_hash)
  in
  let nested_top =
    match parse_and_lower_tops ("jqd { " ^ nested_form ^ " }") with
    | [ top ] -> top
    | _ -> Alcotest.fail "nested executable markers did not lower as one top"
  in
  check_top_print_round_trip "nested executable markers" ("jqd { " ^ nested_form ^ " }") nested_top;
  let live_unquote_form = "(lam ((pvar same)) (quote (unquote (surface-ref-v0 op same))))" in
  let live_unquote_top =
    match parse_and_lower_tops ("jqd { " ^ live_unquote_form ^ " }") with
    | [ top ] -> top
    | _ -> Alcotest.fail "live-unquote marker fixture did not lower as one top"
  in
  check_top_print_round_trip "live-unquote executable marker"
    ("jqd { " ^ live_unquote_form ^ " }")
    live_unquote_top;
  let declaration_form =
    "(defterm ((binding marker () (lam ((pvar same)) (app (surface-ref-v0 op same) (surface-ref-v0 \
     con same))))))"
  in
  let declaration_top =
    match parse_and_lower_tops ("jqd { " ^ declaration_form ^ " }") with
    | [ top ] -> top
    | _ -> Alcotest.fail "declaration marker fixture did not lower as one top"
  in
  check_top_print_round_trip "declaration executable markers"
    ("jqd { " ^ declaration_form ^ " }")
    declaration_top;
  Alcotest.(check bool)
    "ordinary unquoted constructor intent keeps bootstrap var compatibility" true
    (Form.equal_ignoring_meta (parse_form "(var same)") (Kernel.expr_to_form (lower "Same")));
  Alcotest.(check string) "ordinary constructor stays surface" "Same" (print_expr (lower "Same"));
  Alcotest.(check string)
    "ordinary operation stays surface" "`op:same`"
    (print_expr (lower "`op:same`"));
  let malformed =
    [
      ("arity", "(surface-ref-v0 con)", "E0202");
      ("term kind", "(surface-ref-v0 term same)", "E0210");
      ("unknown kind", "(surface-ref-v0 unknown same)", "E0210");
      ("name sort", "(surface-ref-v0 con 1)", "E0203");
    ]
  in
  List.iter
    (fun (label, source, expected_code) ->
      match Kernel.expr_of_form (parse_form source) with
      | Error [ diagnostic ] ->
          Alcotest.(check string) label expected_code (Diag.code_or_uncoded diagnostic)
      | Error diagnostics -> fail_diags label diagnostics
      | Ok _ -> Alcotest.failf "%s marker was accepted" label)
    malformed;
  match Surface_lower.lower_expr (parse_expr "quote { jqd { (surface-ref-v0 invalid same) } }") with
  | Error [ diagnostic ] when Diag.code diagnostic = Some "E0210" -> ()
  | Error diagnostics -> fail_diags "malformed quoted raw marker" diagnostics
  | Ok _ -> Alcotest.fail "malformed marker survived quote validation"

let test_raw_jqd_inversion_and_round_trips () =
  let representative = bootstrap "(quote (app (var f) (lit 1)))" in
  Alcotest.(check string)
    "representative quote printer" "quote { f(1) }"
    (check_print_round_trip "representative quote" representative);
  let raw_payload =
    match Reader.parse_one ~file:"raw-payload.jqd" "(mystery foo)" with
    | Ok form -> form
    | Error diagnostics -> fail_diags "raw payload" diagnostics
  in
  let fallback = Kernel.{ it = Quote raw_payload; meta = Meta.empty } in
  Alcotest.(check string)
    "fallback quote printer" "quote { jqd { (mystery foo) } }"
    (check_print_round_trip "fallback quote" fallback);
  let balanced_source = "quote { jqd { (mystery \"}\" ; } in a comment\n foo) } }" in
  let balanced_expected =
    Reader.parse_one ~file:"balanced-raw.jqd" "(mystery \"}\" ; } in a comment\n foo)"
    |> Result.get_ok
  in
  let balanced = lower ~file:"balanced-raw.jac" balanced_source in
  Alcotest.(check bool)
    "raw mode balances strings and comments" true
    (Form.equal_ignoring_meta balanced_expected (payload balanced));
  Alcotest.(check (option string))
    "raw payload span is remapped" (Some "balanced-raw.jac:1:15-2:6")
    (Option.map Span.to_string (Meta.span (payload balanced).Form.meta));
  (match
     Surface_lower.lower_expr (parse_expr ~file:"bad-raw.jac" "quote { jqd { (unquote (lit)) } }")
   with
  | Error [ diagnostic ]
    when Diag.code diagnostic = Some "E0202" && Option.is_some (Diag.span diagnostic) ->
      let span = Option.get (Diag.span diagnostic) in
      Alcotest.(check string) "raw validation span" "bad-raw.jac:1:24-29" (Span.to_string span)
  | Error diagnostics -> fail_diags "raw validation" diagnostics
  | Ok _ -> Alcotest.fail "malformed live raw unquote was accepted");
  match Surface_parse.parse_string ~file:"raw-top.jac" "jqd { (lit 7) }" with
  | Ok tops -> (
      match Surface_lower.lower_tops tops with
      | Ok [ Kernel.Expr { Kernel.it = Kernel.Lit (LInt 7); _ } ] -> (
          let grouped =
            Reader.parse_one ~file:"grouped.jqd"
              "(defterm ((binding first () (lit 1)) (binding second () (lit 2))))"
            |> Result.get_ok |> Kernel.of_form |> Result.get_ok
          in
          let printed = Surface_print.print_top grouped |> Result.get_ok in
          Alcotest.(check bool)
            "raw top printer fallback" true
            (String.starts_with ~prefix:"jqd { " printed);
          let reparsed =
            Surface_parse.parse_string ~file:"printed-raw-top.jac" printed
            |> Result.get_ok |> Surface_lower.lower_tops |> Result.get_ok
          in
          match reparsed with
          | [ actual ] ->
              Alcotest.(check bool)
                "raw top print inversion" true
                (Form.equal_ignoring_meta (Kernel.to_form grouped) (Kernel.to_form actual))
          | _ -> Alcotest.fail "raw top printer fallback did not reparse as one top")
      | Ok _ -> Alcotest.fail "raw top did not lower to its bootstrap form"
      | Error diagnostics -> fail_diags "raw top lower" diagnostics)
  | Error diagnostics -> fail_diags "raw top parse" diagnostics

let test_raw_recovery_and_illegal_context () =
  let check_one code source =
    let recovered = Surface_parse.recover_string ~file:"malformed-raw.jac" source in
    Alcotest.(check int) (code ^ " occurs exactly once") 1 (count_code code recovered);
    (match Surface_parse.parse_string ~file:"malformed-raw.jac" source with
    | Error diagnostics ->
        Alcotest.(check int)
          (code ^ " occurs exactly once through the strict entry point")
          1
          (count_diagnostic code diagnostics)
    | Ok _ -> Alcotest.failf "%s was accepted by the strict entry point" code);
    recovered
  in
  let bad_reader = check_one "E0101" "quote { jqd { (lit @) } }\nafter = 7\n" in
  (match
     List.find_opt
       (fun diagnostic -> String.equal (Diag.code_or_uncoded diagnostic) "E0101")
       bad_reader.diagnostics
   with
  | Some diagnostic when Option.is_some (Diag.span diagnostic) ->
      let span = Option.get (Diag.span diagnostic) in
      Alcotest.(check string)
        "Reader error span remaps into surface source" "malformed-raw.jac:1:20-20"
        (Span.to_string span)
  | _ -> Alcotest.fail "mapped raw Reader syntax diagnostic was missing");
  Alcotest.(check bool)
    "Reader syntax damage preserves later declaration" true
    (find_following_definition bad_reader);
  ignore (check_one "E0101" "jqd { (lit @) }\nafter = 7\n");
  ignore (check_one "E0114" "jqd { (lit 1) (lit 2) }\nafter = 7\n");
  ignore (check_one "E0114" "quote { jqd { (lit 1) (lit 2) } }\nafter = 7\n");
  ignore (check_one "E1221" "quote { jqd { (lit 1)");
  ignore (check_one "E0102" "quote { jqd { (lit \"unterminated) }");
  ignore (check_one "E1221" "quote { jqd { (lit 1) ; raw close }\n");
  check_equivalent "raw nested quote obeys outer liveness"
    "quote { quote { jqd { (unquote (unquote (var b))) } } }"
    "(quote (quote (unquote (unquote (var b)))))";
  (match
     Surface_lower.lower_expr
       (parse_expr ~file:"nested-malformed-raw.jac"
          "quote { quote { jqd { (unquote (unquote (lit))) } } }")
   with
  | Error [ diagnostic ]
    when Diag.code diagnostic = Some "E0202" && Option.is_some (Diag.span diagnostic) ->
      let span = Option.get (Diag.span diagnostic) in
      Alcotest.(check string)
        "nested raw validation remaps the live splice span" "nested-malformed-raw.jac:1:41-46"
        (Span.to_string span)
  | Error diagnostics -> fail_diags "nested malformed raw validation" diagnostics
  | Ok _ -> Alcotest.fail "malformed nested live raw splice was accepted");
  let illegal_source = "f(jqd { (lit 1) (lit 2) })\nafter = 7\n" in
  let lexed = Surface_lex.lex_recover ~file:"illegal-raw.jac" illegal_source in
  Alcotest.(check bool)
    "illegal expression context remains an inert candidate" true
    (List.exists
       (fun token ->
         match token.Surface_lex.token with Surface_lex.RawCandidate _ -> true | _ -> false)
       lexed.tokens);
  let recovered = Surface_parse.recover_string ~file:"illegal-raw.jac" illegal_source in
  Alcotest.(check bool)
    "illegal expression-context jqd is diagnosed" true (recovered.diagnostics <> []);
  Alcotest.(check int)
    "illegal expression context emits no Reader diagnostic" 0 (count_code "E0114" recovered);
  Alcotest.(check bool)
    "illegal expression context constructs no RawTop" false (has_raw_top recovered);
  Alcotest.(check bool) "illegal expression context constructs no Quote" false (has_quote recovered);
  Alcotest.(check bool)
    "illegal expression-context jqd preserves later declaration" true
    (find_following_definition recovered);
  match Surface_parse.parse_string ~file:"illegal-raw.jac" illegal_source with
  | Error diagnostics ->
      Alcotest.(check int)
        "strict illegal context emits no Reader diagnostic" 0
        (count_diagnostic "E0114" diagnostics)
  | Ok _ -> Alcotest.fail "strict parsing accepted call-position jqd"

let test_raw_parser_owned_recovery_boundaries () =
  let unmatched_handler =
    Surface_parse.recover_string ~file:"review-a.jac"
      {|handle body() {
  | return (x -> x
}
jqd { (lit 7) }
after = 7
|}
  in
  Alcotest.(check (list int))
    "review A preserves the later raw top" [ 7 ] (raw_top_ints unmatched_handler);
  Alcotest.(check bool)
    "review A preserves the following declaration" true
    (find_following_definition unmatched_handler);
  let illegal_pattern =
    Surface_parse.recover_string ~file:"review-b.jac"
      {|match x {
  | quote { jqd { (lit 1) (lit 2) } } -> 0
  | A -> 1
}
after = 7
|}
  in
  Alcotest.(check int) "review B emits no E0114" 0 (count_code "E0114" illegal_pattern);
  Alcotest.(check bool) "review B constructs no RawTop" false (has_raw_top illegal_pattern);
  Alcotest.(check bool) "review B constructs no Quote" false (has_quote illegal_pattern);
  Alcotest.(check bool)
    "review B preserves the later arm" true
    (has_constructor_arm "a" illegal_pattern);
  Alcotest.(check bool)
    "review B preserves the following declaration" true
    (find_following_definition illegal_pattern);
  (match
     Surface_parse.parse_string ~file:"review-b.jac"
       {|match x {
  | quote { jqd { (lit 1) (lit 2) } } -> 0
  | A -> 1
}
after = 7
|}
   with
  | Error diagnostics ->
      Alcotest.(check int) "strict review B emits no E0114" 0 (count_diagnostic "E0114" diagnostics)
  | Ok _ -> Alcotest.fail "strict parsing accepted quote in pattern position");
  let multiple =
    Surface_parse.recover_string ~file:"multiple-raw.jac"
      "broken = @\njqd { (lit 1) }\njqd { (lit 2) }\nafter = 7\n"
  in
  Alcotest.(check (list int))
    "multiple raw tops survive earlier ordinary damage" [ 1; 2 ] (raw_top_ints multiple);
  Alcotest.(check bool)
    "multiple raw tops preserve the final declaration" true
    (find_following_definition multiple)

let test_raw_candidate_eof_fallback () =
  let recover source = Surface_parse.recover_string ~file:"raw-fallback.jac" source in
  let strict_diagnostics source =
    match Surface_parse.parse_string ~file:"raw-fallback.jac" source with
    | Error diagnostics -> diagnostics
    | Ok _ -> Alcotest.failf "strict parsing accepted malformed raw source %S" source
  in
  let top_source = "jqd { (lit 1 }\nafter = 7\n" in
  let top = recover top_source in
  Alcotest.(check int) "top fallback reports one Reader diagnostic" 1 (count_code "E0106" top);
  Alcotest.(check int) "top fallback does not report E1221" 0 (count_code "E1221" top);
  Alcotest.(check bool)
    "top fallback preserves the following definition" true (find_following_definition top);
  (match
     List.find_opt (fun diagnostic -> Diag.code_or_uncoded diagnostic = "E0106") top.diagnostics
   with
  | Some diagnostic when Option.is_some (Diag.span diagnostic) ->
      let span = Option.get (Diag.span diagnostic) in
      Alcotest.(check string)
        "top fallback maps the Reader span" "raw-fallback.jac:1:7-14" (Span.to_string span)
  | _ -> Alcotest.fail "top fallback Reader diagnostic had no mapped span");
  let top_strict = strict_diagnostics top_source in
  Alcotest.(check int)
    "strict top fallback reports one Reader diagnostic" 1
    (count_diagnostic "E0106" top_strict);
  Alcotest.(check int)
    "strict top fallback does not report E1221" 0
    (count_diagnostic "E1221" top_strict);
  let handler =
    recover
      {|handle body() {
  | return x -> quote { jqd { (lit 1 } }
  | abort() resume _ -> 0
}
after = 7
|}
  in
  Alcotest.(check int) "quote fallback reports one Reader diagnostic" 1 (count_code "E0106" handler);
  Alcotest.(check int) "quote fallback does not duplicate E1221" 0 (count_code "E1221" handler);
  Alcotest.(check bool)
    "quote fallback preserves the following handler clause" true (find_operation "abort" handler);
  Alcotest.(check bool)
    "quote fallback preserves the following top" true
    (find_following_definition handler);
  let illegal = recover {|match x {
  | quote { jqd { (lit 1 } } -> 0
  | A -> 1
}
after = 7
|} in
  Alcotest.(check int)
    "illegal fallback emits no Reader diagnostic" 0
    (count_reader_diagnostics illegal.diagnostics);
  Alcotest.(check bool)
    "illegal fallback preserves the later arm" true (has_constructor_arm "a" illegal);
  Alcotest.(check bool)
    "illegal fallback preserves the following top" true
    (find_following_definition illegal);
  let illegal_strict =
    strict_diagnostics {|match x {
  | quote { jqd { (lit 1 } } -> 0
  | A -> 1
}
after = 7
|}
  in
  Alcotest.(check int)
    "strict illegal fallback emits no Reader diagnostic" 0
    (count_reader_diagnostics illegal_strict);
  let unterminated_string = recover "jqd { (lit \"unterminated }\nafter = 7\n" in
  Alcotest.(check int)
    "string fallback reports one Reader diagnostic" 1
    (count_code "E0102" unterminated_string);
  Alcotest.(check int)
    "string fallback does not report E1221" 0
    (count_code "E1221" unterminated_string);
  Alcotest.(check bool)
    "string fallback preserves the following definition" true
    (find_following_definition unterminated_string);
  let check_balanced_string_fallback label string_literal =
    let source =
      Printf.sprintf "jqd { (mystery (lit %s) }; jqd { (lit 8) }; after = 7" string_literal
    in
    let recovered = recover source in
    Alcotest.(check int)
      (label ^ " reports one mapped Reader E0106")
      1 (count_code "E0106" recovered);
    Alcotest.(check int)
      (label ^ " reports no unterminated string diagnostic")
      0 (count_code "E1213" recovered);
    Alcotest.(check int)
      (label ^ " reports no string escape diagnostic")
      0 (count_code "E1214" recovered);
    Alcotest.(check (list int))
      (label ^ " preserves the later raw top")
      [ 8 ] (raw_top_ints recovered);
    Alcotest.(check bool)
      (label ^ " preserves the following definition")
      true
      (find_following_definition recovered);
    recovered
  in
  let reproduction = check_balanced_string_fallback "balanced brace string" {|"}"|} in
  (match
     List.find_opt
       (fun diagnostic -> Diag.code_or_uncoded diagnostic = "E0106")
       reproduction.diagnostics
   with
  | Some diagnostic when Option.is_some (Diag.span diagnostic) ->
      let span = Option.get (Diag.span diagnostic) in
      Alcotest.(check string)
        "balanced brace string maps the Reader span" "raw-fallback.jac:1:7-26" (Span.to_string span)
  | _ -> Alcotest.fail "balanced brace string Reader diagnostic had no mapped span");
  ignore (check_balanced_string_fallback "multiple balanced braces" {|"}}}"|});
  ignore (check_balanced_string_fallback "escaped quote and brace text" {|"escaped \" } brace }"|});
  let balanced = recover "jqd { (mystery \"}\" ; } in a comment\n (nested foo)) }\nafter = 7\n" in
  Alcotest.(check int)
    "balanced raw ignores fallback candidates" 0
    (List.length balanced.diagnostics);
  Alcotest.(check bool) "balanced raw uses the true outer close" true (has_raw_top balanced);
  Alcotest.(check bool)
    "balanced raw preserves the following definition" true
    (find_following_definition balanced);
  let eof_source = "jqd { (lit 1)" in
  let eof_first = recover eof_source in
  let eof_second = recover eof_source in
  Alcotest.(check int) "no-fallback EOF reports one E1221" 1 (count_code "E1221" eof_first);
  Alcotest.(check (list string))
    "no-fallback EOF diagnostics are deterministic"
    (List.map Diag.to_string eof_first.diagnostics)
    (List.map Diag.to_string eof_second.diagnostics)

let test_unclosed_raw_always_reports_missing_brace () =
  let cases =
    [
      ("invalid scalar", "jqd { (lit @", [ "E0101"; "E1221" ]);
      ("unclosed bootstrap form", "jqd { (lit", [ "E0106"; "E1221" ]);
      ("valid payload", "jqd { (lit 1)", [ "E1221" ]);
    ]
  in
  let nondecreasing_offsets diagnostics =
    let offsets =
      List.map
        (fun diagnostic ->
          match Diag.span diagnostic with
          | Some span -> span.Span.start_pos.offset
          | None -> max_int)
        diagnostics
    in
    List.for_all2 ( <= ) offsets (List.tl offsets @ [ max_int ])
  in
  List.iter
    (fun (label, source, expected) ->
      let recovered = Surface_parse.recover_string ~file:"unclosed-raw.jac" source in
      Alcotest.(check (list string))
        (label ^ " recovery codes") expected (diagnostic_codes recovered);
      Alcotest.(check int) (label ^ " exactly one missing brace") 1 (count_code "E1221" recovered);
      Alcotest.(check bool)
        (label ^ " recovery diagnostics are source ordered")
        true
        (nondecreasing_offsets recovered.diagnostics);
      match Surface_parse.parse_string ~file:"unclosed-raw.jac" source with
      | Error diagnostics ->
          Alcotest.(check (list string))
            (label ^ " strict codes") expected
            (List.map (fun diagnostic -> Diag.code_or_uncoded diagnostic) diagnostics);
          Alcotest.(check int)
            (label ^ " strict exactly one missing brace")
            1
            (count_diagnostic "E1221" diagnostics);
          Alcotest.(check bool)
            (label ^ " strict diagnostics are source ordered")
            true
            (nondecreasing_offsets diagnostics)
      | Ok _ -> Alcotest.failf "strict parsing accepted %s" label)
    cases

let test_raw_strict_and_recovering_success () =
  let source = "jqd { (lit 1) }\nquote { jqd { (mystery foo) } }\n" in
  let check_items label items =
    match items with
    | [
     { Surface_ast.it = RawTop top_form; _ };
     { Surface_ast.it = TopExpr { it = Quote (Raw quote_form); _ }; _ };
    ] ->
        Alcotest.(check (option string))
          (label ^ " top payload span") (Some "raw-success.jac:1:7-14")
          (Option.map Span.to_string (Meta.span top_form.Form.meta));
        Alcotest.(check (option string))
          (label ^ " quote payload span") (Some "raw-success.jac:2:15-28")
          (Option.map Span.to_string (Meta.span quote_form.Form.meta))
    | _ -> Alcotest.failf "%s produced the wrong raw tree" label
  in
  let recovered = Surface_parse.recover_string ~file:"raw-success.jac" source in
  Alcotest.(check int) "recovering valid raw diagnostics" 0 (List.length recovered.diagnostics);
  check_items "recovering" recovered.items;
  match Surface_parse.parse_string ~file:"raw-success.jac" source with
  | Ok items -> check_items "strict" items
  | Error diagnostics -> fail_diags "strict valid raw" diagnostics

let test_handler_print_hash_round_trip () =
  let hash = Hash.of_string "surface-round-trip-op" in
  let expression =
    bootstrap
      (Printf.sprintf "(handle (lit 1) (ret (pvar x) (var x)) (opclause #%s () unused (lit 0)))"
         (Hash.to_hex hash))
  in
  let expression =
    match expression.Kernel.it with
    | Kernel.Handle ({ ops = [ op ]; _ } as handler) ->
        {
          expression with
          Kernel.it = Kernel.Handle { handler with ops = [ { op with resume = "_" } ] };
        }
    | _ -> Alcotest.fail "handler hash fixture had the wrong shape"
  in
  let printed = check_print_round_trip "handler" expression in
  Alcotest.(check bool)
    "atomic handler stays one body/clause brace group" true
    (String.starts_with ~prefix:"handle 1 {" printed)

let suite =
  [
    Alcotest.test_case "handler clauses and bootstrap parity" `Quick
      test_handler_equivalence_and_clause_shapes;
    Alcotest.test_case "D35 body boundary" `Quick test_d35_wrapped_and_unwrapped_bodies;
    Alcotest.test_case "handler recovery" `Quick test_handler_recovery_and_return_cardinality;
    Alcotest.test_case "missing quote brace recovery" `Quick test_missing_quote_brace_recovery;
    Alcotest.test_case "handler spans" `Quick test_handler_spans_and_provenance;
    Alcotest.test_case "quote staging and resolution" `Quick test_quote_unquote_and_resolution;
    Alcotest.test_case "double-unquote depth and dependencies" `Quick
      test_double_unquote_depth_and_dependencies;
    Alcotest.test_case "quoted namespace identity and printing" `Quick
      test_quoted_namespace_identity_and_printing;
    Alcotest.test_case "quoted namespace eval resolution" `Quick
      test_quoted_namespace_eval_resolution;
    Alcotest.test_case "quoted namespace depth and raw markers" `Quick
      test_quoted_namespace_depth_and_raw_markers;
    Alcotest.test_case "raw quote inversion" `Quick test_raw_jqd_inversion_and_round_trips;
    Alcotest.test_case "raw recovery and context" `Quick test_raw_recovery_and_illegal_context;
    Alcotest.test_case "raw parser-owned boundaries" `Quick
      test_raw_parser_owned_recovery_boundaries;
    Alcotest.test_case "raw candidate EOF fallback" `Quick test_raw_candidate_eof_fallback;
    Alcotest.test_case "unclosed raw missing brace" `Quick
      test_unclosed_raw_always_reports_missing_brace;
    Alcotest.test_case "raw strict and recovering success" `Quick
      test_raw_strict_and_recovering_success;
    Alcotest.test_case "handler print/hash round trip" `Quick test_handler_print_hash_round_trip;
  ]
