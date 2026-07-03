(** The conformance corpus runner (plan W1.7): the spec's teeth.

    Every file in [corpus/valid] must pass the whole pipeline (parse, validate, resolve against the
    stub prelude names, hash) and land exactly on the golden hashes. Every file in [corpus/invalid]
    must fail at the stage its [.expect] sidecar names, with the expected diagnostic code. *)

open Weft

let valid_dir = "../corpus/valid"
let invalid_dir = "../corpus/invalid"
let golden_file = "../corpus/golden/hashes.golden"

let test_valid_corpus () =
  let files = Corpus_support.wft_files valid_dir in
  Alcotest.(check bool) "corpus has >= 10 valid files" true (List.length files >= 10);
  let expected =
    Corpus_support.read_file golden_file
    |> String.split_on_char '\n'
    |> List.filter (fun l -> l <> "")
  in
  let actual = Corpus_support.corpus_golden_lines ~valid_dir in
  Alcotest.(check (list string))
    "every valid file passes the pipeline and matches golden hashes (regenerate with `dune exec \
     test/gen_goldens.exe` and review the diff)"
    expected actual

let test_invalid_corpus () =
  let files = Corpus_support.wft_files invalid_dir in
  Alcotest.(check bool) "corpus has >= 5 invalid files" true (List.length files >= 5);
  List.iter
    (fun file ->
      let path = Filename.concat invalid_dir file in
      let expect_path = Filename.remove_extension path ^ ".expect" in
      if not (Sys.file_exists expect_path) then Alcotest.failf "%s has no .expect sidecar" file;
      match Corpus_support.parse_expect (Corpus_support.read_file expect_path) with
      | None -> Alcotest.failf "%s: malformed .expect sidecar" file
      | Some (expected_stage, expected_code) -> (
          match Corpus_support.staged_pipeline ~file (Corpus_support.read_file path) with
          | Ok _ ->
              Alcotest.failf "%s: expected failure at %s, but the pipeline passed" file
                (Corpus_support.stage_name expected_stage)
          | Error (stage, diags) ->
              Alcotest.(check string)
                (Printf.sprintf "%s fails at the right stage" file)
                (Corpus_support.stage_name expected_stage)
                (Corpus_support.stage_name stage);
              Alcotest.(check bool)
                (Printf.sprintf "%s reports %s (got: %s)" file expected_code
                   (String.concat ", " (List.map (fun d -> d.Diag.code) diags)))
                true
                (List.exists (fun d -> d.Diag.code = expected_code) diags)))
    files

(* Sanity for the runner itself: a case that fails at the wrong stage or with the wrong code
   must be caught (this is what "a deliberately broken case fails CI" relies on). *)
let test_runner_catches_breakage () =
  (* wrong stage: this source fails at parse, not resolve *)
  (match Corpus_support.staged_pipeline ~file:"broken" "(lit 1" with
  | Error (Corpus_support.Parse, _) -> ()
  | _ -> Alcotest.fail "expected a parse-stage failure");
  (* wrong code: E0106, not E0999 *)
  match Corpus_support.staged_pipeline ~file:"broken" "(lit 1" with
  | Error (_, [ d ]) -> Alcotest.(check bool) "code differs" false (d.Diag.code = "E0999")
  | _ -> Alcotest.fail "expected one diagnostic"

let suite =
  [
    Alcotest.test_case "valid corpus passes and matches goldens" `Quick test_valid_corpus;
    Alcotest.test_case "invalid corpus fails at named stage with named code" `Quick
      test_invalid_corpus;
    Alcotest.test_case "runner catches breakage" `Quick test_runner_catches_breakage;
  ]
