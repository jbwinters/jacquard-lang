open Jacquard

let fail_diags label diagnostics =
  Alcotest.failf "%s: %s" label (String.concat "; " (List.map Diag.to_string diagnostics))

let fresh_root =
  let serial = ref 0 in
  fun () ->
    incr serial;
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "jacquard-named-call-%d-%d" (Unix.getpid ()) !serial)

let open_store root =
  match Store.open_store root with
  | Ok store -> store
  | Error diagnostics -> fail_diags "store" diagnostics

let parse source =
  match Surface_parse.parse_string ~file:"named-calls.jac" source with
  | Ok tops -> tops
  | Error diagnostics -> fail_diags "parse" diagnostics

let lower source =
  match Surface_lower.lower_tops (parse source) with
  | Ok tops -> tops
  | Error diagnostics -> fail_diags "lower" diagnostics

let resolve_top store top =
  match Resolve.resolve (Store.names_view store) top with
  | Ok top -> top
  | Error diagnostics -> fail_diags "resolve" diagnostics

let install store source =
  List.map
    (fun top ->
      let top = resolve_top store top in
      match top with
      | Kernel.Decl declaration -> (
          match Store.put_decl store declaration with
          | Ok _ -> top
          | Error diagnostics -> fail_diags "put" diagnostics)
      | Kernel.Expr _ -> top)
    (lower source)

let make_prelude_checker () =
  let store = open_store (fresh_root ()) in
  (match Prelude.load ~dir:"../prelude" store with
  | Ok _ -> ()
  | Error diagnostics -> fail_diags "prelude" diagnostics);
  let checker =
    match Check.make_ctx store with
    | Ok checker -> checker
    | Error diagnostics -> fail_diags "checker" diagnostics
  in
  (match Prelude.builtin_signatures store with
  | Ok signatures -> Check.register_builtin_signatures checker signatures
  | Error diagnostics -> fail_diags "builtin signatures" diagnostics);
  (store, checker)

let resolve_expression store source =
  match lower source with
  | [ Kernel.Expr expression ] -> (
      match Resolve.resolve_expr (Store.names_view store) expression with
      | Ok expression -> expression
      | Error diagnostics -> fail_diags "resolve expression" diagnostics)
  | tops -> Alcotest.failf "expected one expression, got %d tops" (List.length tops)

let check_expression checker store source =
  let expression = resolve_expression store source in
  match Check.check_top checker (Kernel.Expr expression) with
  | Ok checked -> checked
  | Error diagnostics -> fail_diags "check expression" diagnostics

let warnings code checked =
  List.filter (fun diagnostic -> Diag.code diagnostic = Some code) checked.Check.warnings

let resolution_diagnostics store source =
  match lower source with
  | [ Kernel.Expr expression ] -> (
      match Resolve.resolve_expr (Store.names_view store) expression with
      | Ok _ -> Alcotest.failf "expected resolution failure for %S" source
      | Error diagnostics -> diagnostics)
  | [ Kernel.Decl declaration ] -> (
      match Resolve.resolve_decl (Store.names_view store) declaration with
      | Ok _ -> Alcotest.failf "expected declaration resolution failure for %S" source
      | Error diagnostics -> diagnostics)
  | tops -> Alcotest.failf "expected one top, got %d" (List.length tops)

let only_diagnostic store source code excerpt =
  match resolution_diagnostics store source with
  | [ diagnostic ] ->
      Alcotest.(check string) "diagnostic code" code (Diag.code_or_uncoded diagnostic);
      let span =
        match Diag.span diagnostic with
        | Some span -> span
        | None -> Alcotest.fail "diagnostic has no span"
      in
      let actual =
        String.sub source span.Span.start_pos.offset (span.end_pos.offset - span.start_pos.offset)
      in
      Alcotest.(check string) "diagnostic span" excerpt actual
  | diagnostics -> Alcotest.failf "expected one diagnostic, got %d" (List.length diagnostics)

let expression_hash expression =
  match Canon.hash_expr expression with
  | Ok hash -> hash
  | Error diagnostics -> fail_diags "hash" diagnostics

