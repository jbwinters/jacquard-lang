open Jacquard

let form = Alcotest.testable Form.pp Form.equal_ignoring_meta

let parse_ok s =
  match Reader.parse_one ~file:"t.jqd" s with
  | Ok f -> f
  | Error ds ->
      Alcotest.failf "expected parse of %S to succeed: %s" s
        (String.concat "; " (List.map Diag.to_string ds))

let parse_err s =
  match Reader.parse_string ~file:"err.jqd" s with
  | Ok _ -> Alcotest.failf "expected parse of %S to fail" s
  | Error [ d ] -> d
  | Error ds -> Alcotest.failf "expected exactly one diagnostic, got %d" (List.length ds)

let check_span what expected f =
  match Form.span f with
  | None -> Alcotest.failf "%s: no span" what
  | Some s -> Alcotest.(check string) what expected (Span.to_string s)

(* --- spans --- *)

let test_spans_flat () =
  let f = parse_ok "(lit 1)" in
  check_span "root" "t.jqd:1:1-8" f;
  match Form.span f with
  | Some s ->
      Alcotest.(check int) "start offset" 0 s.Span.start_pos.Span.offset;
      Alcotest.(check int) "end offset" 7 s.Span.end_pos.Span.offset
  | None -> Alcotest.fail "no span"

let test_spans_nested () =
  let f = parse_ok "(app (var add) (lit 1))" in
  check_span "root" "t.jqd:1:1-24" f;
  match f.Form.args with
  | [ Form.F v; Form.F l ] ->
      check_span "(var add)" "t.jqd:1:6-15" v;
      check_span "(lit 1)" "t.jqd:1:16-23" l
  | _ -> Alcotest.fail "expected two form args"

let test_spans_multiline () =
  let f = parse_ok "(app\n  (var add)\n  (lit 1))" in
  check_span "root" "t.jqd:1:1-3:11" f;
  match f.Form.args with
  | [ Form.F v; Form.F l ] ->
      check_span "(var add)" "t.jqd:2:3-12" v;
      check_span "(lit 1)" "t.jqd:3:3-10" l
  | _ -> Alcotest.fail "expected two form args"

(* --- scalars and atoms --- *)

let test_symbols_bare_and_quoted () =
  Alcotest.check form "bare = quoted" (parse_ok "(var add)") (parse_ok "(var 'add)")

let test_text_escapes () =
  let f = parse_ok {|(lit "a\nb\"c\\d\te\x01")|} in
  match f.Form.args with
  | [ Form.Text s ] -> Alcotest.(check string) "unescaped" "a\nb\"c\\d\te\x01" s
  | _ -> Alcotest.fail "expected one text arg"

let test_numbers () =
  let one_arg s =
    match (parse_ok s).Form.args with [ a ] -> a | _ -> Alcotest.fail "expected one arg"
  in
  (match one_arg "(lit 0)" with Form.Int 0 -> () | _ -> Alcotest.fail "0");
  (match one_arg "(lit -42)" with Form.Int -42 -> () | _ -> Alcotest.fail "-42");
  (match one_arg "(lit +7)" with Form.Int 7 -> () | _ -> Alcotest.fail "+7");
  (match one_arg "(lit 3.14)" with Form.Real r when r = 3.14 -> () | _ -> Alcotest.fail "3.14");
  (match one_arg "(lit 1.)" with Form.Real 1.0 -> () | _ -> Alcotest.fail "1.");
  (match one_arg "(lit 2e3)" with Form.Real 2000.0 -> () | _ -> Alcotest.fail "2e3");
  (match one_arg "(lit -0.5)" with Form.Real -0.5 -> () | _ -> Alcotest.fail "-0.5");
  (match one_arg "(lit +inf.0)" with
  | Form.Real r when r = infinity -> ()
  | _ -> Alcotest.fail "+inf.0");
  (match one_arg "(lit -inf.0)" with
  | Form.Real r when r = neg_infinity -> ()
  | _ -> Alcotest.fail "-inf.0");
  match one_arg "(lit +nan.0)" with
  | Form.Real r when Float.is_nan r -> ()
  | _ -> Alcotest.fail "+nan.0"

let test_hash_literal () =
  let hex = Hash.to_hex (Hash.of_string "x") in
  let f = parse_ok (Printf.sprintf "(ref #%s term)" hex) in
  match f.Form.args with
  | [ Form.Hash h; Form.Sym "term" ] -> Alcotest.(check string) "hash preserved" hex (Hash.to_hex h)
  | _ -> Alcotest.fail "expected hash + sym args"

let test_comments_skipped () =
  let fs =
    match Reader.parse_string ~file:"t.jqd" "; hi\n(lit 1) ; bye\n(lit 2)\n" with
    | Ok fs -> fs
    | Error _ -> Alcotest.fail "comments should be skipped"
  in
  Alcotest.(check int) "two forms" 2 (List.length fs)

(* --- groups --- *)

