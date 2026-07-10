open Jacquard

let fail_diags label diagnostics =
  Alcotest.failf "%s: %s" label (String.concat "; " (List.map Diag.to_string diagnostics))

let parse_file source =
  match Surface_parse.parse_file ~file:"trivia.jac" source with
  | Ok file -> file
  | Error diagnostics -> fail_diags "parse" diagnostics

let lower_file source =
  match Surface_lower.lower_file (parse_file source) with
  | Ok file -> file
  | Error diagnostics -> fail_diags "lower" diagnostics

let print_recovered source =
  let recovered = Surface_parse.recover_string ~file:"trivia.jac" source in
  match Surface_print.print_recovered recovered with
  | Ok text -> text
  | Error diagnostics -> fail_diags "print" diagnostics

let atom_text = function Meta.Layout text | Comment text | Doc text -> text
let texts key meta = List.map atom_text (Meta.trivia key meta)
let comments key meta = Meta.comment_texts key meta

let contains text substring =
  try
    ignore (Str.search_forward (Str.regexp_string substring) text 0);
    true
  with Not_found -> false

let count_occurrences text substring =
  let regexp = Str.regexp_string substring in
  let rec loop offset count =
    try
      let found = Str.search_forward regexp text offset in
      loop (found + String.length substring) (count + 1)
    with Not_found -> count
  in
  loop 0 0

let index_of text substring =
  try Str.search_forward (Str.regexp_string substring) text 0
  with Not_found -> Alcotest.failf "missing substring %S in:\n%s" substring text

let only_binding = function
  | [ Kernel.Decl { Kernel.it = Kernel.DefTerm [ binding ]; _ } ] -> binding
  | _ -> Alcotest.fail "expected one singleton term declaration"

let test_exact_top_trivia_and_file_anchor () =
  let source = "\t-- lead\r\nx = 1  -- tail\r\n\r\n-- eof" in
  let file = parse_file source in
  (match file.tops with
  | [ top ] ->
      Alcotest.(check (list string))
        "leading bytes" [ "\t"; "-- lead\r"; "\n"; " " ] (texts Meta.key_trivia top.meta);
      Alcotest.(check (list string))
        "trailing bytes" [ "  "; "-- tail\r" ]
        (texts Meta.key_trivia_trailing top.meta);
      Alcotest.(check (list string))
        "EOF bytes" [ "\n\r\n"; "-- eof" ]
        (texts Meta.key_trivia_eof top.meta)
  | _ -> Alcotest.fail "expected one parsed top");
  let comment_only = parse_file "\t-- only\r\n--| orphan" in
  Alcotest.(check int) "comment-only tops" 0 (List.length comment_only.tops);
  Alcotest.(check (list string))
    "file anchor"
    [ "\t"; "-- only\r"; "\n"; "--| orphan" ]
    (texts Meta.key_trivia_eof comment_only.meta)

let test_structured_encoding_and_legacy () =
  let atoms = [ Meta.Layout "\t"; Meta.Comment "-- c"; Meta.Doc "--| d" ] in
  let meta = Meta.with_trivia Meta.key_trivia atoms Meta.empty in
  Alcotest.(check bool) "structured roundtrip" true (Meta.trivia Meta.key_trivia meta = atoms);
  let encoded = Meta.find Meta.key_trivia meta in
  (match encoded with
  | Some (Meta.List [ Meta.Map _; Meta.Map _; Meta.Map _ ]) -> ()
  | _ -> Alcotest.fail "trivia did not use ordered map atoms");
  let legacy = Meta.add Meta.key_trivia (Meta.List [ Meta.Text "; old" ]) Meta.empty in
  Alcotest.(check (list string)) "legacy bootstrap" [ "; old" ] (texts Meta.key_trivia legacy)

let test_semicolon_and_blank_line_bytes () =
  let file = parse_file "x = 1;\t-- first\r\n\r\n  y = 2\n" in
  match file.tops with
  | [ first; second ] ->
      Alcotest.(check (list string))
        "semicolon/trailing bytes" [ ";\t"; "-- first\r" ]
        (texts Meta.key_trivia_trailing first.meta);
      Alcotest.(check (list string))
        "blank-line leading bytes" [ "\n\r\n  "; " " ]
        (texts Meta.key_trivia second.meta)
  | _ -> Alcotest.fail "semicolon fixture shape"

