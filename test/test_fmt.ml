open Jacquard

(* W5.1: trivia-preserving formatter — roundtrip with identical trivia, idempotency, and
   comment survival. *)

let valid_dir = "../corpus/valid"

let parse_ok ~what src =
  match Reader.parse_string ~file:what src with
  | Ok fs -> fs
  | Error ds -> Eval_support.fail_diags (what ^ " parse") ds

(* A nested fingerprint of every node's trivia, for exact preservation checks. *)
let rec trivia_fp (f : Form.t) : string =
  let get k =
    match Meta.find k f.Form.meta with
    | Some (Meta.List l) ->
        String.concat "|" (List.filter_map (function Meta.Text c -> Some c | _ -> None) l)
    | Some (Meta.Text c) -> c
    | _ -> ""
  in
  Printf.sprintf "[%s;%s;%s;%s](%s)" (get Meta.key_trivia) (get Meta.key_trivia_inner)
    (get Meta.key_trivia_trailing) (get Meta.key_trivia_eof)
    (String.concat "," (List.map (function Form.F g -> trivia_fp g | _ -> ".") f.Form.args))

let test_roundtrip_preserves_trivia () =
  List.iter
    (fun file ->
      let src = Corpus_support.read_file (Filename.concat valid_dir file) in
      let forms = parse_ok ~what:file src in
      let formatted = Printer.format_all forms in
      let forms' = parse_ok ~what:(file ^ " reformatted") formatted in
      List.iter2
        (fun a b ->
          if not (Form.equal_ignoring_meta a b) then
            Alcotest.failf "%s: formatting changed structure" file;
          Alcotest.(check string)
            (Printf.sprintf "%s: trivia identical" file)
            (trivia_fp a) (trivia_fp b))
        forms forms')
    (Corpus_support.jqd_files valid_dir)

let test_idempotent () =
  List.iter
    (fun file ->
      let src = Corpus_support.read_file (Filename.concat valid_dir file) in
      let once = Printer.format_all (parse_ok ~what:file src) in
      let twice = Printer.format_all (parse_ok ~what:file once) in
      Alcotest.(check string) (file ^ ": formatting is idempotent") once twice)
    (Corpus_support.jqd_files valid_dir)

let test_comments_survive_golden () =
  let src =
    "; leading file comment\n\
     ; second line\n\
     (defterm ((binding one () ; inline note\n\
     (lit 1))))\n\
     (app (var one)) ; trailing note\n\
     (tuple ; after head\n\
     (lit 1)\n\
     ; between args\n\
     (lit 2))\n"
  in
  let formatted = Printer.format_all (parse_ok ~what:"golden" src) in
  let expected =
    String.concat "\n"
      [
        "; leading file comment";
        "; second line";
        "(defterm";
        "  (";
        "    (binding";
        "      one";
        "      () ; inline note";
        "      (lit 1))))";
        "";
        "(app";
        "  (var one)) ; trailing note";
        "";
        "(tuple";
        "  ; after head";
        "  (lit 1)";
        "  ; between args";
        "  (lit 2))";
        "";
      ]
  in
  Alcotest.(check string) "formatted output" expected formatted

let test_eof_comments_survive () =
  let src = "(lit 1)\n; the last word\n; really\n" in
  let formatted = Printer.format_all (parse_ok ~what:"eof" src) in
  Alcotest.(check string) "eof comments kept" "(lit 1)\n; the last word\n; really\n" formatted;
  Alcotest.(check string)
    "idempotent" formatted
    (Printer.format_all (parse_ok ~what:"eof2" formatted))

let suite =
  [
    Alcotest.test_case "roundtrip preserves trivia" `Quick test_roundtrip_preserves_trivia;
    Alcotest.test_case "eof comments survive" `Quick test_eof_comments_survive;
    Alcotest.test_case "idempotent" `Quick test_idempotent;
    Alcotest.test_case "comments survive (golden)" `Quick test_comments_survive_golden;
  ]
