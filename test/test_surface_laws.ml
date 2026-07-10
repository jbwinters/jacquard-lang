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
    "47fff3e3ced0fced860d6669b46e99954e2ecb729fa69b988283aa9a8f2263d6"
    (Hash.to_hex (Hash.of_string grammar))

let suite =
  [
    Alcotest.test_case "valid corpus printer totality" `Quick test_valid_corpus_printer_totality;
    Alcotest.test_case "one-page grammar snapshot" `Quick test_one_page_grammar_snapshot;
  ]