let print_expression expression =
  match Surface_print.print_top (Kernel.Expr expression) with
  | Ok text -> text
  | Error diagnostics -> fail_diags "print" diagnostics

let int_literal expression =
  match expression.Kernel.it with
  | Kernel.Lit (Kernel.LInt value) -> value
  | _ -> Alcotest.fail "int"

let rec named_let_bindings acc expression =
  match expression.Kernel.it with
  | Kernel.Let { isrec = false; binder = { it = Kernel.PVar name; _ }; value; body }
    when Meta.surface_generated expression.meta = Some "named-call-reordered"
         || Meta.surface_generated expression.meta = Some "named-call-argument-let" ->
      named_let_bindings ((name, int_literal value) :: acc) body
  | Kernel.App (_, arguments) -> (List.rev acc, arguments)
  | _ -> Alcotest.fail "expected generated named-call lets ending in App"

let test_parse_print_quote_and_recovery () =
  let source =
    "choose(-- first label\n\
     left: first, right: second) = (first, second)\n\n\
     choose(-- first call label\n\
     right: 2, left: 1)\n"
  in
  let recovered = Surface_parse.recover_string ~file:"named-comments.jac" source in
  let formatted =
    match Surface_print.print_recovered recovered with
    | Ok text -> text
    | Error diagnostics -> fail_diags "format" diagnostics
  in
  Alcotest.(check int)
    "parameter comment once" 1
    (Test_surface_trivia.count_occurrences formatted "-- first label");
  Alcotest.(check int)
    "argument comment once" 1
    (Test_surface_trivia.count_occurrences formatted "-- first call label");
  let formatted_again =
    match
      Surface_print.print_recovered
        (Surface_parse.recover_string ~file:"named-comments.jac" formatted)
    with
    | Ok text -> text
    | Error diagnostics -> fail_diags "format twice" diagnostics
  in
  Alcotest.(check string) "formatter idempotent" formatted formatted_again;
  let narrow_source = "combine(important-left: first-value, important-right: second-value)\n" in
  let narrow =
    match
      Surface_print.print_recovered ~width:30
        (Surface_parse.recover_string ~file:"named-width.jac" narrow_source)
    with
    | Ok text -> text
    | Error diagnostics -> fail_diags "narrow format" diagnostics
  in
  Alcotest.(check bool)
    "named call wraps at narrow width" true
    (Test_surface_trivia.count_occurrences narrow "\n" > 1);
  let narrow_again =
    match
      Surface_print.print_recovered ~width:30
        (Surface_parse.recover_string ~file:"named-width.jac" narrow)
    with
    | Ok text -> text
    | Error diagnostics -> fail_diags "narrow format twice" diagnostics
  in
  Alcotest.(check string) "narrow formatter idempotent" narrow narrow_again;
  List.iter
    (fun source ->
      match Surface_parse.parse_string ~file:"bad-order.jac" source with
      | Error diagnostics ->
          Alcotest.(check bool)
            source true
            (List.exists (fun diagnostic -> Diag.code diagnostic = Some "E1220") diagnostics)
      | Ok _ -> Alcotest.failf "expected ordering parse error for %S" source)
    [
      "choose(left: 1, 2)";
      "choose(left: first, second) = first";
      "once effect E a where { op : (left: a, a) -> a }";
    ];
  List.iter
    (fun source ->
      match Surface_lower.lower_tops (parse source) with
      | Error [ diagnostic ] ->
          Alcotest.(check string) "quote code" "E1238" (Diag.code_or_uncoded diagnostic)
      | Error diagnostics -> fail_diags "quoted named call" diagnostics
      | Ok _ -> Alcotest.failf "quoted named call lowered: %s" source)
    [ "quote { choose(left: 1) }"; "quote { unquote(choose(left: 1)) }" ];
  ignore (lower "quote { choose(1) }")

