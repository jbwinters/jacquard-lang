open Weft

(* W3.7: 20 golden rendered diagnostics; every checker code appears in at least one. *)

let golden_file = "../corpus/golden/diags.golden"

let test_golden_diagnostics () =
  match Corpus_support.diag_golden_lines ~prelude_dir:"../prelude" with
  | Error ds -> Eval_support.fail_diags "diag battery" ds
  | Ok actual ->
      Alcotest.(check bool) "at least 20 cases" true (List.length Corpus_support.diag_cases >= 20);
      let expected =
        Corpus_support.read_file golden_file
        |> String.split_on_char '\n'
        |> List.filter (fun l -> l <> "")
      in
      let flatten lines =
        (* multi-line renderings (hints) count as part of their case line *)
        lines
      in
      Alcotest.(check (list string))
        "rendered diagnostics match corpus/golden/diags.golden (regenerate with `dune exec \
         test/gen_diag_goldens.exe` and review the wording diff)"
        (flatten expected)
        (flatten (List.concat_map (String.split_on_char '\n') actual))

(* every code the checker can emit appears in the golden battery (the plan's coverage
   check over the code enum) *)
let test_code_coverage () =
  let golden = Corpus_support.read_file golden_file in
  let contains needle =
    let n = String.length needle and m = String.length golden in
    let rec go i = i + n <= m && (String.sub golden i n = needle || go (i + 1)) in
    go 0
  in
  List.iter
    (fun (code, what) ->
      Alcotest.(check bool)
        (Printf.sprintf "%s (%s) appears in the golden battery" code what)
        true
        (contains ("[" ^ code ^ "]")))
    Check.checker_codes

let suite =
  [
    Alcotest.test_case "20 golden diagnostics" `Quick test_golden_diagnostics;
    Alcotest.test_case "checker code coverage" `Quick test_code_coverage;
  ]
