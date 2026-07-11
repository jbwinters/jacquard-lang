open Jacquard

let fail_diags label diagnostics =
  Alcotest.failf "%s:\n%s" label (String.concat "\n" (List.map Diag.to_string diagnostics))

let parse source =
  match Surface_parse.parse_string ~file:"types.jac" source with
  | Ok tops -> tops
  | Error diagnostics -> fail_diags "surface parse" diagnostics

let lower source =
  match Surface_lower.lower_tops (parse source) with
  | Ok tops -> tops
  | Error diagnostics -> fail_diags "surface lower" diagnostics

let bootstrap source =
  match Reader.parse_one ~file:"types.jqd" source with
  | Error diagnostics -> fail_diags "bootstrap read" diagnostics
  | Ok form -> (
      match Kernel.of_form form with
      | Ok top -> top
      | Error diagnostics -> fail_diags "bootstrap validate" diagnostics)

let print ?width ?lookup top =
  match Surface_print.print_top ?width ?lookup top with
  | Ok text -> text
  | Error diagnostics -> fail_diags "surface print" diagnostics

let print_fragment ?width source =
  match Reader.parse_one ~file:"fragment.jqd" source with
  | Error diagnostics -> fail_diags "fragment read" diagnostics
  | Ok form -> (
      match Surface_print.print_fragment ?width form with
      | Ok text -> text
      | Error diagnostics -> fail_diags "fragment print" diagnostics)

let print_recovered ?width source =
  let recovered = Surface_parse.recover_string ~file:"types.jac" source in
  match Surface_print.print_recovered ?width recovered with
  | Ok text -> text
  | Error diagnostics -> fail_diags "trivia print" diagnostics

let form top = Kernel.to_form top

let hash_top label top =
  match Canon.hash_top top with
  | Ok hashes -> hashes.Canon.decl_hash
  | Error diagnostics -> fail_diags (label ^ " hash") diagnostics

let comments key meta = Meta.comment_texts key meta

let contains text needle =
  let rec loop index =
    index + String.length needle <= String.length text
    && (String.sub text index (String.length needle) = needle || loop (index + 1))
  in
  loop 0

let read_file path =
  let channel = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in channel)
    (fun () -> really_input_string channel (in_channel_length channel))

let make_check_ctx () =
  let store, _ = Eval_support.make_prelude_ctx () in
  let ctx =
    match Check.make_ctx store with
    | Error diagnostics -> fail_diags "checker context" diagnostics
    | Ok ctx ->
        (match Prelude.builtin_signatures store with
        | Error diagnostics -> fail_diags "builtin signatures" diagnostics
        | Ok signatures -> Check.register_builtin_signatures ctx signatures);
        ctx
  in
  (store, ctx)

let only_annotation = function
  | Kernel.Decl { it = DefTerm [ { annot = Some annotation; _ } ]; _ } -> annotation
  | _ -> Alcotest.fail "expected one annotated definition"

let check_inversion label top =
  let rendered = print top in
  match lower (rendered ^ "\n") with
  | [ reparsed ] ->
      Alcotest.(check bool) label true (Form.equal_ignoring_meta (form top) (form reparsed))
  | _ -> Alcotest.failf "%s: printed text did not parse as one top" label

let test_complete_type_inventory () =
  let zero = String.make 64 '0' in
  let cases =
    [
      ("reference", "x : Text\nx = 0\n");
      ("variable", "x : a\nx = 0\n");
      ("application", "x : Result Text (List a)\nx = 0\n");
      ("empty tuple", "x : ()\nx = 0\n");
      ("singleton tuple", "x : (Text,)\nx = 0\n");
      ("nested arrow", "x : ((a) ->{| e} b, a) ->{| e} b\nx = 0\n");
      ("forall", "x : forall a b | e. ((a) ->{| e} b, a) ->{| e} b\nx = 0\n");
      ("empty forall", "x : forall . Text\nx = 0\n");
      ("explicit type hash", Printf.sprintf "x : #%s:type\nx = 0\n" zero);
    ]
  in
  List.iter
    (fun (label, source) ->
      match lower source with
      | [ top ] -> check_inversion label top
      | _ -> Alcotest.failf "%s did not lower to one definition" label)
    cases