let test_direct_calls_hashes_and_source_order () =
  let store = open_store (fresh_root ()) in
  ignore (install store "choose(left: first, right: second) = (first, second)\n");
  let reordered = resolve_expression store "choose(right: 2, left: 1)" in
  let bindings, final_arguments = named_let_bindings [] reordered in
  Alcotest.(check (list int)) "source evaluation order" [ 2; 1 ] (List.map snd bindings);
  let final_names =
    List.map
      (fun argument ->
        match argument.Kernel.it with
        | Kernel.Var name -> name
        | _ -> Alcotest.fail "final named call argument is not a temporary")
      final_arguments
  in
  Alcotest.(check (list string))
    "declaration-order application"
    (List.rev (List.map fst bindings))
    final_names;
  Alcotest.(check string)
    "printer restores source call" "choose(right: 2, left: 1)" (print_expression reordered);
  let bootstrap = Printer.print_all [ Kernel.expr_to_form reordered ] in
  Alcotest.(check bool)
    "generated temporaries export as bootstrap symbols" true
    (String.length bootstrap > 0);
  let named = resolve_expression store "choose(left: 1, right: 2)" in
  let positional = resolve_expression store "choose(1, 2)" in
  Alcotest.(check bool)
    "declaration-order hash twin" true
    (Hash.equal (expression_hash named) (expression_hash positional));
  let explicit_lets =
    resolve_expression store
      "{ let right-value = 2; let left-value = 1; choose(left-value, right-value) }"
  in
  Alcotest.(check bool)
    "reordered explicit-let hash twin" true
    (Hash.equal (expression_hash reordered) (expression_hash explicit_lets));
  ignore (install store "resize(img, scale: ratio) = (ratio, img)\n");
  let mixed = resolve_expression store "resize(1, scale: 2)" in
  Alcotest.(check string)
    "positional prefix and labeled suffix" "resize(1, scale: 2)" (print_expression mixed);
  Alcotest.(check bool)
    "mixed call hash twin" true
    (Hash.equal (expression_hash mixed) (expression_hash (resolve_expression store "resize(1, 2)")));
  match lower "first(value: x) = second(value: x)\nsecond(value: y) = first(value: y)\n" with
  | [ Kernel.Decl declaration ] -> (
      match Resolve.resolve_decl Resolve.empty_names declaration with
      | Ok { Kernel.it = Kernel.DefTerm [ first; second ]; _ } ->
          let callee binding =
            match binding.Kernel.value.it with
            | Kernel.Lam (_, { it = Kernel.App ({ it = Kernel.GroupRef index; _ }, _); _ }) -> index
            | _ -> Alcotest.fail "same-SCC named call did not become GroupRef App"
          in
          Alcotest.(check int) "first to second" 1 (callee first);
          Alcotest.(check int) "second to first" 0 (callee second)
      | Ok _ -> Alcotest.fail "unexpected same-SCC declaration"
      | Error diagnostics -> fail_diags "same SCC" diagnostics)
  | _ -> Alcotest.fail "mutual fixture did not form one declaration"

let test_constructor_and_operation_calls () =
  let store = open_store (fresh_root ()) in
  ignore (install store "type Packet a = | Packet(left: a, right: a)\n");
  let packet = resolve_expression store "Packet(right: 2, left: 1)" in
  Alcotest.(check string)
    "constructor labels print" "Packet(right: 2, left: 1)" (print_expression packet);
  ignore (install store "type Envelope a = | Envelope(a, payload: a)\n");
  let envelope = resolve_expression store "Envelope(1, payload: 2)" in
  Alcotest.(check string)
    "constructor positional prefix" "Envelope(1, payload: 2)" (print_expression envelope);
  ignore (install store "once effect Sending a where { send : (path: a, body: a) -> a }\n");
  let operation = resolve_expression store "`op:send`(body: 2, path: 1)" in
  Alcotest.(check string)
    "operation labels print" "`op:send`(body: 2, path: 1)" (print_expression operation);
  ignore (install store "once effect Appending a where { append : (a, suffix: a) -> a }\n");
  let operation_prefix = resolve_expression store "`op:append`(1, suffix: 2)" in
  Alcotest.(check string)
    "operation positional prefix" "`op:append`(1, suffix: 2)"
    (print_expression operation_prefix)

