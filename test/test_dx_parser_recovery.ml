open Jacquard

let fixture_root = "../corpus/surface/dx3"
let fixture kind name = Filename.concat (Filename.concat fixture_root kind) name
let read kind name = Corpus_support.read_file (fixture kind name)
let recover name = Surface_parse.recover_string ~file:name (read "malformed" name)
let rendered recovered = List.map Diag.to_string recovered.Surface_ast.diagnostics

let malformed_goldens =
  [
    ( "missing-quote.jac",
      [
        "missing-quote.jac:6:1-10: error[E1221]: unclosed `quote`: expected `}` before the \
         enclosing boundary\n\
        \  hint: the `quote` expression opened at missing-quote.jac:1:10-15";
      ] );
    ( "missing-match.jac",
      [
        "missing-match.jac:4:1-10: error[E1221]: unclosed `match`: expected `}` before the next \
         top-level item\n\
        \  hint: the `match` expression opened at missing-match.jac:1:10-15";
      ] );
    ( "missing-handler.jac",
      [
        "missing-handler.jac:4:1-10: error[E1221]: unclosed `handle`: expected `}` before the next \
         top-level item\n\
        \  hint: the `handle` expression opened at missing-handler.jac:1:16-22";
      ] );
    ( "missing-block.jac",
      [
        "missing-block.jac:4:1-10: error[E1221]: unclosed block: expected `}` before the next \
         top-level item\n\
        \  hint: the block opened at missing-block.jac:1:10-11";
      ] );
    ( "extra-delimiter.jac",
      [ "extra-delimiter.jac:2:1-2: error[E1220]: unmatched `}` at top level" ] );
    ( "eof-nested.jac",
      [
        "eof-nested.jac:5:1-1: error[E1221]: unclosed `quote`: expected `}` after the quoted \
         expression\n\
        \  hint: the `quote` expression opened at eof-nested.jac:1:17-22";
      ] );
    ( "missing-if-keyword.jac",
      [
        "missing-if-keyword.jac:1:18-19: error[E1220]: unclosed `if`: expected `then` after the \
         condition, found int(1)\n\
        \  hint: the `if` expression opened at missing-if-keyword.jac:1:10-12";
      ] );
    ( "mismatched-quote.jac",
      [
        "mismatched-quote.jac:1:28-29: error[E1221]: unclosed `quote`: expected `}`, found ]\n\
        \  hint: the `quote` expression opened at mismatched-quote.jac:1:15-20";
      ] );
    ( "mismatched-match.jac",
      [
        "mismatched-match.jac:3:1-2: error[E1221]: unclosed `match`: expected `}`, found ]\n\
        \  hint: the `match` expression opened at mismatched-match.jac:1:15-20";
      ] );
    ( "mismatched-handler.jac",
      [
        "mismatched-handler.jac:3:1-2: error[E1221]: unclosed `handle`: expected `}`, found ]\n\
        \  hint: the `handle` expression opened at mismatched-handler.jac:1:21-27";
      ] );
    ( "mismatched-block.jac",
      [
        "mismatched-block.jac:3:1-2: error[E1221]: unclosed block: expected `}`, found ]\n\
        \  hint: the block opened at mismatched-block.jac:1:15-16";
      ] );
  ]

let test_exact_construct_goldens_and_strictness () =
  List.iter
    (fun (name, expected) ->
      let recovered = recover name in
      Alcotest.(check (list string)) (name ^ " exact diagnostic") expected (rendered recovered);
      Alcotest.(check bool)
        (name ^ " carries a synthetic recovery marker")
        true
        (List.exists Surface_ast.has_holes_top recovered.items);
      match Surface_parse.strict_file recovered with
      | Error _ -> (
          let marker_only = { recovered with Surface_ast.diagnostics = [] } in
          match Surface_parse.strict_file marker_only with
          | Error [ { Diag.code = "E1202"; _ } ] -> ()
          | Error diagnostics ->
              Eval_support.fail_diags (name ^ " marker-only strict boundary") diagnostics
          | Ok _ -> Alcotest.failf "%s marker was accepted after diagnostics were removed" name)
      | Ok _ -> Alcotest.failf "%s was accepted by the strict boundary" name)
    malformed_goldens