let test_documented_signatures () =
  let store, check_ctx = make_check_ctx () in
  let fixtures =
    [
      ( "stdlib",
        "state.run : forall a b | e. (() ->{State | e} a, b) ->{| e} (a, b)",
        "../docs/stdlib.md",
        Some "state.run" );
      ( "Warp",
        "check.throws : forall a b | e. (() ->{Throw, Check | e} a, (b) ->{Check | e} Bool, Show \
         b, Text) ->{Check | e} ()",
        "../docs/warp-testing.md",
        Some "check.throws" );
      ("demo", "escrow.workflow : () ->{Fs, Console, Net} Int", "cli/escrow.t", None);
      ("tutorial safe-div", "safe-div : (Int, Int) ->{Abort} Int", "../docs/tutorial.md", None);
      ( "tutorial to-option",
        "to-option : forall a | e. (() ->{Abort | e} a) ->{| e} Option a",
        "../docs/tutorial.md",
        None );
    ]
  in
  List.iter
    (fun (label, signature, evidence_path, checker_name) ->
      Alcotest.(check bool)
        (label ^ " evidence contains exact checker output")
        true
        (contains (read_file evidence_path) signature);
      Option.iter
        (fun name ->
          let hash =
            match Store.lookup_kind store name Resolve.KTerm with
            | Some entry -> entry.Resolve.hash
            | None -> Alcotest.failf "%s: checker name not found" name
          in
          let actual =
            name ^ " : " ^ Check.show_scheme check_ctx (Check.term_scheme check_ctx hash)
          in
          Alcotest.(check string) (label ^ " exact checker output") signature actual)
        checker_name;
      let colon = String.index signature ':' in
      let name = String.sub signature 0 colon |> String.trim in
      let source = signature ^ "\n" ^ name ^ " = 0\n" in
      match lower source with
      | [ top ] -> check_inversion (label ^ " verbatim signature") top
      | _ -> Alcotest.failf "%s signature did not lower to one definition" label)
    fixtures

let test_row_forms_and_namespaces () =
  let zero = String.make 64 '0' in
  let rows =
    [
      "{}";
      "{Net}";
      "{Net, Clock}";
      "{Net | e}";
      "{| e}";
      "{`effect:net.v2`, `effect:match` | `rvar:row--tail`}";
      Printf.sprintf "{#%s:effect}" zero;
    ]
  in
  List.iter
    (fun row ->
      let source = Printf.sprintf "f : () ->%s Text\nf = 0\n" row in
      match lower source with
      | [ top ] -> check_inversion row top
      | _ -> Alcotest.failf "%s did not lower to one definition" row)
    rows;
  let type_hash = Hash.of_string "ss14-type" in
  let effect_hash = Hash.of_string "ss14-effect" in
  let names =
    Resolve.of_alist
      [
        ("net", { Resolve.hash = type_hash; kind = Resolve.KType });
        ("net", { Resolve.hash = effect_hash; kind = Resolve.KEffect });
      ]
  in
  match lower "f : () ->{Net} Net\nf = 0\n" with
  | [ top ] -> (
      match Resolve.resolve names top with
      | Error diagnostics -> fail_diags "namespace resolve" diagnostics
      | Ok
          (Kernel.Decl
             { it = DefTerm [ { annot = Some { it = TArrow (_, row, result); _ }; _ } ]; _ }) -> (
          match (row.effects, result.it) with
          | [ Kernel.Hashed actual_effect ], Kernel.TRef (Kernel.Hashed actual_type) ->
              Alcotest.(check bool) "effect namespace" true (Hash.equal effect_hash actual_effect);
              Alcotest.(check bool) "type namespace" true (Hash.equal type_hash actual_type)
          | _ -> Alcotest.fail "resolved row/type references had the wrong shape")
      | Ok _ -> Alcotest.fail "resolved signature had the wrong shape")
  | _ -> Alcotest.fail "namespace fixture did not lower to one definition"

