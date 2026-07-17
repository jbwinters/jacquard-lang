open Jacquard

let valid_dir = "../corpus/valid"

let tops_of_file path =
  match Reader.parse_string ~file:path (Corpus_support.read_file path) with
  | Error ds -> Eval_support.fail_diags "surface totality read" ds
  | Ok forms ->
      List.map
        (fun form ->
          match Kernel.of_form form with
          | Ok top -> top
          | Error ds -> Eval_support.fail_diags "surface totality validate" ds)
        forms

let print_file label tops =
  match Surface_print.print_file tops with
  | Ok text ->
      if tops <> [] && String.equal text "" then
        Alcotest.failf "%s: nonempty kernel file rendered as empty text" label
  | Error ds -> Eval_support.fail_diags label ds

let test_valid_corpus_printer_totality () =
  let files = Corpus_support.jqd_files valid_dir in
  Alcotest.(check bool) "nonempty corpus" true (files <> []);
  List.iter
    (fun file ->
      let path = Filename.concat valid_dir file in
      let tops = tops_of_file path in
      print_file (file ^ " unresolved") tops;
      let resolved =
        List.map
          (fun top ->
            match Resolve.resolve Corpus_support.stub_names top with
            | Ok resolved -> resolved
            | Error ds -> Eval_support.fail_diags (file ^ " resolve") ds)
          tops
      in
      print_file (file ^ " resolved") resolved)
    files

let grammar_snapshot source =
  let marker = "### One-page grammar" in
  let opening = "```text\n" in
  let marker_at = Str.search_forward (Str.regexp_string marker) source 0 in
  let body_at =
    Str.search_forward (Str.regexp_string opening) source marker_at + String.length opening
  in
  let closing_at = Str.search_forward (Str.regexp_string "\n```") source body_at in
  String.sub source body_at (closing_at - body_at) ^ "\n"

let test_one_page_grammar_snapshot () =
  let grammar = grammar_snapshot (Corpus_support.read_file "../docs/surface-syntax.md") in
  let lines =
    String.split_on_char '\n' grammar |> List.filter (fun line -> not (String.equal line ""))
  in
  Alcotest.(check bool) "L7 grammar stays within 100 nonblank lines" true (List.length lines <= 100);
  Alcotest.(check string)
    "L7 grammar snapshot (review docs/surface-syntax.md before updating)"
    "e564dd92d4b632d4cd8b724ba8bf830ba2489527387c74e93e722ac7b808ffc8"
    (Hash.to_hex (Hash.of_string grammar))

let format_surface path source =
  let recovered = Surface_parse.recover_string ~file:path source in
  match Surface_print.print_recovered recovered with
  | Ok text -> text
  | Error diagnostics -> Eval_support.fail_diags (path ^ " format") diagnostics

let contains needle text =
  let rec loop index =
    index + String.length needle <= String.length text
    && (String.sub text index (String.length needle) = needle || loop (index + 1))
  in
  loop 0

let test_surface_formatter_corpus_stability () =
  let dir = "../corpus/surface" in
  let files =
    Sys.readdir dir |> Array.to_list
    |> List.filter (fun file -> Filename.check_suffix file ".jac")
    |> List.sort String.compare
  in
  Alcotest.(check int) "task 103 formatter corpus size" 3 (List.length files);
  List.iter
    (fun file ->
      let path = Filename.concat dir file in
      let once = format_surface path (Corpus_support.read_file path) in
      let twice = format_surface path once in
      Alcotest.(check string) (file ^ " L2") once twice;
      match file with
      | "formatter-sequenced-arm.jac" ->
          Alcotest.(check bool) "B1 sequenced arm is braced" true (contains "| True -> {" once)
      | "formatter-long-arm.jac" ->
          Alcotest.(check bool)
            "B1 long single expression is unbraced" false (contains "| True -> {" once)
      | "formatter-constructors.jac" ->
          Alcotest.(check bool)
            "B5 long constructor list is vertical" true
            (contains "type DeploymentOutcome =\n  | CompletelyClear\n" once)
      | _ -> Alcotest.failf "unexpected formatter corpus file %s" file)
    files

let test_constructor_standard_width_boundary () =
  let render constructor_length =
    let constructor = "A" ^ String.make (constructor_length - 1) 'a' in
    format_surface "constructors.jac" (Printf.sprintf "type T = | %s | B\n" constructor)
  in
  let fits = render 85 in
  let breaks = render 86 in
  Alcotest.(check int)
    "100-column declaration stays on one line" 100
    (String.length (String.trim fits));
  Alcotest.(check bool) "100 columns is inline" false (contains "type T =\n" fits);
  Alcotest.(check string)
    "101 columns breaks before constructors" "type T =\n"
    (String.sub breaks 0 (String.length "type T =\n"));
  Alcotest.(check int)
    "one constructor per line after boundary" 2
    (String.split_on_char '\n' (String.trim breaks) |> List.tl |> List.length);
  Alcotest.(check bool) "second constructor has its own line" true (contains "\n  | B\n" breaks)

let trim = String.trim

let source_root =
  lazy
    (if Sys.file_exists "../../../dune-project" then "../../.."
     else if Sys.file_exists "dune-project" then "."
     else Alcotest.fail "cannot locate repository root for release evidence")

let source_path relative = Filename.concat (Lazy.force source_root) relative
let read_source relative = Corpus_support.read_file (source_path relative)

let section heading source =
  let lines = String.split_on_char '\n' source in
  let rec seek = function
    | [] -> None
    | line :: rest -> if String.equal (trim line) heading then collect [ line ] rest else seek rest
  and collect rev_lines = function
    | line :: _ when String.starts_with ~prefix:"## " (trim line) ->
        Some (String.concat "\n" (List.rev rev_lines))
    | line :: rest -> collect (line :: rev_lines) rest
    | [] -> Some (String.concat "\n" (List.rev rev_lines))
  in
  seek lines