let make_check_context () =
  let store, _ = Eval_support.make_prelude_ctx () in
  match Check.make_ctx store with
  | Error diagnostics -> Eval_support.fail_diags "DX.3 checker context" diagnostics
  | Ok context ->
      (match Prelude.builtin_signatures store with
      | Error diagnostics -> Eval_support.fail_diags "DX.3 builtin signatures" diagnostics
      | Ok signatures -> Check.register_builtin_signatures context signatures);
      (store, context)

let test_later_top_level_checking_is_bounded () =
  let names =
    [
      "missing-quote.jac";
      "missing-match.jac";
      "missing-handler.jac";
      "missing-block.jac";
      "extra-delimiter.jac";
      "missing-if-keyword.jac";
      "mismatched-quote.jac";
      "mismatched-match.jac";
      "mismatched-handler.jac";
      "mismatched-block.jac";
    ]
  in
  List.iter
    (fun name ->
      let store, context = make_check_context () in
      let report = Surface_check.analyze ~names:(Store.names_view store) context (recover name) in
      let codes = List.map (fun diagnostic -> diagnostic.Diag.code) report.diagnostics in
      Alcotest.(check int)
        (name ^ " has one primary syntax diagnostic")
        1
        (List.length
           (List.filter (fun code -> String.equal code "E1220" || String.equal code "E1221") codes));
      Alcotest.(check int)
        (name ^ " has one independent later type error")
        1
        (List.length (List.filter (String.equal "E0801") codes));
      Alcotest.(check bool)
        (name ^ " checks the later valid declaration")
        true
        (List.mem "later-good" (List.map fst report.signatures)))
    names

let format_strict file source =
  let recovered = Surface_parse.recover_string ~file source in
  match Surface_parse.strict_file recovered with
  | Error diagnostics -> Eval_support.fail_diags (file ^ " strict format parse") diagnostics
  | Ok parsed -> (
      match Surface_lower.lower_file parsed with
      | Error diagnostics -> Eval_support.fail_diags (file ^ " format lowering") diagnostics
      | Ok lowered -> (
          match Surface_print.print_file_with_trivia ~file_meta:lowered.meta lowered.tops with
          | Ok formatted -> formatted
          | Error diagnostics -> Eval_support.fail_diags (file ^ " surface print") diagnostics))

let hash_source file source =
  let store, _ = Eval_support.make_prelude_ctx () in
  let parsed =
    match Surface_parse.parse_string ~file source with
    | Ok tops -> tops
    | Error diagnostics -> Eval_support.fail_diags (file ^ " hash parse") diagnostics
  in
  let lowered =
    match Surface_lower.lower_tops parsed with
    | Ok tops -> tops
    | Error diagnostics -> Eval_support.fail_diags (file ^ " hash lowering") diagnostics
  in
  List.map
    (fun top ->
      let resolved =
        match Resolve.resolve (Store.names_view store) top with
        | Ok top -> top
        | Error diagnostics -> Eval_support.fail_diags (file ^ " hash resolution") diagnostics
      in
      match Canon.hash_top resolved with
      | Ok hashed -> Hash.to_hex hashed.Canon.decl_hash
      | Error diagnostics -> Eval_support.fail_diags (file ^ " canonical hash") diagnostics)
    lowered

let contains needle text =
  let rec loop offset =
    offset + String.length needle <= String.length text
    && (String.sub text offset (String.length needle) = needle || loop (offset + 1))
  in
  loop 0

let valid_names = [ "nested-quote-match.jac"; "nested-if-handler.jac"; "preflight-policy.jac" ]