let test_row_wrapping_threshold () =
  let row =
    "(row (eref network-observability) (eref filesystem-observability) (eref deterministic-clock) \
     e)"
  in
  let compact = "->{NetworkObservability, FilesystemObservability, DeterministicClock | e}" in
  Alcotest.(check string)
    "fits at exact width" compact
    (print_fragment ~width:(String.length compact) row);
  Alcotest.(check string)
    "wraps one effect per line"
    "->{\n  NetworkObservability,\n  FilesystemObservability,\n  DeterministicClock\n  | e\n}"
    (print_fragment ~width:(String.length compact - 1) row);
  let top =
    bootstrap
      "(ann (var f) (tarrow () (row (eref network-observability) (eref filesystem-observability) \
       (eref deterministic-clock) e) (tref text)))"
  in
  let once = print ~width:48 top in
  match lower (once ^ "\n") with
  | [ reparsed ] -> Alcotest.(check string) "wrapped idempotence" once (print ~width:48 reparsed)
  | _ -> Alcotest.fail "wrapped row did not parse as one top"

let test_hash_inversion_and_row_set_law () =
  let type_hash = Hash.of_string "ss14-result" in
  let net = Hash.of_string "ss14-net" in
  let clock = Hash.of_string "ss14-clock" in
  let hex hash = Hash.to_hex hash in
  let source effects =
    Printf.sprintf "(ann (lit 0) (tarrow () (row %s) (tref #%s)))"
      (String.concat " " (List.map (fun hash -> "(eref #" ^ hex hash ^ ")") effects))
      (hex type_hash)
  in
  let first = bootstrap (source [ net; clock ]) in
  let second = bootstrap (source [ clock; net ]) in
  check_inversion "explicit hash inversion" first;
  let hash = function
    | Kernel.Expr expression -> (
        match Canon.hash_expr expression with
        | Ok hash -> hash
        | Error diagnostics -> fail_diags "canonical hash" diagnostics)
    | Kernel.Decl _ -> Alcotest.fail "expected expression"
  in
  Alcotest.(check bool) "row order is hash-insensitive" true (Hash.equal (hash first) (hash second))

let test_resolved_reference_identity () =
  let result_hash = Hash.of_string "ss14-result-name" in
  let text_hash = Hash.of_string "ss14-text-name" in
  let map_hash = Hash.of_string "ss14-map-name" in
  let same_type_hash = Hash.of_string "ss14-same-type" in
  let same_effect_hash = Hash.of_string "ss14-same-effect" in
  let net_hash = Hash.of_string "ss14-net-effect" in
  let explicit_type = Hash.of_string "ss14-explicit-type" in
  let explicit_effect = Hash.of_string "ss14-explicit-effect" in
  let entries =
    [
      ("result", result_hash, Resolve.KType, Surface_name.Type);
      ("text", text_hash, Resolve.KType, Surface_name.Type);
      ("map.t", map_hash, Resolve.KType, Surface_name.Type);
      ("same", same_type_hash, Resolve.KType, Surface_name.Type);
      ("same", same_effect_hash, Resolve.KEffect, Surface_name.Effect);
      ("net.v2", net_hash, Resolve.KEffect, Surface_name.Effect);
    ]
  in
  let names =
    Resolve.of_alist
      (List.map (fun (name, hash, kind, _) -> (name, { Resolve.hash; kind })) entries)
  in
  let lookup kind hash =
    List.find_map
      (fun (name, candidate, _, candidate_kind) ->
        if kind = candidate_kind && Hash.equal hash candidate then Some name else None)
      entries
  in
  let source =
    Printf.sprintf
      "probe : forall `tvar:item--` | `rvar:rest--`. (Result Text `tvar:item--`, `type:map.t` \
       `tvar:item--`, Same) ->{`effect:net.v2`, Same, #%s:effect | `rvar:rest--`} #%s:type\n\
       probe = 0\n"
      (Hash.to_hex explicit_effect) (Hash.to_hex explicit_type)
  in
  let unresolved =
    match lower source with [ top ] -> top | _ -> Alcotest.fail "identity fixture"
  in
  let resolved =
    match Resolve.resolve names unresolved with
    | Ok top -> top
    | Error diagnostics -> fail_diags "identity resolve" diagnostics
  in
  let rendered = print ~lookup resolved in
  Alcotest.(check bool)
    "escaped dotted type survives rendering" true
    (contains rendered "`type:map.t`");
  Alcotest.(check bool)
    "escaped dotted effect survives rendering" true
    (contains rendered "`effect:net.v2`");
  Alcotest.(check bool) "named type survives rendering" true (contains rendered "Result Text");
  Alcotest.(check bool)
    "unknown full type hash fallback" true
    (contains rendered (Printf.sprintf "#%s:type" (Hash.to_hex explicit_type)));
  Alcotest.(check bool)
    "unknown full effect hash fallback" true
    (contains rendered (Printf.sprintf "#%s:effect" (Hash.to_hex explicit_effect)));
  let reparsed =
    match lower (rendered ^ "\n") with [ top ] -> top | _ -> Alcotest.fail "reparse"
  in
  let reresolved =
    match Resolve.resolve names reparsed with
    | Ok top -> top
    | Error diagnostics -> fail_diags "identity reresolve" diagnostics
  in
  Alcotest.(check bool)
    "resolved Form identity" true
    (Form.equal_ignoring_meta (form resolved) (form reresolved));
  Alcotest.(check bool)
    "resolved HASH_V0 identity" true
    (Hash.equal (hash_top "resolved" resolved) (hash_top "reresolved" reresolved));
  match only_annotation resolved with
  | { it = TForall (_, _, { it = TArrow (params, row, result); _ }); _ } -> (
      Alcotest.(check bool)
        "same-name type namespace" true
        (List.exists
           (fun (parameter : Kernel.ty) ->
             match parameter.Kernel.it with
             | TRef (Hashed hash) -> Hash.equal hash same_type_hash
             | _ -> false)
           params);
      Alcotest.(check bool)
        "same-name effect namespace" true
        (List.exists
           (function Kernel.Hashed hash -> Hash.equal hash same_effect_hash | Named _ -> false)
           row.effects);
      Alcotest.(check bool)
        "unknown explicit effect hash" true
        (List.exists
           (function Kernel.Hashed hash -> Hash.equal hash explicit_effect | Named _ -> false)
           row.effects);
      match result.it with
      | TRef (Hashed hash) ->
          Alcotest.(check bool) "unknown explicit type hash" true (Hash.equal explicit_type hash)
      | _ -> Alcotest.fail "explicit result type did not remain hashed")
  | _ -> Alcotest.fail "resolved identity annotation shape"