let table_cells line =
  match String.split_on_char '|' line |> List.map trim with
  | "" :: cells -> ( match List.rev cells with "" :: rev_cells -> List.rev rev_cells | _ -> cells)
  | cells -> cells

let table_rows text =
  let rec seek = function
    | [] -> []
    | line :: rest ->
        let line = trim line in
        if String.starts_with ~prefix:"|" line then collect [ table_cells line ] rest else seek rest
  and collect rev_rows = function
    | line :: rest ->
        let line = trim line in
        if String.starts_with ~prefix:"|" line then collect (table_cells line :: rev_rows) rest
        else List.rev rev_rows
    | [] -> List.rev rev_rows
  in
  String.split_on_char '\n' text |> seek
  |> List.filter (function
    | first :: _ ->
        not
          (String.equal first "ID" || String.equal first "inventory" || String.equal first "command"
          || String.for_all (function '-' | ':' -> true | _ -> false) first)
    | [] -> false)

let test_table_rows_stop_at_later_subheading () =
  let markdown =
    "intro\n\
     | ID | status |\n\
     |---|---|\n\
     | D38 | shipped |\n\n\
     ### Later audit\n\n\
     | ID | status |\n\
     |---|---|\n\
     | D38 | adjusted |\n"
  in
  Alcotest.(check (list (list string)))
    "only the intended first table is parsed"
    [ [ "D38"; "shipped" ] ]
    (table_rows markdown)

let code_tokens text =
  let rec loop start acc =
    match String.index_from_opt text start '`' with
    | None -> List.rev acc
    | Some opening -> (
        match String.index_from_opt text (opening + 1) '`' with
        | None -> List.rev acc
        | Some closing ->
            let token = String.sub text (opening + 1) (closing - opening - 1) in
            loop (closing + 1) (token :: acc))
  in
  loop 0 []

let markdown_links text =
  let rec loop start acc =
    match Str.search_forward (Str.regexp_string "](") text start with
    | exception Not_found -> List.rev acc
    | opening -> (
        let target_start = opening + 2 in
        match String.index_from_opt text target_start ')' with
        | None -> List.rev acc
        | Some closing ->
            let target = String.sub text target_start (closing - target_start) in
            loop (closing + 1) (target :: acc))
  in
  loop 0 []

let replace_once ~needle ~replacement text =
  match Str.search_forward (Str.regexp_string needle) text 0 with
  | exception Not_found -> Alcotest.failf "mutation needle not found: %s" needle
  | index ->
      String.sub text 0 index ^ replacement
      ^ String.sub text
          (index + String.length needle)
          (String.length text - index - String.length needle)

let sorted_directory_files dir suffix =
  Sys.readdir (source_path dir)
  |> Array.to_list
  |> List.filter (fun file -> Filename.check_suffix file suffix)
  |> List.sort String.compare

let compiled_test_inventory =
  lazy
    (let argv = [| Sys.argv.(0); "list"; "--color=never" |] in
     let channel = Unix.open_process_args_in Sys.argv.(0) argv in
     let rec read lines =
       match input_line channel with
       | line ->
           let line = trim line in
           let is_case = not (String.equal line "" || contains "qcheck random seed:" line) in
           read (if is_case then line :: lines else lines)
       | exception End_of_file -> List.rev lines
     in
     let inventory = read [] in
     match Unix.close_process_in channel with
     | Unix.WEXITED 0 -> inventory
     | _ -> Alcotest.fail "compiled Alcotest inventory command failed")

let compiled_test_count = lazy (List.length (Lazy.force compiled_test_inventory))

let compiled_group_count group =
  let prefix = group ^ " " in
  Lazy.force compiled_test_inventory
  |> List.fold_left
       (fun count line -> if String.starts_with ~prefix line then count + 1 else count)
       0

let rec count_files_with_suffix path suffix =
  Sys.readdir path |> Array.to_list
  |> List.fold_left
       (fun count entry ->
         let child = Filename.concat path entry in
         match (Unix.stat child).st_kind with
         | Unix.S_DIR -> count + count_files_with_suffix child suffix
         | Unix.S_REG when Filename.check_suffix entry suffix -> count + 1
         | _ -> count)
       0

let claimed_inventory_count ~path ~prefix source =
  match
    source |> String.split_on_char '\n'
    |> List.find_opt (fun line -> String.starts_with ~prefix line)
  with
  | None -> Error (Printf.sprintf "%s is missing `%s`" path prefix)
  | Some line -> (
      match code_tokens line with
      | [ count ] -> (
          match int_of_string_opt count with
          | Some count -> Ok count
          | None -> Error (Printf.sprintf "%s has a non-integer `%s` count" path prefix))
      | _ -> Error (Printf.sprintf "%s must state exactly one `%s` count" path prefix))

let inventory_claim_errors ~path claims =
  let source = read_source path in
  claims
  |> List.filter_map (fun (prefix, expected) ->
      match claimed_inventory_count ~path ~prefix source with
      | Ok claimed when claimed = expected -> None
      | Ok claimed ->
          Some
            (Printf.sprintf "%s `%s` is stale (claimed %d, expected %d)" path prefix claimed
               expected)
      | Error message -> Some message)

let release_inventory_errors () =
  let actual_tests = Lazy.force compiled_test_count in
  let actual_crams = count_files_with_suffix (source_path "test") ".t" in
  let concurrency_path = "docs/release/structured-concurrency/EVIDENCE.md" in
  let concurrency_evidence = read_source concurrency_path in
  let channel_cases = compiled_group_count "channel-contract" in
  let channel_row = Printf.sprintf "| `channel-contract` | %d |" channel_cases in
  inventory_claim_errors ~path:"docs/release/0.1/EVIDENCE.md"
    [ ("- Alcotest/QCheck cases:", 554); ("- Cram transcript files:", 32) ]
  @ inventory_claim_errors ~path:"docs/release/0.1/DECISION.md"
      [ ("Test count:", 554); ("Cram count:", 32) ]
  @ inventory_claim_errors ~path:"docs/release/dx-jac-export/EVIDENCE.md"
      [ ("- Alcotest/QCheck cases:", actual_tests); ("- Cram transcript files:", actual_crams) ]
  @ inventory_claim_errors ~path:concurrency_path
      [ ("- Alcotest/QCheck cases:", actual_tests); ("- Cram transcript files:", actual_crams) ]
  @
  if contains channel_row concurrency_evidence then []
  else
    [
      Printf.sprintf "%s compiled-discovery table is stale (expected row prefix `%s`)"
        concurrency_path channel_row;
    ]