let test_layout_capture_normalizes_output () =
  let source = "x\t=\t1;\t\r\n\r\n  y = 2\r\n" in
  let file = parse_file source in
  let layout =
    file.tops
    |> List.concat_map (fun (top : Surface_ast.top) ->
        Meta.trivia Meta.key_trivia top.meta
        @ Meta.trivia Meta.key_trivia_trailing top.meta
        @ Meta.trivia Meta.key_trivia_eof top.meta)
    |> List.filter_map (function Meta.Layout text -> Some text | Comment _ | Doc _ -> None)
    |> String.concat ""
  in
  Alcotest.(check bool) "tabs captured exactly" true (String.contains layout '\t');
  Alcotest.(check bool) "CRLF captured exactly" true (contains layout "\r\n");
  Alcotest.(check bool) "blank line captured exactly" true (contains layout "\r\n\r\n");
  Alcotest.(check bool) "semicolon captured exactly" true (String.contains layout ';');
  let printed = print_recovered source in
  Alcotest.(check bool) "tabs normalized" false (String.contains printed '\t');
  Alcotest.(check bool) "CR normalized" false (String.contains printed '\r');
  Alcotest.(check bool) "semicolons normalized" false (String.contains printed ';')

let test_docs_attach_only_to_declarations () =
  let source =
    "--| signature\n\
     id : (a) ->{} a\n\
     --| definition\n\
     id(x) = x\n\n\
     --| type\n\
     type T = | T\n\n\
     --| effect\n\
     effect E where { op : () -> T }\n"
  in
  let lowered = lower_file source in
  (match lowered.tops with
  | [
   Kernel.Decl { Kernel.it = DefTerm [ binding ]; _ };
   Kernel.Decl ({ Kernel.it = DefType _; _ } as type_decl);
   Kernel.Decl ({ Kernel.it = DefEffect _; _ } as effect_decl);
  ] ->
      Alcotest.(check (list string))
        "definition docs" [ "--| definition" ]
        (List.map atom_text (Meta.docs binding.bmeta));
      Alcotest.(check (list string))
        "signature docs" [ "--| signature" ]
        (List.map atom_text (Meta.docs (Meta.signature binding.bmeta)));
      Alcotest.(check (list string))
        "type docs" [ "--| type" ]
        (List.map atom_text (Meta.docs type_decl.meta));
      Alcotest.(check (list string))
        "effect docs" [ "--| effect" ]
        (List.map atom_text (Meta.docs effect_decl.meta))
  | _ -> Alcotest.fail "doc fixture lowered to an unexpected shape");
  let same_line = parse_file "x = 1 --| trailing\n" in
  let top = List.hd same_line.tops in
  Alcotest.(check int) "same-line doc is not attached" 0 (List.length (Meta.docs top.meta));
  Alcotest.(check (list string))
    "same-line doc is trailing" [ " "; "--| trailing" ]
    (texts Meta.key_trivia_trailing top.meta);
  let orphan = parse_file "--| orphan\n42\n" in
  match orphan.tops with
  | [ { Surface_ast.it = TopExpr expression; _ } ] ->
      Alcotest.(check int) "expression has no docs" 0 (List.length (Meta.docs expression.meta));
      Alcotest.(check (list string))
        "orphan remains trivia" [ "--| orphan"; "\n" ]
        (texts Meta.key_trivia expression.meta)
  | _ -> Alcotest.fail "orphan fixture shape"

let test_scc_reorder_keeps_binding_trivia () =
  let lowered = lower_file "-- b doc\nb = a\n-- a doc\na = 1\n" in
  let bindings =
    List.concat_map
      (function
        | Kernel.Decl { Kernel.it = DefTerm bindings; _ } -> bindings
        | _ -> Alcotest.fail "expected only term declarations")
      lowered.tops
  in
  Alcotest.(check (list string))
    "dependency-first order" [ "a"; "b" ]
    (List.map (fun binding -> binding.Kernel.bname) bindings);
  let comments binding = Meta.comment_texts Meta.key_trivia binding.Kernel.bmeta in
  Alcotest.(check (list string)) "a owns a comment" [ "-- a doc" ] (comments (List.nth bindings 0));
  Alcotest.(check (list string)) "b owns b comment" [ "-- b doc" ] (comments (List.nth bindings 1))

let test_nested_ownership_and_print_idempotence () =
  let source = "-- top\nf(1, -- next\n\t2\n  -- inner\n) -- trailing\n-- eof\n" in
  let file = parse_file source in
  (match file.tops with
  | [ { Surface_ast.it = TopExpr ({ it = Call (_, [ first; second ]); _ } as call); _ } ] ->
      Alcotest.(check (list string))
        "comment after comma leads next arg" [ " "; "-- next"; "\n\t" ]
        (texts Meta.key_trivia second.meta);
      Alcotest.(check (list string))
        "closing-delimiter interior" [ "\n  "; "-- inner"; "\n" ]
        (texts Meta.key_trivia_inner call.meta);
      Alcotest.(check int)
        "first arg not duplicated" 0
        (List.length (Meta.trivia Meta.key_trivia_trailing first.meta))
  | _ -> Alcotest.fail "nested fixture shape");
  let once = print_recovered source in
  let twice = print_recovered once in
  Alcotest.(check string) "trivia-aware print idempotent" once twice;
  Alcotest.(check bool)
    "all comment bytes survive" true
    (List.for_all (contains once) [ "-- top"; "-- next"; "-- inner"; "-- trailing"; "-- eof" ])