let test_checker_signatures_are_surface () =
  let store, check_ctx = make_check_ctx () in
  let expression =
    match
      Reader.parse_one ~file:"checker.jqd" "(lam ((pvar f) (pvar x)) (app (var f) (var x)))"
    with
    | Error diagnostics -> fail_diags "checker read" diagnostics
    | Ok form -> (
        match Kernel.expr_of_form form with
        | Error diagnostics -> fail_diags "checker validate" diagnostics
        | Ok expression -> expression)
  in
  let expression =
    match Resolve.resolve_expr (Store.names_view store) expression with
    | Ok expression -> expression
    | Error diagnostics -> fail_diags "checker resolve" diagnostics
  in
  let signature =
    match Check.check_top check_ctx (Kernel.Expr expression) with
    | Ok { Check.names = [ (_, scheme) ]; _ } -> Check.show_scheme check_ctx scheme
    | Ok _ -> Alcotest.fail "checker returned an unexpected signature set"
    | Error diagnostics -> fail_diags "checker inference" diagnostics
  in
  Alcotest.(check string)
    "surface row quantifier" "forall a b | e. ((b) ->{| e} a, b) ->{| e} a" signature;
  let rendered_source = "shown : " ^ signature ^ "\nshown(f, x) = f(x)\n" in
  let rendered_top =
    match lower rendered_source with [ top ] -> top | _ -> Alcotest.fail "rendered checker scheme"
  in
  let rendered_top =
    match Resolve.resolve (Store.names_view store) rendered_top with
    | Ok top -> top
    | Error diagnostics -> fail_diags "rendered checker scheme resolve" diagnostics
  in
  let rendered_signature =
    match Check.check_top check_ctx rendered_top with
    | Ok { Check.names = [ (_, scheme) ]; _ } -> Check.show_scheme check_ctx scheme
    | Ok _ -> Alcotest.fail "rendered checker scheme returned unexpected names"
    | Error diagnostics -> fail_diags "rendered checker scheme check" diagnostics
  in
  Alcotest.(check string) "inferred scheme rendering identity" signature rendered_signature