let doctest_names () =
  [
    "README.md";
    "docs/effect-taxonomy.md";
    "docs/concurrency.md";
    "docs/effect-membranes.md";
    "docs/tutorial.md";
    "docs/stdlib.md";
    "docs/warp-testing.md";
    "demos/README.md";
  ]
  |> List.concat_map (fun path ->
      read_source path |> String.split_on_char '\n'
      |> List.filter_map (fun line ->
          match
            if String.starts_with ~prefix:"```jacquard " line then
              Str.search_forward (Str.regexp_string "doctest=") line 0
            else raise Not_found
          with
          | exception Not_found -> None
          | index ->
              let start = index + String.length "doctest=" in
              let stop =
                match String.index_from_opt line start ' ' with
                | Some stop -> stop
                | None -> String.length line
              in
              Some (String.sub line start (stop - start))))
  |> List.sort String.compare

let twin_names () =
  sorted_directory_files "corpus/valid" ".jac"
  |> List.filter (fun jac ->
      let stem = Filename.remove_extension jac in
      Sys.file_exists (source_path (Filename.concat "corpus/valid" (stem ^ ".jqd"))))

let demo_names () =
  let root = source_path "demos" in
  let root_symlinks =
    Sys.readdir root |> Array.to_list
    |> List.filter (fun entry -> (Unix.lstat (Filename.concat root entry)).st_kind = Unix.S_LNK)
    |> List.sort String.compare
  in
  if root_symlinks <> [] then
    Alcotest.failf "demos/ must not contain compatibility symlinks: %s"
      (String.concat ", " root_symlinks);
  [ "demos/basics"; "demos/inference"; "demos/tooling"; "demos/worlds" ]
  |> List.concat_map (fun dir -> sorted_directory_files dir ".jac")
  |> List.sort String.compare

let anchor_of_heading heading =
  let buffer = Buffer.create (String.length heading) in
  let pending_dash = ref false in
  String.lowercase_ascii heading
  |> String.iter (function
    | ('a' .. 'z' | '0' .. '9') as c ->
        if !pending_dash && Buffer.length buffer > 0 then Buffer.add_char buffer '-';
        pending_dash := false;
        Buffer.add_char buffer c
    | ' ' | '-' -> pending_dash := true
    | _ -> ());
  Buffer.contents buffer

let link_resolves ~decision_path ~followups target =
  let path, anchor =
    match String.index_opt target '#' with
    | None -> (target, None)
    | Some index ->
        ( String.sub target 0 index,
          Some (String.sub target (index + 1) (String.length target - index - 1)) )
  in
  let absolute = Filename.concat (Filename.dirname (source_path decision_path)) path in
  if not (Sys.file_exists absolute) then false
  else
    match anchor with
    | None -> true
    | Some expected ->
        let contents =
          if String.equal (Filename.basename path) "FOLLOWUPS.md" then followups
          else Corpus_support.read_file absolute
        in
        contents |> String.split_on_char '\n'
        |> List.exists (fun line ->
            let line = trim line in
            String.starts_with ~prefix:"## " line
            && String.equal expected
                 (anchor_of_heading (String.sub line 3 (String.length line - 3))))

let manifest_errors () =
  let manifest = read_source "docs/release/surface-syntax/MANIFEST.sha256" in
  let errors = ref [] in
  let add message = errors := message :: !errors in
  if not (contains "# Base commit: 07bf8aa71d197603c3830bd595ef7dd1e33e6bee" manifest) then
    add "manifest base commit is not 07bf8aa";
  if
    not
      (String.equal
         (manifest |> Hash.of_string |> Hash.to_hex)
         "c8c245de2c999c805a3902089d9f2c23f698931a451b93e354514811cc069515")
  then add "historical SS.22 manifest bytes changed";
  let entries =
    manifest |> String.split_on_char '\n'
    |> List.filter_map (fun line ->
        let line = trim line in
        if String.equal line "" || String.starts_with ~prefix:"#" line then None
        else
          match Str.split (Str.regexp "[ \t]+") line with
          | [ digest; path ] when String.length digest = 64 -> Some (digest, path)
          | _ ->
              add ("malformed manifest row: " ^ line);
              None)
  in
  let historical_inventory =
    [
      "corpus/golden/hashes.golden";
      "corpus/golden/prelude-hashes.golden";
      "corpus/golden/ring0-freeze.golden";
      "corpus/sigs/24-ring2.jqd";
      "corpus/valid/stdlib-ss22.jac";
      "corpus/valid/stdlib-ss22.jqd";
      "demos/clarifying-question.jac";
      "demos/clarifying-question.jqd";
      "demos/cookbook.jqd";
      "demos/repair.jac";
      "demos/repair.jqd";
      "docs/README.md";
      "docs/SKILL.md";
      "docs/native-intrinsics.md";
      "docs/release/surface-syntax/DECISION.md";
      "docs/release/surface-syntax/FOLLOWUPS.md";
      "docs/stdlib.md";
      "prelude/04-builtins.jqd";
      "prelude/07-enum.jqd";
      "prelude/09-grid.jqd";
      "prelude/11-text.jqd";
      "prelude/13-dist-lib.jqd";
      "prelude/16-gen.jqd";
      "prelude/rings.manifest";
      "runtime/jq_apply.c";
      "runtime/jq_intrinsics.c";
      "runtime/jq_value.h";
      "scripts/release/check-surface-syntax-manifest.sh";
      "src/check.ml";
      "src/native/build.ml";
      "src/native/compile.ml";
      "src/native/emit.ml";
      "src/native/spec.ml";
      "src/prelude.ml";
      "src/tier.ml";
      "src/types.ml";
      "test/cli/native-effects.t";
      "test/cli/dune";
      "test/cli/ss22.t";
      "test/cli/surface.t";
      "test/cli/tiers.t";
      "test/corpus_support.ml";
      "test/docs-doctest/fixtures/stdlib-text-join.jac";
      "test/docs-doctest/fixtures/stdlib-text-join.stdout";
      "test/dune";
      "test/native-gauntlet/MAPPING.md";
      "test/native-gauntlet/e07-erasure-text-join.jqd";
      "test/native-gauntlet/g31-repair-pure.jqd";
      "test/native-gauntlet/g35-stdlib-ss22.jqd";
      "test/native-asan/join-bad-early.jqd";
      "test/native-asan/join-bad-first-class.jqd";
      "test/native-asan/join-bad-last.jqd";
      "test/native-asan/join-bad-middle.jqd";
      "test/test_prelude.ml";
      "test/test_surface_laws.ml";
      "test/test_text.ml";
      "test/test_tier.ml";
    ]
  in
  let paths = List.map snd entries |> List.sort String.compare in
  let expected = List.sort String.compare historical_inventory in
  if paths <> expected then add "immutable historical manifest inventory is not exact";
  List.rev !errors