let test_fail_closed_diagnostics () =
  let store = open_store (fresh_root ()) in
  ignore (install store "choose(left: first, right: second) = (first, second)\nplain(x) = x\n");
  only_diagnostic store "plain(value: 1)" "E0309" "plain(value: 1)";
  only_diagnostic store "choose(left: 1, wrong: 2)" "E0310" "wrong: 2";
  only_diagnostic store "choose(left: 1, left: 2)" "E0311" "left: 2";
  only_diagnostic store "choose(1, left: 2)" "E0311" "left: 2";
  only_diagnostic store "choose(left: 1)" "E0312" "choose(left: 1)";
  only_diagnostic store "bad(label: (x, y)) = x" "E0313" "label: (x, y)";
  only_diagnostic store "bad(value: x, value: y) = x" "E0313" "value: y";
  only_diagnostic store "{ let f = fn (x) -> x; f(value: 1) }" "E0309" "f(value: 1)";
  ignore (install store "type Ambiguous a = | Ambiguous(value: a, value: a)\n");
  only_diagnostic store "Ambiguous(value: 1, value: 2)" "E0314" "Ambiguous(value: 1, value: 2)";
  ignore (install store "type MixedFields a = | MixedFields(left: a, a)\n");
  only_diagnostic store "MixedFields(left: 1, other: 2)" "E0314" "MixedFields(left: 1, other: 2)"

let resolved_declaration store source =
  match lower source with
  | [ Kernel.Decl declaration ] -> (
      match Resolve.resolve_decl (Store.names_view store) declaration with
      | Ok declaration -> declaration
      | Error diagnostics -> fail_diags "resolve declaration" diagnostics)
  | tops -> Alcotest.failf "expected one declaration, got %d" (List.length tops)

let test_store_identity_reopen_and_conflict () =
  let root = fresh_root () in
  let store = open_store root in
  let original =
    resolved_declaration store "choose(left: first, right: second) = (first, second)"
  in
  let hashes =
    match Store.put_decl store original with
    | Ok hashes -> hashes
    | Error diagnostics -> fail_diags "put original" diagnostics
  in
  let member = List.assoc "choose" hashes.Canon.named in
  Alcotest.(check (option (list (option string))))
    "ABI installed"
    (Some [ Some "left"; Some "right" ])
    ((Store.names_view store).Resolve.callable_abi member);
  (match Store.rename store ~old_name:"choose" ~new_name:"select" () with
  | Ok () -> ()
  | Error diagnostics -> fail_diags "rename" diagnostics);
  let reopened = open_store root in
  Alcotest.(check (option (list (option string))))
    "ABI survives rename and reopen"
    (Some [ Some "left"; Some "right" ])
    ((Store.names_view reopened).Resolve.callable_abi member);
  let renamed_binders = resolved_declaration reopened "select(left: x, right: y) = (x, y)" in
  (match Store.put_decl reopened renamed_binders with
  | Ok renamed_hashes ->
      Alcotest.(check bool)
        "binder rename keeps member hash" true
        (Hash.equal member (List.assoc "select" renamed_hashes.Canon.named))
  | Error diagnostics -> fail_diags "binder rename" diagnostics);
  let relabeled = resolved_declaration reopened "select(first: x, second: y) = (x, y)" in
  (match Store.put_decl reopened relabeled with
  | Error [ diagnostic ] ->
      Alcotest.(check string) "ABI conflict" "E0612" (Diag.code_or_uncoded diagnostic)
  | Error diagnostics -> fail_diags "ABI conflict" diagnostics
  | Ok _ -> Alcotest.fail "conflicting relabel replaced a hash-bound ABI");
  Alcotest.(check (option (list (option string))))
    "conflict is transactional"
    (Some [ Some "left"; Some "right" ])
    ((Store.names_view reopened).Resolve.callable_abi member)