let test_type_trivia_ownership () =
  let source =
    "f : forall a | e. -- forall-dot\n\
     (a) ->{ -- row-open\n\
     -- net-leading\n\
     Net, -- comma\n\
     -- clock-leading\n\
     Clock -- clock-trailing\n\
     | -- row-bar\n\
     e -- row-tail\n\
     } -- row-close\n\
     a\n\
     f = 0\n"
  in
  let once = print_recovered source in
  let expected =
    {|f : forall a | e. -- forall-dot
      (a) ->{ -- row-open
        -- net-leading
       Net, -- comma
       -- clock-leading
       Clock -- clock-trailing
       | -- row-bar
       e -- row-tail
       } -- row-close
        a
f = 0
|}
  in
  let annotation = match lower source with [ top ] -> only_annotation top | _ -> assert false in
  (match annotation.it with
  | TForall (_, _, { it = TArrow (_, row, _); _ }) ->
      let forall = Meta.surface_container "forall" annotation.meta in
      Alcotest.(check (list string))
        "dot owns its trailing comment" [ "-- forall-dot" ]
        (comments Meta.key_trivia_trailing (Meta.surface_container "forall-dot" forall));
      Alcotest.(check (list string))
        "opening brace owns its trailing comment" [ "-- row-open" ]
        (comments Meta.key_trivia_trailing (Meta.surface_container "row-open" row.wmeta));
      Alcotest.(check (list string))
        "first effect has its own channel" [ "-- net-leading" ]
        (comments Meta.key_trivia (Meta.surface_indexed_container "row-effect" 0 row.wmeta));
      Alcotest.(check (list string))
        "comma has its own channel" [ "-- comma" ]
        (comments Meta.key_trivia_trailing (Meta.surface_indexed_container "row-comma" 0 row.wmeta));
      Alcotest.(check (list string))
        "second effect leading channel" [ "-- clock-leading" ]
        (comments Meta.key_trivia (Meta.surface_indexed_container "row-effect" 1 row.wmeta));
      Alcotest.(check (list string))
        "second effect trailing channel" [ "-- clock-trailing" ]
        (comments Meta.key_trivia_trailing
           (Meta.surface_indexed_container "row-effect" 1 row.wmeta));
      Alcotest.(check (list string))
        "bar owns its trailing comment" [ "-- row-bar" ]
        (comments Meta.key_trivia_trailing (Meta.surface_container "row-bar" row.wmeta));
      Alcotest.(check (list string))
        "tail owns its trailing comment" [ "-- row-tail" ]
        (comments Meta.key_trivia_trailing (Meta.surface_container "row-tail" row.wmeta));
      Alcotest.(check (list string))
        "closing brace owns its trailing comment" [ "-- row-close" ]
        (comments Meta.key_trivia_trailing (Meta.surface_container "row-close" row.wmeta))
  | _ -> Alcotest.fail "trivia fixture annotation shape");
  Alcotest.(check string) "exact canonical placement" expected once;
  Alcotest.(check string) "type trivia idempotence" once (print_recovered once)

let test_malformed_rows_and_recovery () =
  let zero = String.make 64 '0' in
  let cases =
    [
      ("missing tail", "f : () ->{|} Text\nf = 0\n");
      ("duplicate tail", "f : () ->{Net | e | f} Text\nf = 0\n");
      ("trailing comma", "f : () ->{Net,} Text\nf = 0\n");
      ("wrong namespace", Printf.sprintf "f : () ->{#%s:type} Text\nf = 0\n" zero);
      ("missing opening brace", "f : () ->Net Text\nf = 0\n");
      ("legacy tail-only", "f : () ->{e} Text\nf = 0\n");
      ("newline before comma", "f : () ->{Net\n, Clock} Text\nf = 0\n");
      ( "synthetic future parameterized-effect syntax",
        "future : () ->{FutureEffect payload | e} Text\nfuture = 0\n" );
    ]
  in
  List.iter
    (fun (label, source) ->
      let recovered = Surface_parse.recover_string ~file:"types.jac" source in
      Alcotest.(check bool)
        (label ^ " reports E1220") true
        (List.exists (fun diagnostic -> diagnostic.Diag.code = "E1220") recovered.diagnostics))
    cases;
  let legacy = "f : () ->{e} Text\nf = 0\n" in
  let legacy_recovered = Surface_parse.recover_string ~file:"types.jac" legacy in
  Alcotest.(check bool)
    "legacy tail-only row rejected" true
    (List.exists (fun diagnostic -> diagnostic.Diag.code = "E1220") legacy_recovered.diagnostics);
  Alcotest.(check string) "legacy tail-only exact recovery" legacy (print_recovered legacy);
  let recovered =
    Surface_parse.recover_string ~file:"types.jac" "broken : () ->{Net\nlater = 42\n"
  in
  Alcotest.(check (list string))
    "missing brace diagnostic"
    [
      "types.jac:2:1-6: error[E1220]: expected `}` before the next top-level item";
      "types.jac:2:1-6: error[E1224]: signature for `broken` cannot attach to definition `later`";
    ]
    (List.map Diag.to_string recovered.diagnostics);
  match List.rev recovered.items with
  | { Surface_ast.it = Definition { name = "later"; _ }; _ } :: _ -> ()
  | _ -> Alcotest.fail "malformed row recovery discarded the later top-level definition"