let test_comment_free_compatibility () =
  let source = "id(x) = {\n  let y = x\n  y\n}\n" in
  let lowered = lower_file source in
  let canonical =
    match Surface_print.print_file lowered.tops with
    | Ok text -> text
    | Error diagnostics -> fail_diags "canonical print" diagnostics
  in
  Alcotest.(check string) "comment-free path" canonical (print_recovered source)

let test_container_comment_printing () =
  let sources =
    [
      "choose(x) = match x {\n -- first\n | A -> 1 -- body\n -- second\n | B -> 2\n -- inner\n}\n";
      "run() = handle body() {\n\
      \ -- ret\n\
      \ | return x -> x\n\
      \ -- op\n\
      \ | abort(-- p\n\
      \ p) resume k -> k(p)\n\
      \ -- inner\n\
       }\n";
      "--| t\n\
       type Pair a =\n\
      \ -- con\n\
      \ | Pair(-- first\n\
      \ left: a, -- second\n\
      \ right: a\n\
      \ -- fields inner\n\
       )\n\
       --| e\n\
       effect E where {\n\
      \ -- op\n\
      \ op : (-- param\n\
      \ Pair a) -> Pair a\n\
      \ -- effect inner\n\
       }\n";
      "f : () ->{ -- effect\n E -- tail\n | r} T\nf() = 1\n";
    ]
  in
  List.iteri
    (fun index source ->
      let once = print_recovered source in
      Alcotest.(check string)
        (Printf.sprintf "container %d idempotent" index)
        once (print_recovered once))
    sources

let hash source =
  let top =
    match (lower_file source).tops with [ top ] -> top | _ -> Alcotest.fail "expected one top"
  in
  let top =
    match Resolve.resolve Resolve.empty_names top with
    | Ok top -> top
    | Error diagnostics -> fail_diags "resolve" diagnostics
  in
  match Canon.hash_top top with
  | Ok result -> result.Canon.decl_hash
  | Error diagnostics -> fail_diags "hash" diagnostics

let test_hash_and_metadata_law () =
  let plain = "id(x) = x\n" in
  let decorated = "--| identity\r\nid ( x ) =\t x -- result\r\n" in
  let plain_form = Kernel.to_form (List.hd (lower_file plain).tops) in
  let decorated_form = Kernel.to_form (List.hd (lower_file decorated).tops) in
  Alcotest.(check bool) "commented form" true (Form.equal_ignoring_meta plain_form decorated_form);
  Alcotest.(check bool) "commented hash" true (Hash.equal (hash plain) (hash decorated));
  let binding = only_binding (lower_file plain).tops in
  let base = Kernel.{ it = DefTerm [ binding ]; meta = Meta.empty } in
  let perturbed =
    {
      base with
      Kernel.meta =
        Meta.with_trivia Meta.key_trivia
          [ Meta.Layout "\r\n\t"; Meta.Comment "-- metadata only" ]
          Meta.empty;
    }
  in
  let hash_decl declaration =
    match Canon.hash_top (Kernel.Decl declaration) with
    | Ok result -> result.Canon.decl_hash
    | Error diagnostics -> fail_diags "metadata hash" diagnostics
  in
  Alcotest.(check bool)
    "metadata perturbation" true
    (Hash.equal (hash_decl base) (hash_decl perturbed))

let test_recovery_boundaries () =
  let source = "f(1, -- before invalid\n @ -- after invalid\n 2)\n-- next top\n3\n" in
  let recovered = Surface_parse.recover_string ~file:"recover-trivia.jac" source in
  Alcotest.(check bool) "recovery has diagnostics" true (recovered.diagnostics <> []);
  Alcotest.(check string) "recovery retains full source" source recovered.source;
  Alcotest.(check string)
    "damaged replay is exact" source
    (match Surface_print.print_recovered recovered with
    | Ok text -> text
    | Error diagnostics -> fail_diags "recovered print" diagnostics);
  match recovered.items with
  | [
   { Surface_ast.it = TopExpr { it = Call (_, args); _ }; _ }; { Surface_ast.it = TopExpr last; _ };
  ] ->
      let holes =
        List.filter_map
          (fun expression ->
            match expression.Surface_ast.it with Surface_ast.Hole _ -> Some expression | _ -> None)
          args
      in
      Alcotest.(check bool) "invalid produced a hole" true (holes <> []);
      let hole = List.hd holes in
      Alcotest.(check (list string))
        "comment before invalid belongs to hole" [ "-- before invalid" ]
        (comments Meta.key_trivia hole.meta);
      Alcotest.(check (list string))
        "comment after invalid trails hole" [ "-- after invalid" ]
        (comments Meta.key_trivia_trailing hole.meta);
      let undamaged =
        List.filter
          (fun expression ->
            match expression.Surface_ast.it with Surface_ast.Hole _ -> false | _ -> true)
          args
      in
      Alcotest.(check bool)
        "invalid comments do not cross to valid args" true
        (List.for_all
           (fun (expression : Surface_ast.expr) ->
             comments Meta.key_trivia expression.meta = []
             && comments Meta.key_trivia_trailing expression.meta = [])
           undamaged);
      Alcotest.(check (list string))
        "next-top comment stayed with next top" [ "\n"; "-- next top"; "\n" ]
        (texts Meta.key_trivia last.meta)
  | _ -> Alcotest.fail "recovery fixture did not retain both top-level boundaries"