let test_groups () =
  let f = parse_ok "(lam ((pvar x)) (var x))" in
  (match f.Form.args with
  | [ Form.F { Form.head = "group"; args = [ Form.F { Form.head = "pvar"; _ } ]; _ }; Form.F _ ] ->
      ()
  | _ -> Alcotest.fail "params should read as a group of forms");
  let g = parse_ok "(binding fact () (lit 1))" in
  (match g.Form.args with
  | [ Form.Sym "fact"; Form.F { Form.head = "group"; args = []; _ }; Form.F _ ] -> ()
  | _ -> Alcotest.fail "() should read as an empty group");
  let d = parse_err "(group 42)" in
  Alcotest.(check string) "scalar group element rejected" "E0110" (Diag.code_or_uncoded d)

let test_parse_one_arity () =
  (match Reader.parse_one ~file:"t.jqd" "" with
  | Error [ d ] -> Alcotest.(check string) "empty input" "E0106" (Diag.code_or_uncoded d)
  | _ -> Alcotest.fail "empty input should fail");
  match Reader.parse_one ~file:"t.jqd" "(lit 1) (lit 2)" with
  | Error [ d ] -> Alcotest.(check string) "two forms" "E0114" (Diag.code_or_uncoded d)
  | _ -> Alcotest.fail "two forms should fail parse_one"

(* --- golden parse errors (the structured wording is the contract; renderer order is pinned by
   Test_diag and the CLI transcript suite) --- *)

let golden_errors =
  [
    ( "unclosed",
      "(lit 1\n",
      "E0106",
      "The source ended before the form was complete.",
      "unclosed form: expected `)`",
      "Complete the open form and its closing parenthesis." );
    ( "bad token",
      "(lit @)\n",
      "E0101",
      "The source contains an unexpected character.",
      "unexpected character '@'",
      "Remove the character or replace it with valid bootstrap syntax." );
    ( "unterminated text",
      "(lit \"abc\n",
      "E0102",
      "A text literal is not closed.",
      "unterminated text literal",
      "Close the text literal with a double quote before the end of the line or file." );
    ( "bad hash",
      "(ref #deadbeef term)\n",
      "E0104",
      "A hash literal is malformed.",
      "invalid hash literal #deadbeef",
      "Write the hash as 64 lowercase hexadecimal characters." );
    ( "stray rparen",
      ")\n",
      "E0108",
      "The source contains an unmatched closing parenthesis.",
      "unexpected `)` at top level",
      "Remove the unmatched parenthesis or add its missing opening form." );
    ( "bad head",
      "(42 x)\n",
      "E0107",
      "A bootstrap form has an invalid head.",
      "expected a form head symbol, found '4'",
      "Use a lowercase kernel-form head." );
    ( "big int",
      "(lit 123456789012345678901234567890)\n",
      "E0109",
      "An integer is outside Jacquard's supported range.",
      "integer literal 123456789012345678901234567890 does not fit in a native int",
      "Choose a value representable as a Jacquard 63-bit native integer (decision D2)." );
    ( "bad escape",
      "(lit \"a\\qb\")\n",
      "E0103",
      "A text literal contains an invalid escape.",
      "invalid escape sequence \\q",
      "Use one of these escapes: \\\\ \\\" \\n \\t \\r \\xHH." );
    ( "bad number",
      "(lit 1.2.3)\n",
      "E0105",
      "A numeric literal is malformed.",
      "malformed number \"1.2.3\"",
      "Rewrite the value as one valid integer or real literal." );
    ( "bad quoted symbol",
      "(var 'Foo)\n",
      "E0111",
      "A quoted symbol is malformed.",
      "invalid quoted symbol 'Foo",
      "Rewrite the quoted symbol using the documented symbol grammar." );
    ( "bad bare symbol",
      "(var a@b)\n",
      "E0112",
      "A bare symbol is malformed.",
      "invalid symbol \"a@b\"",
      "Rewrite the name using the documented bare-symbol grammar." );
    ( "top-level scalar",
      "42\n",
      "E0113",
      "A bootstrap file has a non-form top-level value.",
      "expected a form at top level, found \"42\"",
      "Wrap the top-level value in a kernel form." );
  ]

let test_golden_errors () =
  List.iter
    (fun (name, src, code, summary, cause, next_step) ->
      let diagnostic = parse_err src in
      Alcotest.(check string) (name ^ " code") code (Diag.code_or_uncoded diagnostic);
      Alcotest.(check string) (name ^ " summary") summary (Diag.summary diagnostic);
      Alcotest.(check string) (name ^ " cause") cause (Diag.cause diagnostic);
      Alcotest.(check string) (name ^ " next step") next_step (Diag.next_step diagnostic))
    golden_errors

let suite =
  [
    Alcotest.test_case "flat spans" `Quick test_spans_flat;
    Alcotest.test_case "nested spans" `Quick test_spans_nested;
    Alcotest.test_case "multiline spans" `Quick test_spans_multiline;
    Alcotest.test_case "bare and quoted symbols" `Quick test_symbols_bare_and_quoted;
    Alcotest.test_case "text escapes" `Quick test_text_escapes;
    Alcotest.test_case "numbers" `Quick test_numbers;
    Alcotest.test_case "hash literal" `Quick test_hash_literal;
    Alcotest.test_case "comments skipped" `Quick test_comments_skipped;
    Alcotest.test_case "argument groups" `Quick test_groups;
    Alcotest.test_case "parse_one arity" `Quick test_parse_one_arity;
    Alcotest.test_case "golden parse errors" `Quick test_golden_errors;
  ]