let test_forall_newline_recovery_and_owners () =
  let cases =
    [
      ( "binder newline",
        "f : forall a -- binder-comment\n. a\nf = 0\n",
        "-- binder-comment",
        "forall-tvar",
        0 );
      ( "bar newline",
        "f : forall a | -- bar-comment\ne. a\nf = 0\n",
        "-- bar-comment",
        "forall-bar",
        -1 );
      ( "row binder newline",
        "f : forall a | e -- row-binder-comment\n. a\nf = 0\n",
        "-- row-binder-comment",
        "forall-rvar",
        0 );
    ]
  in
  List.iter
    (fun (label, source, comment, owner, index) ->
      let recovered = Surface_parse.recover_string ~file:"types.jac" source in
      Alcotest.(check bool)
        (label ^ " rejected") true
        (List.exists (fun diagnostic -> diagnostic.Diag.code = "E1220") recovered.diagnostics);
      Alcotest.(check string) (label ^ " exact recovery") source (print_recovered source);
      match recovered.items with
      | { Surface_ast.it = Signature (_, annotation); _ } :: _ ->
          let forall = Meta.surface_container "forall" annotation.meta in
          let owner_meta =
            if index < 0 then Meta.surface_container owner forall
            else Meta.surface_indexed_container owner index forall
          in
          Alcotest.(check (list string))
            (label ^ " deterministic owner") [ comment ]
            (comments Meta.key_trivia_trailing owner_meta)
      | _ -> Alcotest.failf "%s did not retain its signature island" label)
    cases

let test_raw_and_bootstrap_fallback () =
  let raw = "jqd { (ann (var f) (tarrow () (row (eref net)) (tref text))) }\n" in
  match lower raw with
  | [ top ] ->
      Alcotest.(check string) "raw top remains explicit" (String.trim raw) (print top);
      let bootstrap_source = "(ann (var f) (tarrow () (row e) (tref text)))" in
      let before = bootstrap bootstrap_source in
      let after = bootstrap bootstrap_source in
      Alcotest.(check bool)
        "bootstrap reader unchanged" true
        (Form.equal_ignoring_meta (form before) (form after))
  | _ -> Alcotest.fail "raw fixture did not lower to one top"

let suite =
  [
    Alcotest.test_case "complete type inventory" `Quick test_complete_type_inventory;
    Alcotest.test_case "documented signatures" `Quick test_documented_signatures;
    Alcotest.test_case "row forms and namespaces" `Quick test_row_forms_and_namespaces;
    Alcotest.test_case "row wrapping threshold" `Quick test_row_wrapping_threshold;
    Alcotest.test_case "hash inversion and row set law" `Quick test_hash_inversion_and_row_set_law;
    Alcotest.test_case "resolved reference identity" `Quick test_resolved_reference_identity;
    Alcotest.test_case "checker surface signatures" `Quick test_checker_signatures_are_surface;
    Alcotest.test_case "type trivia ownership" `Quick test_type_trivia_ownership;
    Alcotest.test_case "malformed rows and recovery" `Quick test_malformed_rows_and_recovery;
    Alcotest.test_case "forall newline recovery" `Quick test_forall_newline_recovery_and_owners;
    Alcotest.test_case "raw and bootstrap fallback" `Quick test_raw_and_bootstrap_fallback;
  ]