let test_missing_delimiter_replay_and_orphan_docs () =
  let damaged =
    [
      "f(1, -- missing close\n2\nlater = 3\n";
      "match x {\n | A -> 1\n -- before next top\nlater = 2\n";
      "handle body() {\n | return x -> x\n -- before next top\nlater = 2\n";
    ]
  in
  List.iter
    (fun source ->
      let recovered = Surface_parse.recover_string ~file:"missing-trivia.jac" source in
      Alcotest.(check bool) "missing delimiter diagnosed" true (recovered.diagnostics <> []);
      Alcotest.(check string)
        "missing delimiter replay" source
        (match Surface_print.print_recovered recovered with
        | Ok text -> text
        | Error diagnostics -> fail_diags "missing replay" diagnostics))
    damaged;
  let missing_match =
    Surface_parse.recover_string ~file:"missing-boundary.jac"
      "match x {\n| A -> 1\n-- next-top-owned\nlater = 2\n"
  in
  (match missing_match.items with
  | [ { Surface_ast.it = TopExpr { it = Match (_, [ clause ]); _ }; _ }; definition ] ->
      Alcotest.(check (list string))
        "missing delimiter comment stays off prior clause" []
        (comments Meta.key_trivia_trailing clause.cmeta);
      Alcotest.(check (list string))
        "missing delimiter comment belongs to next top" [ "-- next-top-owned" ]
        (comments Meta.key_trivia definition.meta)
  | _ -> Alcotest.fail "missing match boundary fixture shape");
  let orphan = Surface_parse.recover_string ~file:"orphan-damage.jac" "--|\n@\nx = 1\n" in
  match orphan.items with
  | ({ Surface_ast.it = TopHole _; _ } as hole) :: _ ->
      Alcotest.(check int) "damage is not documented" 0 (List.length (Meta.docs hole.meta));
      Alcotest.(check (list string))
        "empty doc remains ordinary trivia" [ "--|"; "\n" ] (texts Meta.key_trivia hole.meta)
  | _ -> Alcotest.fail "orphan damage fixture shape"

let test_clause_boundaries () =
  let file = parse_file "match x {\n| A -> 1 -- first-tail\n-- second-leading\n| B -> 2\n}\n" in
  match file.tops with
  | [ { Surface_ast.it = TopExpr { it = Match (_, [ first; second ]); _ }; _ } ] ->
      Alcotest.(check (list string))
        "first clause tail" [ "-- first-tail" ]
        (comments Meta.key_trivia_trailing first.cmeta);
      Alcotest.(check (list string))
        "second clause leading" [ "-- second-leading" ]
        (comments Meta.key_trivia second.cmeta);
      Alcotest.(check bool)
        "clause comments do not cross" true
        (not (List.mem "-- second-leading" (comments Meta.key_trivia first.cmeta)))
  | _ -> Alcotest.fail "clause boundary fixture shape"

