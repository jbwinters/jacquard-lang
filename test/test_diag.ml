open Jacquard

let span =
  Span.make ~file:"demo.jqd"
    ~start_pos:{ Span.line = 4; col = 1; offset = 30 }
    ~end_pos:{ Span.line = 4; col = 9; offset = 38 }

let test_error_fields () =
  let d =
    Diag.error ~span ~domain:Runtime ~code:"E0001" ~summary:"Runtime operation failed"
      ~cause:"Something broke while evaluating the operation."
      ~next_step:"Correct the operation input and run it again." ~contrast:None ()
  in
  Alcotest.(check string) "code" "E0001" (Diag.code_or_uncoded d);
  Alcotest.(check string) "summary" "Runtime operation failed" (Diag.summary d);
  Alcotest.(check string) "cause" "Something broke while evaluating the operation." (Diag.cause d);
  Alcotest.(check bool) "severity" true (Diag.severity d = Diag.Error);
  Alcotest.(check string)
    "next step" "Correct the operation input and run it again." (Diag.next_step d);
  Alcotest.(check bool) "no contrast" true (Option.is_none (Diag.contrastive_hint d))

let test_rendering () =
  let contrast =
    Diag.contrast ~mistaken:"Declaring Console grants it"
      ~intended:"The root must grant or handle Console"
  in
  let d =
    Diag.error ~span ~domain:Runtime ~code:"E0002" ~summary:"Console effect is unhandled"
      ~cause:"The program requires Console, but the root did not grant it."
      ~next_step:"Run with --allow console or handle Console in the program."
      ~contrast:(Some contrast) ()
  in
  Alcotest.(check string)
    "rendered"
    "demo.jqd:4:1-9: error[E0002]: Console effect is unhandled\n\
    \  Cause: The program requires Console, but the root did not grant it.\n\
    \  Next step: Run with --allow console or handle Console in the program.\n\
    \  Contrast: mistaken: Declaring Console grants it; intended: The root must grant or handle \
     Console"
    (Diag.to_string d)

let test_json_v1 () =
  let d =
    Diag.warning ~domain:Surface ~code:"W1203" ~summary:"Match scrutinee is difficult to review"
      ~cause:"The scrutinee spans seven lines." ~next_step:"Bind it with `let` first."
      ~contrast:None ()
  in
  let open Yojson.Safe.Util in
  let json = Diag.to_yojson d in
  Alcotest.(check string) "schema" "jacquard-diagnostic-v1" (json |> member "schema" |> to_string);
  Alcotest.(check string) "domain" "surface" (json |> member "domain" |> to_string);
  Alcotest.(check string) "code" "W1203" (json |> member "code" |> to_string);
  Alcotest.(check string) "severity" "warning" (json |> member "severity" |> to_string);
  Alcotest.(check string)
    "next step" "Bind it with `let` first."
    (json |> member "next_step" |> to_string);
  Alcotest.(check bool) "span is null" true (json |> member "span" = `Null);
  Alcotest.(check bool) "contrast omitted" true (json |> member "contrast" = `Null);
  let invalid = "bad\xffbytes" in
  let invalid_span =
    Span.make ~file:("source-" ^ invalid)
      ~start_pos:{ Span.line = 1; col = 1; offset = 0 }
      ~end_pos:{ Span.line = 1; col = 2; offset = 1 }
  in
  let invalid_contrast = Diag.contrast ~mistaken:invalid ~intended:("use-" ^ invalid) in
  let invalid_diagnostic =
    Diag.error ~span:invalid_span ~domain:Surface ~code:"E1210" ~summary:("summary-" ^ invalid)
      ~cause:("cause-" ^ invalid) ~next_step:("step-" ^ invalid) ~contrast:(Some invalid_contrast)
      ()
  in
  let replacement = "bad\xef\xbf\xbdbytes" in
  let repaired = Diag.to_json_string invalid_diagnostic |> Yojson.Safe.from_string in
  Alcotest.(check string)
    "invalid UTF-8 cause repaired" ("cause-" ^ replacement)
    (repaired |> member "cause" |> to_string);
  Alcotest.(check string)
    "invalid UTF-8 path repaired" ("source-" ^ replacement)
    (repaired |> member "span" |> member "file" |> to_string);
  Alcotest.(check string)
    "invalid UTF-8 contrast repaired" replacement
    (repaired |> member "contrast" |> member "mistaken" |> to_string);
  let repaired_cause bytes =
    Diag.error ~domain:Surface ~code:"E1210" ~summary:"Invalid input" ~cause:bytes
      ~next_step:"Replace the invalid input." ~contrast:None ()
    |> Diag.to_json_string |> Yojson.Safe.from_string |> member "cause" |> to_string
  in
  let replacement = "\xef\xbf\xbd" in
  Alcotest.(check string)
    "valid UTF-8 preserved" "\xc2\xa2\xe2\x82\xac\xf0\x9f\x91\x8d"
    (repaired_cause "\xc2\xa2\xe2\x82\xac\xf0\x9f\x91\x8d");
  List.iter
    (fun (label, malformed, replacement_count) ->
      Alcotest.(check string)
        label
        (String.concat "" (List.init replacement_count (Fun.const replacement)))
        (repaired_cause malformed))
    [
      ("truncated UTF-8 repaired", "\xc3", 1);
      ("overlong UTF-8 repaired per byte", "\xc0\x80", 2);
      ("surrogate UTF-8 repaired per byte", "\xed\xa0\x80", 3);
      ("out-of-range UTF-8 repaired per byte", "\xf4\x90\x80\x80", 4);
    ]