let test_checker_review_warnings_and_recovery_names () =
  let store, checker = make_prelude_checker () in
  ignore
    (install store
       "choose-flag(flag: value) = value\n\
        sum-pair : (Int, Int) ->{} Int\n\
        sum-pair(left: x, right: y) = add(x, y)\n\
        later-pair : (Int, Int, Text, Text) ->{} Int\n\
        later-pair(first, second, left: x, right: y) = add(first, second)\n\
        mixed : (Int, Text) ->{} Int\n\
        mixed(number: n, text: t) = n\n\
        plain-flag : (Bool) ->{} Int\n\
        plain-flag(value) = if value then 1 else 0\n\
        plain-pair : (Int, Int) ->{} Int\n\
        plain-pair(x, y) = sub(x, y)\n\
        type Mode = | Live | DryRun\n\
        deploy(mode: value) = match value { | Live -> 1 | DryRun -> 0 }\n");
  let bool_warning = check_expression checker store "choose-flag(True)" |> warnings "W1206" in
  (match bool_warning with
  | [ warning ] ->
      Alcotest.(check string)
        "boolean warning span" "True"
        (match Diag.span warning with
        | Some span ->
            String.sub "choose-flag(True)" span.start_pos.offset
              (span.end_pos.offset - span.start_pos.offset)
        | None -> Alcotest.fail "boolean warning has no span");
      Alcotest.(check bool)
        "boolean remediation names sum type" true
        (Test_surface_trivia.count_occurrences (Diag.next_step warning) "Mode = | Live | DryRun" = 1)
  | warnings -> Alcotest.failf "expected one W1206, got %d" (List.length warnings));
  let repeated_warning = check_expression checker store "sum-pair(1, 2)" |> warnings "W1207" in
  (match repeated_warning with
  | [ warning ] ->
      Alcotest.(check string)
        "same-type warning cause"
        "Parameters 1 through 2 all have type int, so a reordered call can still typecheck."
        (Diag.cause warning)
  | warnings -> Alcotest.failf "expected one W1207, got %d" (List.length warnings));
  let later_warning =
    check_expression checker store "later-pair(1, 2, \"left\", \"right\")" |> warnings "W1207"
  in
  (match later_warning with
  | [ warning ] ->
      Alcotest.(check string)
        "later labeled same-type run"
        "Parameters 3 through 4 all have type text, so a reordered call can still typecheck."
        (Diag.cause warning)
  | warnings -> Alcotest.failf "expected one later W1207, got %d" (List.length warnings));
  List.iter
    (fun source ->
      let checked = check_expression checker store source in
      Alcotest.(check int) (source ^ " W1206") 0 (List.length (warnings "W1206" checked));
      Alcotest.(check int) (source ^ " W1207") 0 (List.length (warnings "W1207" checked)))
    [
      "choose-flag(flag: True)";
      "{ let flag = True; choose-flag(flag) }";
      "sum-pair(left: 1, right: 2)";
      "mixed(1, \"purpose\")";
      "plain-flag(True)";
      "plain-pair(1, 2)";
      "deploy(Live)";
    ];
  let recovered =
    Surface_parse.recover_string ~file:"analysis-named.jac"
      "local-pair(left: x, right: y) = (x, y)\nlocal-pair(right: 2, left: 1)\n"
  in
  let report = Surface_check.analyze ~names:(Store.names_view store) checker recovered in
  Alcotest.(check bool)
    "recovery carries the local named-call ABI" true
    (not
       (List.exists
          (fun diagnostic ->
            List.mem (Diag.code_or_uncoded diagnostic) [ "E0309"; "E0310"; "E0311"; "E0312" ])
          report.diagnostics))

let suite =
  [
    Alcotest.test_case "parse print quote recovery" `Quick test_parse_print_quote_and_recovery;
    Alcotest.test_case "direct hashes and source order" `Quick
      test_direct_calls_hashes_and_source_order;
    Alcotest.test_case "constructors and operations" `Quick test_constructor_and_operation_calls;
    Alcotest.test_case "fail-closed diagnostics" `Quick test_fail_closed_diagnostics;
    Alcotest.test_case "store identity reopen conflict" `Quick
      test_store_identity_reopen_and_conflict;
    Alcotest.test_case "checker warnings and recovery names" `Quick
      test_checker_review_warnings_and_recovery_names;
  ]