let test_parameter_container_ownership () =
  let fixtures =
    [
      ("definition", "f(x\n-- params-inner\n) = x\n", "-- params-inner");
      ("function", "f = fn (x\n-- fn-inner\n) -> x\n", "-- fn-inner");
      ("operation", "effect E where { op : (T\n-- op-inner\n) -> T }\n", "-- op-inner");
      ( "handler operation",
        "f = handle x { | return y -> y | op(x\n-- handler-inner\n) resume k -> k(x) }\n",
        "-- handler-inner" );
      ( "constructor",
        "type Pair = | Pair(left: T\n-- constructor-inner\n)\n",
        "-- constructor-inner" );
      ("arrow", "f : (T\n-- arrow-inner\n) ->{} T\nf = 1\n", "-- arrow-inner");
    ]
  in
  List.iter
    (fun (label, source, comment) ->
      let lowered = lower_file source in
      let printed = print_recovered source in
      (match (label, lowered.tops) with
      | "definition", [ Kernel.Decl { Kernel.it = DefTerm [ binding ]; _ } ] -> (
          Alcotest.(check (list string))
            "definition container owns inner" [ comment ]
            (comments Meta.key_trivia_inner (Meta.surface_container "params" binding.bmeta));
          match binding.value.it with
          | Kernel.Lam (params, _) ->
              Alcotest.(check (list string))
                "last definition parameter has no fake tail" []
                (comments Meta.key_trivia_trailing (List.hd params).meta);
              Alcotest.(check (list string))
                "generated definition lambda does not duplicate the container" []
                (comments Meta.key_trivia_inner
                   (Meta.surface_container "params" binding.value.meta))
          | _ -> Alcotest.fail "definition did not lower to a lambda")
      | "function", [ Kernel.Decl { Kernel.it = DefTerm [ binding ]; _ } ] ->
          Alcotest.(check (list string))
            "function container owns inner" [ comment ]
            (comments Meta.key_trivia_inner (Meta.surface_container "params" binding.value.meta))
      | "operation", [ Kernel.Decl { Kernel.it = DefEffect { ops = [ operation ]; _ }; _ } ] ->
          Alcotest.(check (list string))
            "operation container owns inner" [ comment ]
            (comments Meta.key_trivia_inner (Meta.surface_container "params" operation.smeta))
      | "handler operation", [ Kernel.Decl { Kernel.it = DefTerm [ binding ]; _ } ] -> (
          match binding.value.it with
          | Kernel.Handle { ops = [ operation ]; _ } ->
              Alcotest.(check (list string))
                "handler container owns inner" [ comment ]
                (comments Meta.key_trivia_inner (Meta.surface_container "params" operation.ometa))
          | _ -> Alcotest.fail "handler fixture shape")
      | "constructor", [ Kernel.Decl { Kernel.it = DefType { cons = [ constructor ]; _ }; _ } ] ->
          Alcotest.(check (list string))
            "constructor container owns inner" [ comment ]
            (comments Meta.key_trivia_inner (Meta.surface_container "params" constructor.kmeta))
      | "arrow", [ Kernel.Decl { Kernel.it = DefTerm [ binding ]; _ } ] -> (
          match binding.annot with
          | Some annotation ->
              Alcotest.(check (list string))
                "arrow container owns inner" [ comment ]
                (comments Meta.key_trivia_inner (Meta.surface_container "params" annotation.meta))
          | None -> Alcotest.fail "arrow fixture lost its signature")
      | _ -> Alcotest.failf "%s fixture lowered to an unexpected shape" label);
      Alcotest.(check int) (label ^ " prints once") 1 (count_occurrences printed comment);
      Alcotest.(check string) (label ^ " idempotent") printed (print_recovered printed))
    fixtures

let test_all_parenthesized_container_printing () =
  let sources =
    [
      "f = call(1\n-- call-inner\n)\n";
      "f = (1, 2\n-- tuple-inner\n)\n";
      "f = quote { unquote(1\n-- unquote-inner\n) }\n";
      "f = (1 : T\n-- annotation-inner\n)\n";
      "f = fn ((x, y\n-- pattern-inner\n)) -> x\n";
    ]
  in
  List.iter
    (fun source ->
      let printed = print_recovered source in
      Alcotest.(check string) "parenthesized container idempotent" printed (print_recovered printed))
    sources

let test_remaining_delimited_containers () =
  let printable =
    [
      ("grouping", "f = (x\n-- grouping-inner\n)\n", "-- grouping-inner");
      ("quote", "f = quote { 1\n-- quote-inner\n}\n", "-- quote-inner");
      ( "constructor pattern",
        "f = match x { | Some(y\n-- constructor-pattern-inner\n) -> y }\n",
        "-- constructor-pattern-inner" );
      ("type tuple", "f : (T, U\n-- type-tuple-inner\n)\nf = 1\n", "-- type-tuple-inner");
      ("empty call", "f = call(-- empty-call-inner\n)\n", "-- empty-call-inner");
      ("empty definition", "f(-- empty-definition-inner\n) = 1\n", "-- empty-definition-inner");
      ("empty function", "f = fn (-- empty-function-inner\n) -> 1\n", "-- empty-function-inner");
      ( "empty effect operation",
        "effect E where { op : (-- empty-operation-inner\n) -> T }\n",
        "-- empty-operation-inner" );
      ( "empty handler operation",
        "f = handle x { | return y -> y | op(-- empty-handler-inner\n) resume k -> 1 }\n",
        "-- empty-handler-inner" );
    ]
  in
  List.iter
    (fun (label, source, comment) ->
      let printed = print_recovered source in
      Alcotest.(check int) (label ^ " comment count") 1 (count_occurrences printed comment);
      Alcotest.(check string) (label ^ " idempotent") printed (print_recovered printed))
    printable

