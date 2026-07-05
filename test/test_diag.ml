open Jacquard

let span =
  Span.make ~file:"demo.wft"
    ~start_pos:{ Span.line = 4; col = 1; offset = 30 }
    ~end_pos:{ Span.line = 4; col = 9; offset = 38 }

let test_error_fields () =
  let d = Diag.error ~span ~hint:"try this" ~code:"E0001" "something broke" in
  Alcotest.(check string) "code" "E0001" d.Diag.code;
  Alcotest.(check string) "message" "something broke" d.Diag.message;
  Alcotest.(check bool) "severity" true (d.Diag.severity = Diag.Error);
  Alcotest.(check (option string)) "hint" (Some "try this") d.Diag.hint

let test_rendering () =
  let d = Diag.error ~span ~hint:"grant it" ~code:"E0002" "unhandled effect" in
  Alcotest.(check string)
    "rendered" "demo.wft:4:1-9: error[E0002]: unhandled effect\n  hint: grant it" (Diag.to_string d)

let test_span_multiline () =
  let s =
    Span.make ~file:"a.wft"
      ~start_pos:{ Span.line = 1; col = 2; offset = 1 }
      ~end_pos:{ Span.line = 3; col = 4; offset = 20 }
  in
  Alcotest.(check string) "multiline span" "a.wft:1:2-3:4" (Span.to_string s)

let suite =
  [
    Alcotest.test_case "error fields" `Quick test_error_fields;
    Alcotest.test_case "rendering" `Quick test_rendering;
    Alcotest.test_case "multiline span" `Quick test_span_multiline;
  ]