let validate_release_docs ~decision ~followups ~index =
  let errors = ref [] in
  let add message = errors := message :: !errors in
  let require condition message = if not condition then add message in
  let exact_table heading expected_rows allowed_statuses =
    match section heading decision with
    | None -> add ("missing section " ^ heading)
    | Some body ->
        let rows = table_rows body in
        List.iter
          (function
            | [] -> add ("internal empty reviewed row in " ^ heading)
            | id :: expected_tail as expected_row -> (
                let matches =
                  List.filter (function row_id :: _ -> String.equal row_id id | [] -> false) rows
                in
                match matches with
                | [ _; _ ] | _ :: _ :: _ -> add (id ^ " has more than one row")
                | [] -> add (id ^ " has no row")
                | [ (_ :: status :: _ as actual_row) ] ->
                    if not (List.mem status allowed_statuses) then
                      add (id ^ " has disallowed status " ^ status);
                    let expected_status = List.hd expected_tail in
                    if not (String.equal status expected_status) then
                      add (Printf.sprintf "%s status must be %s, not %s" id expected_status status);
                    if actual_row <> expected_row then
                      add (id ^ " semantic contract does not match the reviewed row")
                | [ _ ] -> add (id ^ " row has the wrong number of columns")))
          expected_rows;
        List.iter
          (function
            | id :: _
              when not (List.exists (fun row -> String.equal id (List.hd row)) expected_rows) ->
                add (id ^ " is an unexpected row in " ^ heading)
            | _ -> ())
          rows
  in
  exact_table "## Law Status"
    [
      [
        "L1";
        "bounded";
        "[surface laws](../../../test/test_surface_laws.ml), [printer \
         inventory](../../../test/test_surface_print.ml), \
         [types](../../../test/test_surface_types.ml), and [handlers and \
         quote](../../../test/test_surface_handlers_quote.ml) cover the valid corpus and \
         kernel-form families, including `jqd` fallbacks; this is not a generated proof over every \
         tree.";
      ];
      [
        "L2";
        "pinned";
        "[surface laws](../../../test/test_surface_laws.ml), [trivia \
         tests](../../../test/test_surface_trivia.ml), and [CLI \
         formatting](../../../test/cli/surface.t) pin formatter idempotence for the formatter \
         corpus and CLI lane. Damaged recovery trees replay their original bytes.";
      ];
      [
        "L3";
        "pinned";
        "[twin harness](../../../test/test_surface_twins.ml), [demo \
         transcript](../../../test/cli/demos.t), [inference \
         transcript](../../../test/cli/infer.t), and [repair \
         transcript](../../../test/cli/repair.t) pin identity for the complete inventories below; \
         this is corpus evidence, not a second semantics.";
      ];
      [
        "L4";
        "pinned";
        "[surface sugar](../../../test/test_surface_sugar.ml) and [control \
         sugar](../../../test/test_surface_control_sugar.ml) pin exact local lowering and hash \
         behavior for every shipped sugar.";
      ];
      [
        "L5";
        "pinned";
        "[surface sugar](../../../test/test_surface_sugar.ml), [control \
         sugar](../../../test/test_surface_control_sugar.ml), [handlers and \
         quote](../../../test/test_surface_handlers_quote.ml), [checker \
         diagnostics](../../../test/test_surface_check.ml), and [CLI \
         diagnostics](../../../test/cli/surface.t) pin the named provenance and diagnostic matrix.";
      ];
      [
        "L6";
        "pinned";
        "[trivia tests](../../../test/test_surface_trivia.ml), [type \
         trivia](../../../test/test_surface_types.ml), [surface \
         laws](../../../test/test_surface_laws.ml), and [CLI \
         formatting](../../../test/cli/surface.t) pin comments, docs, order, ownership, \
         metadata/hash inertia, and idempotence under the stated canonicalization contract.";
      ];
      [
        "L7";
        "pinned";
        "[surface laws](../../../test/test_surface_laws.ml) mechanically require the one-page \
         grammar to remain at most 100 nonblank lines and retain its reviewed digest.";
      ];
    ]
    [ "bounded"; "pinned" ];
  exact_table "## Decision Conformance"
    [
      [
        "D34";
        "shipped";
        "[scaffold](../../../test/test_surface_scaffold.ml), \
         [patterns](../../../test/test_surface_patterns.ml), and \
         [twins](../../../test/test_surface_twins.ml) pin shared case projection and escapes.";
        "none";
      ];
      [
        "D35";
        "shipped";
        "[handlers and quote](../../../test/test_surface_handlers_quote.ml) and \
         [printing](../../../test/test_surface_print.ml) pin atomic handler bodies and mandatory \
         blocks for non-atomic bodies.";
        "none";
      ];
      [
        "D36";
        "partial";
        "The labeled-field portion shipped in SS.8: [declaration \
         tests](../../../test/test_surface_decls.ml), [trivia \
         tests](../../../test/test_surface_trivia.ml), and [printing \
         tests](../../../test/test_surface_print.ml) pin parsing, metadata, trivia, lowering, and \
         rendering. [CLI evidence](../../../test/cli/surface.t) pins `pair.left` as absent with \
         `E0301`; generated accessor definitions and label validation, including duplicate-label \
         rejection, are deliberate follow-ups. Labeled patterns remain deferred.";
        "[D36 acceptance criteria](FOLLOWUPS.md#d36-generated-constructor-accessors)";
      ];
      [
        "D37";
        "shipped";
        "[lexer tests](../../../test/test_surface_lex.ml) and [parser \
         tests](../../../test/test_surface_parse.ml) pin dotted names as atomic and preserve \
         namespace puns.";
        "none";
      ];
      [
        "D38";
        "shipped";
        "SS.22 ships a new callable variadic `text.join` object with an unbounded \
         language/interpreter contract and strict argument evidence in [prelude \
         tests](../../../test/test_prelude.ml), [CLI/native/ASAN boundary \
         evidence](../../../test/cli/ss22.t), and [executable stdlib \
         documentation](../../stdlib.md). Deprecated migration-only `text.join-list` preserves the \
         pre-SS.22 list-plus-separator object hash-for-hash. Native v1 variadic parity is limited \
         to 0-8 arguments; 9 is E1101 under its global ABI ceiling. Interpolation remains absent.";
        "none";
      ];
      [
        "D39";
        "shipped";
        "SS.22 ships all four `int.*` and `real.*` predicates plus dotted real arithmetic, with \
         NaN and boundary parity in [the native \
         gauntlet](../../../test/native-gauntlet/g35-stdlib-ss22.jqd). The obsolete hyphenated \
         public names are removed without aliases, while the five historical marker IDs and \
         semantic hashes remain stable; the [identity map](../../../test/test_prelude.ml) and \
         [hash-reference CLI/native test](../../../test/cli/ss22.t) prove old references still \
         load, typecheck, interpret, and native-compile.";
        "none";
      ];
      [
        "D40";
        "shipped";
        "[declaration tests](../../../test/test_surface_decls.ml) pin lowering order. [CLI \
         evidence](../../../test/cli/surface.t) executes multiple bare expressions interleaved \
         with declarations in document order and pins stdout `40\\n41\\n42\\n` with exit 0.";
        "none";
      ];
      [
        "D41";
        "shipped";
        "[declaration tests](../../../test/test_surface_decls.ml), [printing \
         tests](../../../test/test_surface_print.ml), and [trivia \
         tests](../../../test/test_surface_trivia.ml) pin per-operation `once`/`multi`, uniform \
         effect-level shorthand, canonical emission, recovery, and formatter idempotence.";
        "none";
      ];
      [
        "D42";
        "shipped";
        "[declaration diagnostics](../../../test/test_surface_decls.ml) reject omission, \
         duplication, conflicts, and partially annotated mixed effects with E1236; the \
         [operation-mode twin](../../../corpus/valid/operation-modes.jac) pins resolved \
         `.jac`/`.jqd` hash parity while bootstrap absence remains legacy `Multi`.";
        "none";
      ];
    ]
    [ "shipped"; "partial"; "adjusted" ];
  (match section "## Evidence Inventories" decision with
  | None -> add "missing evidence inventory section"
  | Some body ->
      let rows = table_rows body in
      let check_inventory name actual members_required =
        match List.filter (function id :: _ -> String.equal id name | [] -> false) rows with
        | [ [ _; count; members ] ] ->
            (match int_of_string_opt count with
            | Some claimed when claimed = List.length actual -> ()
            | _ ->
                add
                  (Printf.sprintf "%s count does not match source inventory (claimed %s, actual %d)"
                     name count (List.length actual)));
            if members_required then
              let claimed = code_tokens members |> List.sort String.compare in
              if claimed <> actual then
                add
                  (Printf.sprintf
                     "%s exact inventory does not match source inventory\nclaimed: %s\nactual: %s"
                     name (String.concat ", " claimed) (String.concat ", " actual))
        | _ -> add (name ^ " inventory must have exactly one three-column row")
      in
      (* Successor evidence is checked against the live executable and repository inventories. *)
      check_inventory "tests" (List.init (Lazy.force compiled_test_count) string_of_int) false;
      check_inventory "doctests" (doctest_names ()) true;
      check_inventory "twins" (twin_names ()) true;
      check_inventory "demos" (demo_names ()) true);
  let evidence_sections =
    List.filter_map
      (fun heading -> section heading decision)
      [ "## Law Status"; "## Decision Conformance" ]
  in
  evidence_sections |> String.concat "\n" |> markdown_links
  |> List.iter (fun target ->
      if
        not
          (link_resolves ~decision_path:"docs/release/surface-syntax/DECISION.md" ~followups target)
      then add ("unresolvable evidence path/link: " ^ target));
  List.iter
    (fun target -> require (contains target decision) ("missing required follow-up link " ^ target))
    [
      "FOLLOWUPS.md#d36-generated-constructor-accessors";
      "FOLLOWUPS.md#tier-f-linearity-modes";
      "FOLLOWUPS.md#tier-f-resource-scoped-rows";
    ];
  let acceptance_contract heading expected =
    match section heading followups with
    | None -> add ("missing follow-up section " ^ heading)
    | Some body ->
        require (contains "**Acceptance contract:**" body) (heading ^ " lacks acceptance contract");
        let rows =
          table_rows body |> List.filter (function "contract" :: _ -> false | _ -> true)
        in
        let actual =
          List.filter_map
            (function
              | [ key; value ] -> Some (key, value)
              | row ->
                  add
                    (Printf.sprintf "%s has malformed acceptance row: %s" heading
                       (String.concat " | " row));
                  None)
            rows
        in
        List.iter
          (fun (key, value) ->
            match List.filter (fun (actual_key, _) -> String.equal key actual_key) actual with
            | [] -> add (Printf.sprintf "%s contract `%s` is missing" heading key)
            | [ (_, actual_value) ] when String.equal value actual_value -> ()
            | [ (_, actual_value) ] ->
                add
                  (Printf.sprintf "%s contract `%s` must be `%s`, not `%s`" heading key value
                     actual_value)
            | _ -> add (Printf.sprintf "%s contract `%s` is duplicated" heading key))
          expected;
        List.iter
          (fun (key, _) ->
            if not (List.mem_assoc key expected) then
              add (Printf.sprintf "%s has unexpected contract `%s`" heading key))
          actual
  in
  acceptance_contract "## D36 Generated Constructor Accessors"
    [
      ("generation", "lowering emits one ordinary pure `DefTerm` accessor per eligible label");
      ("name", "each accessor is named `<type-kebab>.<label>`");
      ("provenance", "each accessor is marked `surface-generated`");
      ("execution", "`pair.left(Pair(1, 2))` prints exactly `1` and exits 0 instead of E0301/exit 1");
      ( "display",
        "the printer emits the owning labeled type exactly once and suppresses generated accessor \
         bodies" );
      ( "validation",
        "reject a label missing from any constructor, duplicated within a constructor, \
         inconsistent in type across constructors, or colliding with an explicit term" );
      ("diagnostics", "each validation failure has a dedicated diagnostic code and exact span tests");
      ("preservation", "bootstrap identity, full tests, doctests, twins, and demos remain green");
      ("excluded", "labeled patterns remain outside this acceptance gate");
    ];
  acceptance_contract "## D38 Variadic Text Join"
    [
      ("export", "the prelude exports `text.join`");
      ("arity", "`text.join` accepts zero or more `Text` arguments");
      ( "semantics",
        "arguments are concatenated in call order and the zero-argument result is empty text" );
      ("type", "`text.join : (Text...) ->{} Text`");
      ( "compatibility",
        "deprecated migration-only `text.join-list : (List Text, Text) ->{} Text` retains old \
         marker `text.join` and hash \
         `b39cc4607d94b6fc777f781207fff5d9bf9dff9d96ff11361a69d4032a0a4bfd`" );
      ( "identity",
        "variadic `text.join` is a distinct object with marker `text.join-variadic-v1` and hash \
         `c6b3e1429d584f14e81f4b1dd46b314ae038170bafc8ac0abdfb0162ed54141d`" );
      ( "evidence",
        "focused prelude tests, callable `.jac` examples, and executable documentation pin zero, \
         one, and multiple arguments" );
      ( "native",
        "interpreter/native parity is pinned through 8 arguments; 9 succeeds in the interpreter \
         and is E1101 in native v1" );
      ( "implementation",
        "no host-only bypass; focused identity, checker, interpreter, native, ASAN, tier, and \
         boundary tests are required before the full gate" );
    ];
  acceptance_contract "## D39 Comparison Naming"
    [
      ( "predicates",
        "applicable numeric dictionaries export exactly `gt?`, `gte?`, `lt?`, and `lte?`" );
      ( "semantics",
        "the four predicates return `Bool` for strict greater-than, greater-or-equal, strict \
         less-than, and less-or-equal respectively" );
      ( "real names",
        "migrate `add-real`, `sub-real`, `mul-real`, `div-real`, and `lt-real` to the reviewed \
         `real.*` namespace" );
      ( "identity",
        "only the public name index changes; all five historical semantic hashes and marker IDs \
         remain stable" );
      ( "migration",
        "remove obsolete tracked demo, corpus, fixture, and executable-documentation call sites" );
      ( "evidence",
        "focused prelude and `.jac` CLI tests pin every predicate and migrated real operation" );
      ("gate", "`dune build @all` and full `dune runtest` pass");
    ];
  acceptance_contract "## Tier-F Linearity Modes"
    [
      ( "modes",
        "surface declarations distinguish explicit `once` and `multi` operations, with uniform \
         effect-level shorthand" );
      ( "once semantics",
        "a captured once continuation may be resumed at most once; the interpreter and native \
         runtime reject a second resume with E0906" );
      ( "multi semantics",
        "a multi continuation may be resumed repeatedly and preserves existing deep-handler \
         behavior" );
      ( "compatibility",
        "bootstrap absent mode remains the unique legacy `Multi` encoding; explicit `once` is \
         interface-hashed" );
      ( "surface default",
        "none; omission, duplication, shorthand/per-operation conflict, and partially annotated \
         mixed effects are E1236" );
      ( "evidence",
        "focused parser/printer/recovery tests and a `.jac`/`.jqd` twin pin D41-D42 before release \
         integration" );
    ];
  acceptance_contract "## Tier-F Resource-Scoped Rows"
    [
      ( "display",
        "signatures render resource scope, including the reviewed example `Fs(read: ./config)`" );
      ( "semantics",
        "define whether scopes constrain authority, describe effects, or both; display alone \
         grants no authority" );
      ("checker/runtime", "pin scope validation, containment, and root-grant enforcement");
      ("round trip", "parsing and rendering preserve the resource-scoped row meaning");
      ("migration", "define unscoped-row compatibility and migration rules");
      ( "evidence",
        "pin exact signature display plus adversarial scope-escape and grant tests before any \
         grammar change" );
    ];
  require
    (contains "E0301" followups && contains "pair.left" followups)
    "D36 follow-up lacks direct E0301 non-generation evidence";
  (match section "## Reproduction Context" decision with
  | None -> add "missing reproduction context"
  | Some body ->
      let rows = table_rows body in
      let expected_rows =
        [
          [ "opam exec -- dune build @all"; "exit 0" ];
          [
            "opam exec -- dune runtest --force";
            "exit 0; compiled Alcotest inventory is exactly 554 cases";
          ];
          [ "opam exec -- dune fmt"; "exit 0; no task-file byte changes" ];
          [
            "cd _build/default/test && ./test_jacquard.exe test surface-twins --compact \
             --color=never";
            "exit 0; exactly 5 selected cases pass over 24 twin pairs";
          ];
          [
            "opam exec -- dune runtest test/docs-doctest --force";
            "exit 0; exactly 27 named doctests pass";
          ];
          [
            "JACQUARD_PRELUDE=$PWD/prelude opam exec -- dune exec jac -- run \
             demos/basics/m1-fact.jac";
            "exit 0; stdout is exactly `120`";
          ];
          [ "opam exec -- dune build @doc"; "exit 0" ];
          [ "git -c core.whitespace=trailing-space,space-before-tab diff --check"; "exit 0" ];
          [
            "scripts/release/check-surface-syntax-manifest.sh";
            "exit 0; the immutable manifest matches the exact SS.22 boundary tree";
          ];
        ]
      in
      let normalized_rows =
        List.filter_map
          (function
            | [ command; result ] -> (
                match code_tokens command with
                | [ command ] -> Some [ command; result ]
                | _ ->
                    add ("malformed final-gate command cell: " ^ command);
                    None)
            | row ->
                add ("malformed final-gate row: " ^ String.concat " | " row);
                None)
          rows
      in
      require (normalized_rows = expected_rows)
        "final gate command order or deterministic expected results changed";
      let successor_completed =
        body |> String.split_on_char '\n'
        |> List.find_opt (fun line ->
            String.starts_with ~prefix:"- SS.22 successor verification completed UTC: `" (trim line))
      in
      (match successor_completed with
      | Some line ->
          require
            (Str.string_match
               (Str.regexp
                  "- SS.22 successor verification completed UTC: \
                   `[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z`")
               (trim line) 0)
            "SS.22 successor verification UTC is malformed"
      | None -> add "SS.22 successor verification UTC is missing");
      List.iter
        (fun required ->
          require (contains required body) ("missing successor evidence contract: " ^ required))
        [
          "Task Master files were not changed";
          "does not reopen or strengthen the SS.21 release";
          ".scratch/ss21-final-gate/transcript.log";
          "not required or expected in a clone";
        ]);
  let lower = String.lowercase_ascii decision in
  List.iter
    (fun claim ->
      require (not (contains claim lower)) ("stable-syntax claim is forbidden: " ^ claim))
    [ "`.jac` is stable"; "stable surface syntax"; "surface syntax is stable"; "stable-syntax" ];
  List.iter
    (fun required -> require (contains required decision) ("missing release boundary: " ^ required))
    [
      "Advertise `.jac`";
      "Bootstrap `.jqd` remains permanently supported";
      "EL.4, explicit surface operation modes";
      "SS.0-SS.22 implementation arc is complete";
    ];
  require (contains "release/surface-syntax/DECISION.md" index) "decision is not indexed";
  require (contains "release/surface-syntax/FOLLOWUPS.md" index) "follow-ups are not indexed";
  errors := List.rev_append (manifest_errors ()) !errors;
  List.rev !errors