let test_block_container_provenance () =
  let singleton =
    "-- singleton-leading\n\
     {\n\
     -- singleton-item\n\
     1\n\
     -- singleton-inner\n\
     } -- singleton-trailing\n\
     -- singleton-eof"
  in
  let multi =
    "-- multi-leading\n\
     {\n\
     -- first-item\n\
     1\n\
     -- second-item\n\
     2\n\
     -- multi-inner\n\
     } -- multi-trailing\n"
  in
  List.iter
    (fun (label, source, expected) ->
      let lowered = lower_file source in
      let root =
        match lowered.tops with
        | [ Kernel.Expr expression ] -> expression
        | _ -> Alcotest.fail label
      in
      let container = Meta.surface_container "block" root.meta in
      Alcotest.(check (list string))
        (label ^ " leading")
        [ List.nth expected 0 ]
        (comments Meta.key_trivia container);
      Alcotest.(check (list string))
        (label ^ " inner")
        [ List.nth expected 1 ]
        (comments Meta.key_trivia_inner container);
      Alcotest.(check (list string))
        (label ^ " trailing")
        [ List.nth expected 2 ]
        (comments Meta.key_trivia_trailing container);
      let printed = print_recovered source in
      List.iter
        (fun comment ->
          Alcotest.(check int) (label ^ " unique " ^ comment) 1 (count_occurrences printed comment))
        expected;
      Alcotest.(check string) (label ^ " idempotent") printed (print_recovered printed))
    [
      ( "singleton",
        singleton,
        [
          "-- singleton-leading"; "-- singleton-inner"; "-- singleton-trailing"; "-- singleton-eof";
        ] );
      ( "multi",
        multi,
        [
          "-- multi-leading";
          "-- multi-inner";
          "-- multi-trailing";
          "-- first-item";
          "-- second-item";
        ] );
    ]

let test_raw_top_and_quote_bootstrap_trivia () =
  let raw =
    "-- outer-leading\n\
     jqd { ; raw-leading\n\
     (lit 1) ; raw-trailing\n\
     ; raw-eof\n\
     } -- outer-trailing\n\
     -- outer-eof"
  in
  let lowered = lower_file raw in
  let root_meta =
    match lowered.tops with
    | [ Kernel.Expr expression ] -> expression.meta
    | _ -> Alcotest.fail "raw top fixture shape"
  in
  Alcotest.(check (list string))
    "raw outer leading" [ "-- outer-leading" ]
    (comments Meta.key_trivia root_meta);
  Alcotest.(check (list string))
    "raw outer trailing" [ "-- outer-trailing" ]
    (comments Meta.key_trivia_trailing root_meta);
  let bootstrap = Meta.surface_container "bootstrap" root_meta in
  Alcotest.(check bool)
    "raw bootstrap metadata retained" true
    (comments Meta.key_trivia bootstrap <> [] || comments Meta.key_trivia_eof bootstrap <> []);
  let printed = print_recovered raw in
  List.iter
    (fun comment ->
      Alcotest.(check int) ("raw unique " ^ comment) 1 (count_occurrences printed comment))
    [
      "; raw-leading";
      "; raw-trailing";
      "; raw-eof";
      "-- outer-leading";
      "-- outer-trailing";
      "-- outer-eof";
    ];
  Alcotest.(check string) "raw top idempotent" printed (print_recovered printed);
  let quote = "f = quote { jqd { (mystery ; structured\n foo) } }\n" in
  let quote_printed = print_recovered quote in
  Alcotest.(check bool) "raw quote comment" true (contains quote_printed "; structured");
  Alcotest.(check string) "raw quote idempotent" quote_printed (print_recovered quote_printed);
  let quote_eof = "f = quote { jqd { (lit 1) ; quoted-eof\n} }\n" in
  let quote_eof_printed = print_recovered quote_eof in
  Alcotest.(check int)
    "raw quote EOF is not duplicated" 1
    (count_occurrences quote_eof_printed "; quoted-eof");
  Alcotest.(check string)
    "raw quote EOF idempotent" quote_eof_printed
    (print_recovered quote_eof_printed)

let test_match_sequence_arm_trailing () =
  let source = "f = match x {\n| A -> { 1; 2 } -- sequence-tail\n| B -> 3\n-- match-inner\n}\n" in
  let printed = print_recovered source in
  let tail = index_of printed "-- sequence-tail" in
  let next_arm = index_of printed "| B ->" in
  Alcotest.(check bool) "sequence tail precedes next arm" true (tail < next_arm);
  Alcotest.(check int) "sequence tail once" 1 (count_occurrences printed "-- sequence-tail");
  Alcotest.(check string) "sequence arm idempotent" printed (print_recovered printed)