let test_valid_nested_format_hash_and_namespace_stability () =
  List.iter
    (fun name ->
      let source = read "valid" name in
      let once = format_strict name source in
      let twice = format_strict name once in
      Alcotest.(check string) (name ^ " formats idempotently") once twice;
      Alcotest.(check (list string))
        (name ^ " formatting preserves canonical hash")
        (hash_source name source) (hash_source name once))
    valid_names;
  let preflight = format_strict "preflight-policy.jac" (read "valid" "preflight-policy.jac") in
  Alcotest.(check bool)
    "surface-ref-v0 operation namespace survives formatting" true
    (contains "`op:net.request`" preflight)

let closing_braces source =
  let rec loop offset found =
    match String.index_from_opt source offset '}' with
    | None -> List.rev found
    | Some index -> loop (index + 1) (index :: found)
  in
  loop 0 []

let delete_at source index =
  String.sub source 0 index ^ String.sub source (index + 1) (String.length source - index - 1)

let substring_offsets needle source =
  let needle_length = String.length needle in
  let rec loop offset found =
    if offset + needle_length > String.length source then List.rev found
    else if String.sub source offset needle_length = needle then
      loop (offset + needle_length) (offset :: found)
    else loop (offset + 1) found
  in
  loop 0 []

let choose_index choice items = List.nth items (choice mod List.length items)

let delete_range source offset length =
  String.sub source 0 offset
  ^ String.sub source (offset + length) (String.length source - offset - length)

let replace_at source index replacement =
  String.sub source 0 index ^ String.make 1 replacement
  ^ String.sub source (index + 1) (String.length source - index - 1)

let has_definition name tops =
  List.exists
    (function
      | { Surface_ast.it = Surface_ast.Definition { name = found; _ }; _ } ->
          String.equal name found
      | _ -> false)
    tops

let damaged_case source_choice mutation_choice position_choice =
  let valid_name = choose_index source_choice valid_names in
  let valid_source = read "valid" valid_name in
  let with_later source = (source ^ "\nlater-good = 42\n", true) in
  match mutation_choice mod 6 with
  | 0 ->
      let source = read "valid" "nested-if-handler.jac" in
      let offset = choose_index position_choice (substring_offsets "then" source) in
      ("delete-then.jac", with_later (delete_range source offset 4))
  | 1 ->
      let source = read "valid" "nested-if-handler.jac" in
      let offset = choose_index position_choice (substring_offsets "else" source) in
      ("delete-else.jac", with_later (delete_range source offset 4))
  | 2 ->
      let offset = choose_index position_choice (closing_braces valid_source) in
      ("delete-close.jac", with_later (delete_at valid_source offset))
  | 3 ->
      let offset = choose_index position_choice (closing_braces valid_source) in
      ("right-paren-close.jac", with_later (replace_at valid_source offset ')'))
  | 4 ->
      let offset = choose_index position_choice (closing_braces valid_source) in
      ("right-bracket-close.jac", with_later (replace_at valid_source offset ']'))
  | _ ->
      let offset = choose_index position_choice (closing_braces valid_source) in
      ("truncated-nesting.jac", (String.sub valid_source 0 offset, false))

let test_mutated_nested_delimiters_never_escape () =
  let property =
    QCheck.Test.make ~count:300 ~name:"surface recovery rejects structural mutations"
      QCheck.(triple nat_small nat_small nat_small)
      (fun (source_choice, mutation_choice, position_choice) ->
        let file, (damaged, expect_later) =
          damaged_case source_choice mutation_choice position_choice
        in
        let recovered = Surface_parse.recover_string ~file damaged in
        recovered.diagnostics <> []
        && List.exists Surface_ast.has_holes_top recovered.items
        && Result.is_error (Surface_parse.strict recovered)
        && Result.is_error (Surface_parse.parse_string ~file damaged)
        && ((not expect_later) || has_definition "later-good" recovered.items))
  in
  QCheck.Test.check_exn ~rand:(Random.State.make [| 0xD3; 0x167; 0x51 |]) property

let run () =
  test_exact_construct_goldens_and_strictness ();
  test_later_top_level_checking_is_bounded ();
  test_valid_nested_format_hash_and_namespace_stability ();
  test_mutated_nested_delimiters_never_escape ()