let release_sources () =
  ( read_source "docs/release/surface-syntax/DECISION.md",
    read_source "docs/release/surface-syntax/FOLLOWUPS.md",
    read_source "docs/README.md" )

let assert_release_valid () =
  let decision, followups, index = release_sources () in
  match validate_release_docs ~decision ~followups ~index @ release_inventory_errors () with
  | [] -> ()
  | errors -> Alcotest.fail (String.concat "\n" errors)

let assert_mutation_fails ~needle ~mutate_decision ~mutate_followups () =
  let decision, followups, index = release_sources () in
  let decision = mutate_decision decision in
  let followups = mutate_followups followups in
  let errors = validate_release_docs ~decision ~followups ~index in
  Alcotest.(check bool)
    ("mutation rejected: " ^ needle) true
    (List.exists (fun error -> contains needle error) errors)

let unchanged text = text

let decision_status_mutations =
  [
    ("D34", "shipped", "partial");
    ("D35", "shipped", "adjusted");
    ("D36", "partial", "shipped");
    ("D37", "shipped", "partial");
    ("D38", "shipped", "adjusted");
    ("D39", "shipped", "adjusted");
    ("D40", "shipped", "adjusted");
    ("D41", "shipped", "adjusted");
    ("D42", "shipped", "adjusted");
  ]