let test_signature_channels_and_doc_suffix () =
  let source =
    "--| signature-doc\n\
     f : (T) ->{} T -- signature-tail\n\
     -- between\n\
     --| definition-doc\n\
     f(x) = x -- definition-tail\n"
  in
  let binding = only_binding (lower_file source).tops in
  let signature = Meta.signature binding.bmeta in
  Alcotest.(check (list string))
    "signature docs" [ "--| signature-doc" ]
    (List.map atom_text (Meta.docs signature));
  Alcotest.(check (list string))
    "signature tail" [ "-- signature-tail" ]
    (comments Meta.key_trivia_trailing signature);
  Alcotest.(check (list string))
    "definition docs" [ "--| definition-doc" ]
    (List.map atom_text (Meta.docs binding.bmeta));
  Alcotest.(check (list string))
    "definition leading comments"
    [ "-- between"; "--| definition-doc" ]
    (comments Meta.key_trivia binding.bmeta);
  Alcotest.(check (list string))
    "definition tail" [ "-- definition-tail" ]
    (comments Meta.key_trivia_trailing binding.bmeta);
  let printed = print_recovered source in
  let positions =
    List.map (index_of printed)
      [
        "--| signature-doc";
        "f :";
        "-- signature-tail";
        "-- between";
        "--| definition-doc";
        "f(x)";
        "-- definition-tail";
      ]
  in
  Alcotest.(check (list int))
    "signature/definition order" (List.sort Int.compare positions) positions;
  let ordinary_doc = lower_file "-- ordinary\n--| first\n--| second\ntype T = | T\n" in
  (match ordinary_doc.tops with
  | [ Kernel.Decl declaration ] ->
      Alcotest.(check (list string))
        "maximal doc suffix" [ "--| first"; "--| second" ]
        (List.map atom_text (Meta.docs declaration.meta))
  | _ -> Alcotest.fail "ordinary/doc type fixture");
  let blank_doc = lower_file "--| detached\n\ntype T = | T\n" in
  match blank_doc.tops with
  | [ Kernel.Decl declaration ] ->
      Alcotest.(check int) "blank line detaches docs" 0 (List.length (Meta.docs declaration.meta))
  | _ -> Alcotest.fail "blank doc fixture"

let test_scc_reorder_keeps_signature_bundles () =
  let source =
    "--| b signature\n\
     b : () ->{} T -- b signature tail\n\
     -- b definition\n\
     b = a -- b definition tail\n\
     --| a signature\n\
     a : () ->{} T -- a signature tail\n\
     -- a definition\n\
     a = 1 -- a definition tail\n"
  in
  let lowered = lower_file source in
  let bindings =
    List.concat_map
      (function Kernel.Decl { Kernel.it = DefTerm bindings; _ } -> bindings | _ -> [])
      lowered.tops
  in
  Alcotest.(check (list string))
    "SCC reordered names" [ "a"; "b" ]
    (List.map (fun binding -> binding.Kernel.bname) bindings);
  List.iter
    (fun binding ->
      let name = binding.Kernel.bname in
      Alcotest.(check bool)
        (name ^ " signature bundle") true
        (contains
           (String.concat " " (comments Meta.key_trivia_trailing (Meta.signature binding.bmeta)))
           ("-- " ^ name ^ " signature tail"));
      Alcotest.(check bool)
        (name ^ " definition bundle") true
        (contains
           (String.concat " " (comments Meta.key_trivia_trailing binding.bmeta))
           ("-- " ^ name ^ " definition tail")))
    bindings

let test_structured_bootstrap_formatter () =
  let child_meta =
    Meta.empty
    |> Meta.with_trivia Meta.key_trivia [ Meta.Comment "; structured-leading" ]
    |> Meta.with_trivia Meta.key_trivia_trailing [ Meta.Comment "; structured-tail" ]
  in
  let child = Form.form ~meta:child_meta "lit" [ Form.Int 1 ] in
  let root_meta =
    Meta.with_trivia Meta.key_trivia_inner [ Meta.Comment "; structured-inner" ] Meta.empty
  in
  let root = Form.form ~meta:root_meta "app" [ Form.F child ] in
  let printed = Printer.format_all [ root ] in
  List.iter
    (fun comment -> Alcotest.(check int) comment 1 (count_occurrences printed comment))
    [ "; structured-leading"; "; structured-tail"; "; structured-inner" ];
  Alcotest.(check bool) "bootstrap introducers preserved" true (contains printed "; structured")

