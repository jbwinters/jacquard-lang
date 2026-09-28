open Jacquard

(* SX.28b (DES.4 Phase 2): the nominal field update `Ctor(value with label: e, ...)`. It lowers to one
   application tagged `field-update`; resolution, which knows the constructor's fields, elaborates it
   to the explicit let-and-match twin. The CLI behaviour (interpreter and native parity, evaluation
   order, hashes, the formatter, diagnostics) is pinned by test/cli/surface-field-update.t. *)

let fail_diags label diagnostics =
  Alcotest.failf "%s: %s" label (String.concat "; " (List.map Diag.to_string diagnostics))

let fresh_root =
  let serial = ref 0 in
  fun () ->
    incr serial;
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "jacquard-field-update-%d-%d" (Unix.getpid ()) !serial)

let open_store root =
  match Store.open_store root with
  | Ok store -> store
  | Error diagnostics -> fail_diags "store" diagnostics

let parse source =
  match Surface_parse.parse_string ~file:"field-update.jac" source with
  | Ok tops -> tops
  | Error diagnostics -> fail_diags "parse" diagnostics

let lower source =
  match Surface_lower.lower_tops (parse source) with
  | Ok tops -> tops
  | Error diagnostics -> fail_diags "lower" diagnostics

let install store source =
  List.iter
    (fun top ->
      match Resolve.resolve (Store.names_view store) top with
      | Ok (Kernel.Decl declaration) -> (
          match Store.put_decl store declaration with
          | Ok _ -> ()
          | Error diagnostics -> fail_diags "put" diagnostics)
      | Ok (Kernel.Expr _) -> ()
      | Error diagnostics -> fail_diags "resolve declaration" diagnostics)
    (lower source)

let lowered_expression source =
  match lower source with
  | [ Kernel.Expr expression ] -> expression
  | tops -> Alcotest.failf "expected one expression, got %d tops" (List.length tops)

let resolve_expression store source =
  match Resolve.resolve_expr (Store.names_view store) (lowered_expression source) with
  | Ok expression -> expression
  | Error diagnostics -> fail_diags ("resolve " ^ source) diagnostics

let expression_hash expression =
  match Canon.hash_expr expression with
  | Ok hash -> hash
  | Error diagnostics -> fail_diags "hash" diagnostics

let print_expression expression =
  match Surface_print.print_top (Kernel.Expr expression) with
  | Ok text -> text
  | Error diagnostics -> fail_diags "print" diagnostics

let format ?width source =
  match
    Surface_print.print_recovered ?width (Surface_parse.recover_string ~file:"fmt.jac" source)
  with
  | Ok text -> text
  | Error diagnostics -> fail_diags "format" diagnostics

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

let snapshot_type =
  "type Snap = | Snap(cells: Int, reverse: Int, cache: Int, hits: Int, computed: Int)\n\
   s-value = Snap(1, 2, 3, 4, 5)\n"

let test_parse_lower_and_print () =
  (match parse "Snap(s with cells: 1, cache: 2)" with
  | [ { it = Surface_ast.TopExpr { it = Surface_ast.Call (_, arguments); meta }; _ } ] ->
      Alcotest.(check (option string))
        "the call is a field update" (Some "field-update") (Meta.surface_form meta);
      Alcotest.(check (list (option string)))
        "one unlabeled value, then the labeled fields"
        [ None; Some "cells"; Some "cache" ]
        (List.map
           (fun (argument : Surface_ast.expr) -> Meta.surface_call_label argument.meta)
           arguments)
  | _ -> Alcotest.fail "expected one call");
  (match lowered_expression "Snap(s with cells: 1, cache: 2)" with
  | { it = Kernel.App (_, [ _; _; _ ]); meta } ->
      Alcotest.(check (option string))
        "lowering keeps one tagged application" (Some "field-update") (Meta.surface_form meta)
  | _ -> Alcotest.fail "expected one application");
  List.iter
    (fun source ->
      Alcotest.(check string)
        ("prints back: " ^ source) source
        (print_expression (lowered_expression source)))
    [
      "Snap(s with cells: 1)";
      "Snap(s with cache: 2, cells: 1)";
      "Snap(s |> f with cells: 1)";
      "Snap(Snap(s with hits: 1) with computed: 2)";
      "f(x: Snap(s with hits: 1))";
      "Snap(s with hits: 1) |> g";
    ];
  (* wide and narrow layouts are fixed points; a setter call is never rewritten *)
  let source =
    "long(snapshot) = Snap(snapshot with cells: list.append(snapshot-cells, [1, 2, 3]), cache: \
     cons(4, snapshot-cache), computed: add(snapshot-computed, 1))\n\
     one(s) = snap.with-hits(s, hits: 2)\n"
  in
  let formatted = format source in
  Alcotest.(check bool)
    "wrapped form opens with the value" true
    (Test_surface_trivia.count_occurrences formatted "Snap(snapshot with\n" = 1);
  Alcotest.(check bool)
    "setter kept" true
    (Test_surface_trivia.count_occurrences formatted "snap.with-hits(s, hits: 2)" = 1);
  Alcotest.(check string) "formatter idempotent" formatted (format formatted);
  let narrow = format ~width:30 "Snap(s with cells: first-value, cache: second-value)\n" in
  Alcotest.(check string) "narrow formatter idempotent" narrow (format ~width:30 narrow);
  let with_comments = "Snap(\n  s with -- keep the rest\n  hits: 1,\n  computed: 0,\n)\n" in
  let commented = format with_comments in
  Alcotest.(check int)
    "comment kept once" 1
    (Test_surface_trivia.count_occurrences commented "-- keep the rest");
  Alcotest.(check string) "commented form idempotent" commented (format commented)

