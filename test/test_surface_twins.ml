open Jacquard

let valid_dir = "../corpus/valid"

let contains needle text =
  let rec loop index =
    index + String.length needle <= String.length text
    && (String.sub text index (String.length needle) = needle || loop (index + 1))
  in
  loop 0

let fail_pipeline path (stage, diagnostics) =
  Alcotest.failf "%s failed at %s:\n%s" path (Corpus_support.stage_name stage)
    (String.concat "\n" (List.map Diag.to_string diagnostics))

let hashes_of_bootstrap path =
  let source = Corpus_support.read_file path in
  match Corpus_support.bootstrap_tops ~file:path source with
  | Error failure -> fail_pipeline path failure
  | Ok tops -> (
      match Corpus_support.resolve_and_hash tops with
      | Ok hashes -> hashes
      | Error failure -> fail_pipeline path failure)

let hashes_of_surface_source ~path source =
  match Corpus_support.surface_tops ~file:path source with
  | Error failure -> fail_pipeline path failure
  | Ok tops -> (
      match Corpus_support.resolve_and_hash tops with
      | Ok hashes -> hashes
      | Error failure -> fail_pipeline path failure)

let hashes_of_surface path = hashes_of_surface_source ~path (Corpus_support.read_file path)
let bases extension files = List.map (fun file -> Filename.remove_extension file ^ extension) files

let test_twin_inventory_and_identity () =
  let bootstrap_files = Corpus_support.jqd_files valid_dir in
  let surface_files = Corpus_support.jac_files valid_dir in
  Alcotest.(check (list string))
    "every valid bootstrap program has exactly one surface twin" (bases ".jac" bootstrap_files)
    surface_files;
  List.iter
    (fun bootstrap_file ->
      let surface_file = Filename.remove_extension bootstrap_file ^ ".jac" in
      let bootstrap_path = Filename.concat valid_dir bootstrap_file in
      let surface_path = Filename.concat valid_dir surface_file in
      let bootstrap_hashes = hashes_of_bootstrap bootstrap_path in
      let surface_hashes = hashes_of_surface surface_path in
      let expected = Corpus_support.identity_lines bootstrap_hashes in
      let actual = Corpus_support.identity_lines surface_hashes in
      if expected <> actual then
        Alcotest.fail
          (Corpus_support.twin_mismatch_message ~bootstrap_path ~bootstrap_hashes ~surface_path
             ~surface_hashes))
    bootstrap_files

let test_pinned_field_feedback_twins () =
  let snippets =
    [
      ("multi-effect-signature.jac", "() ->{Net, Clock} Int) ->{} Int");
      ("pipe-transformation.jac", "items |> list.map");
      ("handler-policy.jac", "| abort() resume k -> None");
      ("nested-tuple-destructure.jac", "Some((head, children))");
    ]
  in
  List.iter
    (fun (file, snippet) ->
      let path = Filename.concat valid_dir file in
      Alcotest.(check bool)
        (file ^ " retains its pinned surface pattern")
        true
        (contains snippet (Corpus_support.read_file path)))
    snippets

let test_constructor_case_fold_keeps_folded_identity () =
  let bootstrap_path = Filename.concat valid_dir "case-fold-constructor.jqd" in
  let surface_path = Filename.concat valid_dir "case-fold-constructor.jac" in
  let surface = Corpus_support.read_file surface_path in
  Alcotest.(check bool)
    "printer projects lowercase `some` to PascalCase `Some`" true (contains "Some(1)" surface);
  let tops =
    match Corpus_support.surface_tops ~file:surface_path surface with
    | Ok tops -> tops
    | Error failure -> fail_pipeline surface_path failure
  in
  (match tops with
  | [ Kernel.Expr { it = Kernel.App ({ it = Kernel.Var "some"; meta; _ }, [ _ ]); _ } ] ->
      Alcotest.(check (option string))
        "PascalCase parse retains constructor namespace" (Some "con") (Meta.surface_ref_kind meta)
  | _ -> Alcotest.fail "case-fold twin did not lower to a constructor-headed `some` application");
  (match List.map (Resolve.resolve Corpus_support.stub_names) tops with
  | [ Ok (Kernel.Expr { it = Kernel.App ({ it = Kernel.Ref (hash, Kernel.Con); _ }, [ _ ]); _ }) ]
    ->
      Alcotest.(check string)
        "PascalCase head resolves to the indexed hash-plus-ordinal constructor identity"
        (Hash.to_hex (Corpus_support.stub_hash "some"))
        (Hash.to_hex hash)
  | _ -> Alcotest.fail "case-fold twin did not resolve to a constructor reference");
  let bootstrap_hashes = hashes_of_bootstrap bootstrap_path in
  let surface_hashes = hashes_of_surface surface_path in
  Alcotest.(check (list string))
    "case-fold twin resolves to the same folded constructor hash identity"
    (Corpus_support.identity_lines bootstrap_hashes)
    (Corpus_support.identity_lines surface_hashes)

let test_surface_comments_and_formatting_do_not_change_hash () =
  let path = Filename.concat valid_dir "case-fold-constructor.jac" in
  let original = hashes_of_surface path in
  let edited_path = "edited-case-fold-constructor.jac" in
  let edited = "-- identity must ignore this comment\n\n  Some(  1  )\n" in
  let edited_hashes = hashes_of_surface_source ~path:edited_path edited in
  Alcotest.(check (list string))
    "comments and formatting are hash-excluded"
    (Corpus_support.identity_lines original)
    (Corpus_support.identity_lines edited_hashes)

let test_mismatch_report_names_both_inputs_and_hashes () =
  let bootstrap_path = "left/program.jqd" in
  let surface_path = "right/program.jac" in
  let bootstrap_hashes =
    match Corpus_support.bootstrap_tops ~file:bootstrap_path "(lit 1)" with
    | Error failure -> fail_pipeline bootstrap_path failure
    | Ok tops -> (
        match Corpus_support.resolve_and_hash tops with
        | Ok hashes -> hashes
        | Error failure -> fail_pipeline bootstrap_path failure)
  in
  let surface_hashes = hashes_of_surface_source ~path:surface_path "2\n" in
  let message =
    Corpus_support.twin_mismatch_message ~bootstrap_path ~bootstrap_hashes ~surface_path
      ~surface_hashes
  in
  let bootstrap_hash = (List.hd bootstrap_hashes).Canon.decl_hash |> Hash.to_hex in
  let surface_hash = (List.hd surface_hashes).Canon.decl_hash |> Hash.to_hex in
  Alcotest.(check bool)
    "deliberate mismatch uses distinct hashes" false
    (String.equal bootstrap_hash surface_hash);
  List.iter
    (fun expected ->
      Alcotest.(check bool)
        ("mismatch report contains " ^ expected)
        true (contains expected message))
    [ bootstrap_path; surface_path; bootstrap_hash; surface_hash ]

let suite =
  [
    Alcotest.test_case "all valid corpus twins have identical identity" `Quick
      test_twin_inventory_and_identity;
    Alcotest.test_case "field-feedback surface patterns stay pinned" `Quick
      test_pinned_field_feedback_twins;
    Alcotest.test_case "constructor case fold keeps folded identity" `Quick
      test_constructor_case_fold_keeps_folded_identity;
    Alcotest.test_case "comments and formatting preserve twin hash" `Quick
      test_surface_comments_and_formatting_do_not_change_hash;
    Alcotest.test_case "mismatch report is actionable" `Quick
      test_mismatch_report_names_both_inputs_and_hashes;
  ]