let test_canonical_metadata_inertia () =
  let lowered = lower_file "f(1)\n" in
  let top = match lowered.tops with [ top ] -> top | _ -> Alcotest.fail "canonical fixture" in
  let perturbed =
    match top with
    | Kernel.Expr expression ->
        Kernel.Expr
          {
            expression with
            Kernel.meta =
              expression.meta
              |> Meta.with_trivia Meta.key_trivia_inner [ Meta.Comment "-- metadata-inner" ]
              |> Meta.with_trivia Meta.key_trivia [ Meta.Comment "-- metadata-leading" ];
          }
    | _ -> Alcotest.fail "expected expression"
  in
  let print_top top =
    match Surface_print.print_top top with
    | Ok text -> text
    | Error diagnostics -> fail_diags "print top" diagnostics
  in
  let print_file tops =
    match Surface_print.print_file tops with
    | Ok text -> text
    | Error diagnostics -> fail_diags "print file" diagnostics
  in
  Alcotest.(check string) "exact canonical top" "f(1)" (print_top perturbed);
  Alcotest.(check string) "canonical top metadata inertia" (print_top top) (print_top perturbed);
  Alcotest.(check string) "exact canonical file" "f(1)\n" (print_file [ perturbed ]);
  Alcotest.(check string)
    "canonical file metadata inertia" (print_file [ top ]) (print_file [ perturbed ])

let test_printer_context_concurrency () =
  let source = "-- concurrent-leading\nf(1\n-- concurrent-inner\n) -- concurrent-tail\n" in
  let lowered = lower_file source in
  let canonical =
    match Surface_print.print_file lowered.tops with
    | Ok text -> text
    | Error diagnostics -> fail_diags "canonical concurrent" diagnostics
  in
  let trivia =
    match Surface_print.print_file_with_trivia lowered.tops with
    | Ok text -> text
    | Error diagnostics -> fail_diags "trivia concurrent" diagnostics
  in
  let run expected print =
    for _ = 1 to 250 do
      match print () with
      | Ok actual when String.equal actual expected -> ()
      | Ok actual -> Alcotest.failf "concurrent printer contamination:\n%s" actual
      | Error diagnostics -> fail_diags "concurrent printer" diagnostics
    done
  in
  let canonical_domain =
    Domain.spawn (fun () -> run canonical (fun () -> Surface_print.print_file lowered.tops))
  in
  let trivia_domain =
    Domain.spawn (fun () ->
        run trivia (fun () -> Surface_print.print_file_with_trivia lowered.tops))
  in
  Domain.join canonical_domain;
  Domain.join trivia_domain;
  Alcotest.(check bool) "canonical excludes comments" false (contains canonical "-- concurrent");
  Alcotest.(check bool) "trivia includes comments" true (contains trivia "-- concurrent-inner")

let suite =
  [
    Alcotest.test_case "exact top trivia and file anchor" `Quick
      test_exact_top_trivia_and_file_anchor;
    Alcotest.test_case "structured and legacy encoding" `Quick test_structured_encoding_and_legacy;
    Alcotest.test_case "semicolon and blank-line bytes" `Quick test_semicolon_and_blank_line_bytes;
    Alcotest.test_case "layout capture and normalization" `Quick
      test_layout_capture_normalizes_output;
    Alcotest.test_case "doc attachment" `Quick test_docs_attach_only_to_declarations;
    Alcotest.test_case "SCC binding ownership" `Quick test_scc_reorder_keeps_binding_trivia;
    Alcotest.test_case "nested ownership and printing" `Quick
      test_nested_ownership_and_print_idempotence;
    Alcotest.test_case "comment-free compatibility" `Quick test_comment_free_compatibility;
    Alcotest.test_case "container comment printing" `Quick test_container_comment_printing;
    Alcotest.test_case "hash and metadata law" `Quick test_hash_and_metadata_law;
    Alcotest.test_case "recovery boundaries" `Quick test_recovery_boundaries;
    Alcotest.test_case "missing delimiters and orphan docs" `Quick
      test_missing_delimiter_replay_and_orphan_docs;
    Alcotest.test_case "clause boundaries" `Quick test_clause_boundaries;
    Alcotest.test_case "parameter container ownership" `Quick test_parameter_container_ownership;
    Alcotest.test_case "all parenthesized containers" `Quick
      test_all_parenthesized_container_printing;
    Alcotest.test_case "remaining delimited containers" `Quick test_remaining_delimited_containers;
    Alcotest.test_case "block container provenance" `Quick test_block_container_provenance;
    Alcotest.test_case "raw bootstrap trivia" `Quick test_raw_top_and_quote_bootstrap_trivia;
    Alcotest.test_case "sequenced match arm trailing" `Quick test_match_sequence_arm_trailing;
    Alcotest.test_case "signature channels and doc suffix" `Quick
      test_signature_channels_and_doc_suffix;
    Alcotest.test_case "SCC signature bundles" `Quick test_scc_reorder_keeps_signature_bundles;
    Alcotest.test_case "structured bootstrap formatter" `Quick test_structured_bootstrap_formatter;
    Alcotest.test_case "canonical metadata inertia" `Quick test_canonical_metadata_inertia;
    Alcotest.test_case "printer context concurrency" `Quick test_printer_context_concurrency;
  ]