let parse_codes source =
  match Surface_parse.parse_string ~file:"bad.jac" source with
  | Error diagnostics -> List.map Diag.code_or_uncoded diagnostics
  | Ok _ -> []

let test_syntax_errors () =
  List.iter
    (fun (label, source) -> Alcotest.(check (list string)) label [ "E1220" ] (parse_codes source))
    [
      ("second value before with", "Snap(s, t with cells: 1)");
      ("labeled value before with", "Snap(cells: 1 with hits: 2)");
      ("positional value after with", "Snap(s with cells: 1, 2)");
      ("no fields", "Snap(s with)");
      ("second with", "Snap(s with cells: 1 with hits: 2)");
      ("pipe right side", "t |> Snap(s with cells: 1)");
    ];
  Alcotest.(check (list string))
    "no value: the reserved word cannot start an expression" [ "E1220"; "E1220" ]
    (parse_codes "Snap(with cells: 1)");
  (match Surface_parse.parse_string ~file:"bad.jac" "Snap(s, t with cells: 1)" with
  | Error [ diagnostic ] ->
      Alcotest.(check bool)
        "the diagnostic names the form" true
        (Test_surface_trivia.count_occurrences (Diag.cause diagnostic)
           "exactly one value before `with`"
        = 1)
  | _ -> Alcotest.fail "expected one diagnostic");
  List.iter
    (fun source ->
      match Surface_lower.lower_tops (parse source) with
      | Error [ diagnostic ] ->
          Alcotest.(check string) "quoted update" "E1238" (Diag.code_or_uncoded diagnostic);
          Alcotest.(check bool)
            "the refusal names the update" true
            (Test_surface_trivia.count_occurrences (Diag.cause diagnostic) "`with` field update" = 1)
      | Error diagnostics -> fail_diags "quoted update" diagnostics
      | Ok _ -> Alcotest.failf "quoted update lowered: %s" source)
    [ "quote { Snap(s with cells: 1) }"; "quote { unquote(Snap(s with cells: 1)) }" ]

let rec let_chain acc (expression : Kernel.expr) =
  match expression.it with
  | Kernel.Let { isrec = false; binder = { it = Kernel.PVar name; _ }; value; body } ->
      let_chain ((name, value) :: acc) body
  | _ -> (List.rev acc, expression)

let test_twin_hashes_and_order () =
  let store, _ = make_prelude_checker () in
  install store snapshot_type;
  let update = resolve_expression store "Snap(s-value with cache: 30, cells: 10)" in
  let bindings, final = let_chain [] update in
  (* the value first, then each new field once, in source order *)
  Alcotest.(check (list string))
    "source-order bindings" [ "s-value"; "30"; "10" ]
    (List.map
       (fun (_, (value : Kernel.expr)) ->
         match value.it with
         | Kernel.Ref _ -> Option.value ~default:"?" (Meta.name value.meta)
         | Kernel.Lit (Kernel.LInt n) -> string_of_int n
         | _ -> "?")
       bindings);
  (match final.it with
  | Kernel.Match
      ({ it = Kernel.Var subject; _ }, [ { cbody = { it = Kernel.App (_, rebuilt); _ }; _ } ]) ->
      Alcotest.(check string) "matches the bound value" (fst (List.hd bindings)) subject;
      Alcotest.(check int) "rebuilds every field" 5 (List.length rebuilt)
  | _ -> Alcotest.fail "expected one-clause match");
  let twin =
    resolve_expression store
      "{ let v = s-value; let new-cache = 30; let new-cells = 10; match v { | Snap(cache: _, \
       cells: _, reverse: r, hits: h, computed: c) -> Snap(new-cells, r, new-cache, h, c) } }"
  in
  Alcotest.(check bool)
    "hash equals the let-and-match twin" true
    (Hash.equal (expression_hash update) (expression_hash twin));
  let positional_twin =
    resolve_expression store
      "{ let v = s-value; let a = 30; let b = 10; match v { | Snap(_, r, _, h, c) -> Snap(b, r, a, \
       h, c) } }"
  in
  Alcotest.(check bool)
    "hash equals the positional-pattern twin" true
    (Hash.equal (expression_hash update) (expression_hash positional_twin));
  let setters =
    resolve_expression store "snap.with-cells(snap.with-cache(s-value, cache: 30), cells: 10)"
  in
  Alcotest.(check bool)
    "a setter chain is a different kernel tree" false
    (Hash.equal (expression_hash update) (expression_hash setters));
  Alcotest.(check string)
    "the resolved form prints back" "Snap(s-value with cache: 30, cells: 10)"
    (print_expression update);
  (* generated binders never capture a local an updated field mentions *)
  let capturing =
    resolve_expression store
      "fn (s-value, field-update-value, field-update-new-cells) -> Snap(s-value with cells: \
       add(field-update-value, field-update-new-cells))"
  in
  let plain =
    resolve_expression store "fn (s-value, a, b) -> Snap(s-value with cells: add(a, b))"
  in
  Alcotest.(check bool)
    "capture-avoiding binders keep the twin's identity" true
    (Hash.equal (expression_hash capturing) (expression_hash plain))