let status_mutation_test (id, expected, replacement) =
  assert_mutation_fails ~needle:(id ^ " status") ~mutate_followups:unchanged
    ~mutate_decision:
      (replace_once
         ~needle:(Printf.sprintf "| %s | %s |" id expected)
         ~replacement:(Printf.sprintf "| %s | %s |" id replacement))

let decision_semantic_mutations =
  [
    ("D34", "shared case projection and escapes", "separate case projection without escapes");
    ("D35", "mandatory blocks for non-atomic bodies", "optional blocks for non-atomic bodies");
    ( "D36",
      "generated accessor definitions and label validation, including duplicate-label rejection, \
       are deliberate follow-ups",
      "generated accessor definitions and label validation are shipped" );
    ( "D37",
      "dotted names as atomic and preserve namespace puns",
      "dotted names as segmented and reject namespace puns" );
    ( "D38",
      "SS.22 ships a new callable variadic `text.join` object",
      "SS.22 omits callable variadic `text.join`" );
    ("D39", "public names are removed without aliases", "public names remain as aliases");
    ("D40", "in document order and pins stdout", "in reverse document order and pins stdout");
    ( "D41",
      "per-operation `once`/`multi`, uniform effect-level shorthand",
      "implicit per-operation modes without shorthand" );
    ( "D42",
      "reject omission, duplication, conflicts, and partially annotated mixed effects",
      "accept omission, duplication, conflicts, and partially annotated mixed effects" );
  ]

