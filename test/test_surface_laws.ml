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

let suite =
  [
    Alcotest.test_case "valid corpus printer totality" `Quick test_valid_corpus_printer_totality;
    Alcotest.test_case "one-page grammar snapshot" `Quick test_one_page_grammar_snapshot;
    Alcotest.test_case "surface formatter corpus stability" `Quick
      test_surface_formatter_corpus_stability;
    Alcotest.test_case "constructor standard width boundary" `Quick
      test_constructor_standard_width_boundary;
  ]