let resolution_diagnostics store source =
  match Resolve.resolve_expr (Store.names_view store) (lowered_expression source) with
  | Ok _ -> Alcotest.failf "expected resolution failure for %S" source
  | Error diagnostics -> diagnostics

let only_diagnostic store source code excerpt =
  match resolution_diagnostics store source with
  | [ diagnostic ] ->
      Alcotest.(check string) (source ^ " code") code (Diag.code_or_uncoded diagnostic);
      let span =
        match Diag.span diagnostic with
        | Some span -> span
        | None -> Alcotest.fail "diagnostic has no span"
      in
      Alcotest.(check string)
        (source ^ " span") excerpt
        (String.sub source span.Span.start_pos.offset (span.end_pos.offset - span.start_pos.offset))
  | diagnostics ->
      Alcotest.failf "expected one diagnostic for %S, got %d" source (List.length diagnostics)

let test_label_and_callee_errors () =
  let store, _ = make_prelude_checker () in
  install store (snapshot_type ^ "type Plain = | Plain Int Int\nplain(x) = x\n");
  only_diagnostic store "Snap(s-value with cels: 1)" "E0305" "cels: 1";
  only_diagnostic store "Snap(s-value with cells: 1, hits: 2, cells: 3)" "E0306" "cells: 3";
  only_diagnostic store "Plain(s-value with cells: 1)" "E0307" "Plain(s-value with cells: 1)";
  only_diagnostic store "plain(s-value with cells: 1)" "E0302" "plain";
  only_diagnostic store "fn (f) -> f(s-value with cells: 1)" "E0302" "f"

let test_sum_type_refusal () =
  let store, checker = make_prelude_checker () in
  install store
    "type Shape = | Circle(name: Text, radius: Int) | Square(name: Text, side: Int)\n\
     type Mark = | Dot(size: Int) | Dash(size: Int, length: Int)\n";
  let check source = Check.check_top checker (Kernel.Expr (resolve_expression store source)) in
  (match check "Circle(Circle(\"c\", 1) with name: \"d\")" with
  | Error [ diagnostic ] ->
      Alcotest.(check string) "non-exhaustive" "E0813" (Diag.code_or_uncoded diagnostic);
      Alcotest.(check bool)
        "the message names the total setter" true
        (Test_surface_trivia.count_occurrences (Diag.cause diagnostic)
           "use `shape.with-name` for a total update"
        = 1);
      Alcotest.(check bool)
        "the next step names it too" true
        (Test_surface_trivia.count_occurrences (Diag.next_step diagnostic) "`shape.with-name`" = 1)
  | Error diagnostics -> fail_diags "sum type" diagnostics
  | Ok _ -> Alcotest.fail "a one-constructor update of a sum type was accepted");
  (* a label only some constructors carry has no setter to recommend *)
  (match check "Dash(Dash(1, 2) with length: 3)" with
  | Error [ diagnostic ] ->
      Alcotest.(check string) "non-exhaustive" "E0813" (Diag.code_or_uncoded diagnostic);
      Alcotest.(check int)
        "no setter is named" 0
        (Test_surface_trivia.count_occurrences (Diag.cause diagnostic) ".with-")
  | Error diagnostics -> fail_diags "partial label" diagnostics
  | Ok _ -> Alcotest.fail "a partial-label update of a sum type was accepted");
  (* an ordinary non-exhaustive match keeps its message *)
  match check "match Dot(1) { | Dot(size: s) -> s }" with
  | Error [ diagnostic ] ->
      Alcotest.(check int)
        "no update advice" 0
        (Test_surface_trivia.count_occurrences (Diag.cause diagnostic) "`with`")
  | Error diagnostics -> fail_diags "plain match" diagnostics
  | Ok _ -> Alcotest.fail "a non-exhaustive match was accepted"

let suite =
  [
    Alcotest.test_case "parse, lower, and print" `Quick test_parse_lower_and_print;
    Alcotest.test_case "malformed updates are E1220" `Quick test_syntax_errors;
    Alcotest.test_case "twin hashes and source order" `Quick test_twin_hashes_and_order;
    Alcotest.test_case "label and callee errors" `Quick test_label_and_callee_errors;
    Alcotest.test_case "sum-type refusal names the setter" `Quick test_sum_type_refusal;
  ]