let law_semantic_mutations =
  [
    ( "L1",
      "including `jqd` fallbacks; this is not a generated proof over every tree",
      "excluding `jqd` fallbacks; this is a generated proof over every tree" );
    ( "L3",
      "pin identity for the complete inventories below; this is corpus evidence, not a second \
       semantics",
      "permit divergence in the inventories below; this is a second semantics" );
    ( "L5",
      "pin the named provenance and diagnostic matrix",
      "discard provenance and permit arbitrary diagnostics" );
    ( "L6",
      "pin comments, docs, order, ownership, metadata/hash inertia, and idempotence",
      "permit comments, docs, order, ownership, metadata, hashes, and formatting to change" );
    ( "L7",
      "remain at most 100 nonblank lines and retain its reviewed digest",
      "exceed 100 nonblank lines and ignore its reviewed digest" );
  ]

let semantic_mutation_test (id, needle, replacement) =
  assert_mutation_fails ~needle:(id ^ " semantic contract") ~mutate_followups:unchanged
    ~mutate_decision:(replace_once ~needle ~replacement)

let test_wrong_count_fails =
  assert_mutation_fails ~needle:"twins count" ~mutate_followups:unchanged
    ~mutate_decision:(replace_once ~needle:"| twins | 24 |" ~replacement:"| twins | 23 |")