let test_contract_rejects_empty_step () =
  match
    Diag.error ~domain:Checker ~code:"E0801" ~summary:"Types do not agree"
      ~cause:"Expected int, found text." ~next_step:"" ~contrast:None ()
  with
  | exception Diag.Bug_invalid_diagnostic _ -> ()
  | _ -> Alcotest.fail "empty primary next step was accepted"

let expect_invalid label build =
  match build () with
  | exception Diag.Bug_invalid_diagnostic _ -> ()
  | _ -> Alcotest.fail (label ^ " was accepted")

let test_contract_rejects_invalid_identity_and_span () =
  expect_invalid "code-less checker diagnostic" (fun () ->
      Diag.error ~domain:Checker ~summary:"Types do not agree" ~cause:"Expected int, found text."
        ~next_step:"Correct the value type." ~contrast:None ());
  expect_invalid "code-less runtime warning" (fun () ->
      Diag.warning ~domain:Runtime ~summary:"Runtime warning" ~cause:"A warning occurred."
        ~next_step:"Correct the runtime input." ~contrast:None ());
  expect_invalid "code-less runtime info" (fun () ->
      Diag.info ~domain:Runtime ~summary:"Runtime information" ~cause:"Information is available."
        ~next_step:"Review the runtime information." ~contrast:None ());
  expect_invalid "error carrying a warning code" (fun () ->
      Diag.error ~domain:Checker ~code:"W0801" ~summary:"Types do not agree"
        ~cause:"Expected int, found text." ~next_step:"Correct the value type." ~contrast:None ());
  let invalid_span =
    Span.make ~file:"bad.jac"
      ~start_pos:{ Span.line = 0; col = 1; offset = 0 }
      ~end_pos:{ Span.line = 1; col = 1; offset = 0 }
  in
  expect_invalid "zero-based diagnostic line" (fun () ->
      Diag.error ~span:invalid_span ~domain:Checker ~code:"E0801" ~summary:"Types do not agree"
        ~cause:"Expected int, found text." ~next_step:"Correct the value type." ~contrast:None ());
  let reversed_line_span =
    Span.make ~file:"bad.jac"
      ~start_pos:{ Span.line = 5; col = 1; offset = 10 }
      ~end_pos:{ Span.line = 4; col = 9; offset = 20 }
  in
  expect_invalid "decreasing diagnostic span line" (fun () ->
      Diag.error ~span:reversed_line_span ~domain:Checker ~code:"E0801"
        ~summary:"Types do not agree" ~cause:"Expected int, found text."
        ~next_step:"Correct the value type." ~contrast:None ());
  let reversed_column_span =
    Span.make ~file:"bad.jac"
      ~start_pos:{ Span.line = 5; col = 9; offset = 10 }
      ~end_pos:{ Span.line = 5; col = 4; offset = 20 }
  in
  expect_invalid "decreasing diagnostic span column" (fun () ->
      Diag.error ~span:reversed_column_span ~domain:Checker ~code:"E0801"
        ~summary:"Types do not agree" ~cause:"Expected int, found text."
        ~next_step:"Correct the value type." ~contrast:None ())

let test_cause_projection_excludes_child_actions () =
  let contrast = Diag.contrast ~mistaken:"a term reference" ~intended:"a type reference" in
  let child =
    Diag.error ~domain:Resolution ~code:"E0302" ~summary:"Reference has the wrong kind"
      ~cause:"`add` is a term, but this position needs a type."
      ~next_step:"Reference a type declaration instead." ~contrast:(Some contrast) ()
  in
  Alcotest.(check string)
    "cause projection"
    "E0302: Reference has the wrong kind (`add` is a term, but this position needs a type.)"
    (Diag.to_cause_string child);
  Alcotest.(check bool)
    "child next step excluded" false
    (String.contains (Diag.to_cause_string child) '\n');
  let inference =
    Diag.error ~domain:Inference ~code:"E0901" ~summary:"The posterior is empty."
      ~cause:"Every execution branch has zero weight."
      ~next_step:"Change the model so one branch has nonzero weight." ~contrast:None ()
  in
  let projected = Runtime_err.to_diag (Runtime_err.Diagnostic inference) in
  Alcotest.(check string) "embedded runtime code" "E0901" (Diag.code_or_uncoded projected);
  Alcotest.(check bool) "embedded runtime domain" true (Diag.domain projected = Diag.Inference);
  Alcotest.(check string)
    "compact runtime cause"
    "E0901: The posterior is empty. (Every execution branch has zero weight.)"
    (Runtime_err.to_string (Runtime_err.Diagnostic inference))

let test_span_multiline () =
  let s =
    Span.make ~file:"a.jqd"
      ~start_pos:{ Span.line = 1; col = 2; offset = 1 }
      ~end_pos:{ Span.line = 3; col = 4; offset = 20 }
  in
  Alcotest.(check string) "multiline span" "a.jqd:1:2-3:4" (Span.to_string s)

let suite =
  [
    Alcotest.test_case "error fields" `Quick test_error_fields;
    Alcotest.test_case "rendering" `Quick test_rendering;
    Alcotest.test_case "json v1" `Quick test_json_v1;
    Alcotest.test_case "empty step rejected" `Quick test_contract_rejects_empty_step;
    Alcotest.test_case "invalid identity and span rejected" `Quick
      test_contract_rejects_invalid_identity_and_span;
    Alcotest.test_case "cause projection excludes child actions" `Quick
      test_cause_projection_excludes_child_actions;
    Alcotest.test_case "multiline span" `Quick test_span_multiline;
  ]