let test_wrong_status_fails =
  assert_mutation_fails ~needle:"disallowed status" ~mutate_followups:unchanged
    ~mutate_decision:(replace_once ~needle:"| L2 | pinned |" ~replacement:"| L2 | complete |")

let test_wrong_path_fails =
  assert_mutation_fails ~needle:"unresolvable evidence path" ~mutate_followups:unchanged
    ~mutate_decision:
      (replace_once ~needle:"../../../test/test_surface_print.ml"
         ~replacement:"../../../test/missing-surface-print.ml")

let test_wrong_inventory_fails =
  assert_mutation_fails ~needle:"demos exact inventory" ~mutate_followups:unchanged
    ~mutate_decision:(replace_once ~needle:", `repair.jac`" ~replacement:"")

let followup_mutation_test ~heading ~field ~needle ~replacement =
  assert_mutation_fails
    ~needle:(heading ^ " contract `" ^ field ^ "`")
    ~mutate_decision:unchanged
    ~mutate_followups:(replace_once ~needle ~replacement)

let followup_mutations =
  [
    ( "D36 inverted generation",
      followup_mutation_test ~heading:"## D36 Generated Constructor Accessors" ~field:"generation"
        ~needle:"lowering emits one ordinary pure `DefTerm` accessor per eligible label"
        ~replacement:"lowering emits no accessor" );
    ( "D36 missing validation",
      followup_mutation_test ~heading:"## D36 Generated Constructor Accessors" ~field:"validation"
        ~needle:
          "reject a label missing from any constructor, duplicated within a constructor, \
           inconsistent in type across constructors, or colliding with an explicit term"
        ~replacement:"reject duplicated labels" );
    ( "D38 wrong name",
      followup_mutation_test ~heading:"## D38 Variadic Text Join" ~field:"export"
        ~needle:"the prelude exports `text.join`" ~replacement:"the prelude exports `text.concat`"
    );
    ( "D38 wrong arity",
      followup_mutation_test ~heading:"## D38 Variadic Text Join" ~field:"arity"
        ~needle:"`text.join` accepts zero or more `Text` arguments"
        ~replacement:"`text.join` accepts exactly two arguments" );
    ( "D39 wrong names",
      followup_mutation_test ~heading:"## D39 Comparison Naming" ~field:"predicates"
        ~needle:"applicable numeric dictionaries export exactly `gt?`, `gte?`, `lt?`, and `lte?`"
        ~replacement:"applicable numeric dictionaries export `gt`, `gte`, `lt`, and `lte`" );
    ( "Tier-F absent mode semantics",
      followup_mutation_test ~heading:"## Tier-F Linearity Modes" ~field:"once semantics"
        ~needle:
          "a captured once continuation may be resumed at most once; the interpreter and native \
           runtime reject a second resume with E0906"
        ~replacement:"once has implementation-defined behavior" );
    ( "Tier-F no resource display",
      followup_mutation_test ~heading:"## Tier-F Resource-Scoped Rows" ~field:"display"
        ~needle:
          "signatures render resource scope, including the reviewed example `Fs(read: ./config)`"
        ~replacement:"signatures show an effect row" );
  ]

let suite =
  [
    Alcotest.test_case "valid corpus printer totality" `Quick test_valid_corpus_printer_totality;
    Alcotest.test_case "one-page grammar snapshot" `Quick test_one_page_grammar_snapshot;
    Alcotest.test_case "surface formatter corpus stability" `Quick
      test_surface_formatter_corpus_stability;
    Alcotest.test_case "constructor standard width boundary" `Quick
      test_constructor_standard_width_boundary;
    Alcotest.test_case "release tables stop before later subheadings" `Quick
      test_table_rows_stop_at_later_subheading;
    Alcotest.test_case "structured release decision" `Quick assert_release_valid;
    Alcotest.test_case "mutation: wrong count" `Quick test_wrong_count_fails;
    Alcotest.test_case "mutation: wrong status" `Quick test_wrong_status_fails;
    Alcotest.test_case "mutation: wrong path" `Quick test_wrong_path_fails;
    Alcotest.test_case "mutation: wrong inventory" `Quick test_wrong_inventory_fails;
  ]
  @ List.map
      (fun ((id, _, _) as mutation) ->
        Alcotest.test_case ("mutation: " ^ id ^ " status") `Quick (status_mutation_test mutation))
      decision_status_mutations
  @ List.map
      (fun ((id, _, _) as mutation) ->
        Alcotest.test_case
          ("mutation: " ^ id ^ " semantics")
          `Quick (semantic_mutation_test mutation))
      (decision_semantic_mutations @ law_semantic_mutations)
  @ List.map
      (fun (name, test) -> Alcotest.test_case ("mutation: " ^ name) `Quick test)
      followup_mutations
