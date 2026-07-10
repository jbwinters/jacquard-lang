open Jacquard

let lex source =
  match Surface_lex.lex ~file:"tokens.jac" source with
  | Ok tokens -> tokens
  | Error ds -> Eval_support.fail_diags "surface lex" ds

let without_eof tokens =
  List.filter (fun token -> token.Surface_lex.token <> Surface_lex.Eof) tokens

let token_names source =
  lex source |> without_eof
  |> List.map (fun token -> Surface_lex.show_token token.Surface_lex.token)

let shown source = lex source |> without_eof |> List.map Surface_lex.show
let recover_lex source = Surface_lex.lex_recover ~file:"tokens.jac" source

let recovered_token_names source =
  (recover_lex source).Surface_lex.tokens |> without_eof
  |> List.map (fun token -> Surface_lex.show_token token.Surface_lex.token)

let test_identifier_golden () =
  Alcotest.(check (list string))
    "names and byte spans"
    [
      "tokens.jac:1:1-5 ident(code)";
      "tokens.jac:1:6-18 ident(code.un-form)";
      "tokens.jac:1:19-25 ident(empty?)";
      "tokens.jac:1:26-31 ident(head!)";
      "tokens.jac:1:32-37 ident(Fleet)";
      "tokens.jac:1:38-45 ident(MkFleet)";
      "tokens.jac:1:46-47 ident(_)";
    ]
    (shown "code code.un-form empty? head! Fleet MkFleet _")

let test_keywords_and_escapes () =
  let escaped =
    [
      "`term:match`";
      "`op:match`";
      "`type:match`";
      "`con:match`";
      "`effect:match`";
      "`tvar:match`";
      "`rvar:match`";
    ]
  in
  let source = String.concat " " (Surface_lex.keywords @ [ "returning" ] @ escaped) in
  let expected =
    List.map (fun keyword -> "keyword(" ^ keyword ^ ")") Surface_lex.keywords
    @ [ "ident(returning)" ]
    @ List.map
        (fun spelling ->
          let body = String.sub spelling 1 (String.length spelling - 2) in
          "escaped(" ^ body ^ ")")
        escaped
  in
  Alcotest.(check (list string)) "reserved words are not identifiers" expected (token_names source)

let test_punctuation_and_newlines () =
  Alcotest.(check (list string))
    "punctuation"
    [ "("; ")"; "{"; "}"; "["; "]"; ","; ":"; "="; "->"; "|"; "|>"; "."; ";"; "newline" ]
    (token_names "(){}[],:=->||>.;\n");
  let zeros = String.make 64 '0' in
  Alcotest.(check (list string))
    "arrow maximal munch after atoms"
    [
      "|";
      "ident(x)";
      "->";
      "ident(x)";
      "|";
      "int(-3)";
      "->";
      "ident(x)";
      "|";
      "hash(" ^ zeros ^ ":con)";
      "->";
      "ident(x)";
    ]
    (token_names (Printf.sprintf "|x->x|-3->x|#%s:con->x" zeros))

let test_literals () =
  Alcotest.(check (list string))
    "numbers and strings"
    [
      "int(-3)";
      "real(-2.5)";
      "real(1000.0)";
      "real(+inf.0)";
      "real(+nan.0)";
      "text(\"a\\nb\\\"c\\\\d\\t\\x01\")";
    ]
    (token_names {|-3 -2.5 1e3 +inf.0 -nan.0 "a\nb\"c\\d\t\x01"|});
  Alcotest.(check (list string))
    "UTF-8 columns count bytes"
    [ "tokens.jac:1:1-5 text(\"\xC3\xA9\")" ]
    (shown "\"\xC3\xA9\"")

let test_comments () =
  Alcotest.(check (list string))
    "comments leave newline tokens"
    [ "comment( note)"; "newline"; "doc-comment( docs)"; "newline"; "ident(x)" ]
    (token_names "-- note\n--| docs\nx");
  Alcotest.(check (list string))
    "comment and negative-number adjacency"
    [ "comment(c)"; "newline"; "int(-3)"; "->"; "ident(x)" ]
    (token_names "--c\n-3->x")

let test_hash_and_group_references () =
  let zeros = String.make 64 '0' in
  Alcotest.(check (list string))
    "printer fallbacks"
    [
      "hash(" ^ zeros ^ ":term)";
      "hash(" ^ zeros ^ ":op)";
      "hash(" ^ zeros ^ ":type)";
      "hash(" ^ zeros ^ ":con)";
      "hash(" ^ zeros ^ ":effect)";
      "group-ref(12)";
    ]
    (token_names
       (Printf.sprintf "#%s:term #%s:op #%s:type #%s:con #%s:effect #group[12]" zeros zeros zeros
          zeros zeros));
  Alcotest.(check (list string))
    "hash stops before list delimiter"
    [ "["; "hash(" ^ zeros ^ ":term)"; "]" ]
    (token_names (Printf.sprintf "[#%s:term]" zeros))

let test_namespace_pun_is_lexical () =
  Alcotest.(check (list string))
    "local code binder does not split dotted path"
    [ "keyword(fn)"; "("; "ident(code)"; ")"; "->"; "ident(code.un-form)"; "("; "ident(code)"; ")" ]
    (token_names "fn (code) -> code.un-form(code)");
  Alcotest.(check (list string))
    "same token without local binder"
    [ "ident(code.un-form)"; "("; "ident(value)"; ")" ]
    (token_names "code.un-form(value)")

let test_underscore_is_context_free () =
  Alcotest.(check (list string))
    "wildcard and resume binder share the identifier token"
    [ "ident(_)"; "keyword(resume)"; "ident(_)" ]
    (token_names "_ resume _")

let test_offsets_and_eof () =
  let tokens = lex "x\n  code" in
  match tokens with
  | [ first; newline; second; eof ] ->
      let check_span label token start_offset end_offset start_line start_col end_line end_col =
        let span = token.Surface_lex.span in
        Alcotest.(check int) (label ^ " start offset") start_offset span.Span.start_pos.offset;
        Alcotest.(check int) (label ^ " end offset") end_offset span.end_pos.offset;
        Alcotest.(check int) (label ^ " start line") start_line span.start_pos.line;
        Alcotest.(check int) (label ^ " start col") start_col span.start_pos.col;
        Alcotest.(check int) (label ^ " end line") end_line span.end_pos.line;
        Alcotest.(check int) (label ^ " end col") end_col span.end_pos.col
      in
      check_span "first" first 0 1 1 1 1 2;
      check_span "newline" newline 1 2 1 2 2 1;
      check_span "second" second 4 8 2 3 2 7;
      check_span "eof" eof 8 8 2 7 2 7
  | _ -> Alcotest.fail "offset fixture token shape"

let test_strict_group_indices () =
  List.iter
    (fun source ->
      match Surface_lex.lex ~file:"group.jac" source with
      | Error [ { Diag.code = "E1217"; _ } ] -> ()
      | _ -> Alcotest.failf "%s: non-decimal group index was accepted" source)
    [ "#group[+12]"; "#group[0x10]"; "#group[1_2]"; "#group[]"; "#group[12" ]

let test_malformed_tokens () =
  let cases =
    [
      ("@", "E1210", "bad.jac:1:1-2");
      ("foo--bar", "E1211", "bad.jac:1:1-9");
      ("Foo.Bar", "E1211", "bad.jac:1:1-8");
      ("foo.", "E1211", "bad.jac:1:1-5");
      ("1..2", "E1212", "bad.jac:1:1-5");
      ("-x", "E1212", "bad.jac:1:1-3");
      ("\"unterminated", "E1213", "bad.jac:1:1-14");
      ("\"\\q\"", "E1214", "bad.jac:1:2-3");
      ("\"\\x0\"", "E1214", "bad.jac:1:2-4");
      ("`wat:name`", "E1215", "bad.jac:1:1-11");
      ("#abc:term", "E1216", "bad.jac:1:1-10");
      ("#group[x]", "E1217", "bad.jac:1:1-10");
      ("+3", "E1212", "bad.jac:1:1-3");
      ("123456789012345678901234567890", "E1212", "bad.jac:1:1-31");
      ("ok\n  @", "E1210", "bad.jac:2:3-4");
    ]
  in
  List.iter
    (fun (source, code, expected_span) ->
      match Surface_lex.lex ~file:"bad.jac" source with
      | Error [ diagnostic ] -> (
          Alcotest.(check string) (source ^ " code") code diagnostic.Diag.code;
          match diagnostic.span with
          | Some span ->
              Alcotest.(check string) (source ^ " span") expected_span (Span.to_string span)
          | None -> Alcotest.failf "%s: missing diagnostic span" source)
      | Error diagnostics ->
          Alcotest.failf "%s: expected one diagnostic, got %d" source (List.length diagnostics)
      | Ok _ -> Alcotest.failf "%s: malformed token was accepted" source)
    cases

let test_invalid_raw_utf8 () =
  let source = String.init 3 (function 0 | 2 -> '"' | _ -> Char.chr 0xff) in
  match Surface_lex.lex ~file:"utf8.jac" source with
  | Error [ { Diag.code = "E1218"; span = Some span; _ } ] ->
      Alcotest.(check string) "invalid byte span" "utf8.jac:1:2-3" (Span.to_string span)
  | _ -> Alcotest.fail "invalid raw UTF-8 byte was accepted"

let test_recovering_lexer_preserves_surrounding_tokens () =
  let source = "before\n@\n}\nafter\n" in
  let recovered = recover_lex source in
  Alcotest.(check (list string))
    "tokens around lexical damage"
    [
      "ident(before)";
      "newline";
      "invalid(E1210)";
      "newline";
      "}";
      "newline";
      "ident(after)";
      "newline";
    ]
    (recovered_token_names source);
  Alcotest.(check (list string))
    "recovery diagnostics"
    [ "tokens.jac:2:1-2: error[E1210]: unexpected surface character `@`" ]
    (List.map Diag.to_string recovered.diagnostics);
  match Surface_lex.lex ~file:"tokens.jac" source with
  | Error [ { Diag.code = "E1210"; span = Some span; _ } ] ->
      Alcotest.(check string) "strict span unchanged" "tokens.jac:2:1-2" (Span.to_string span)
  | _ -> Alcotest.fail "strict lexer no longer stops at its first lexical error"

let test_recovering_lexer_resynchronizes_strings () =
  let truncated = recover_lex "before\n\"truncated\nafter\n" in
  Alcotest.(check (list string))
    "truncated string tokens"
    [ "ident(before)"; "newline"; "invalid(E1213)"; "newline"; "ident(after)"; "newline" ]
    (truncated.tokens |> without_eof
    |> List.map (fun token -> Surface_lex.show_token token.Surface_lex.token));
  Alcotest.(check (list string))
    "bounded truncated string diagnostic"
    [ "tokens.jac:2:1-11: error[E1213]: unterminated string literal" ]
    (List.map Diag.to_string truncated.diagnostics);
  let malformed = recover_lex "before\n\"bad\\q\"\nafter\n" in
  Alcotest.(check (list string))
    "malformed escape tokens"
    [ "ident(before)"; "newline"; "invalid(E1214)"; "newline"; "ident(after)"; "newline" ]
    (malformed.tokens |> without_eof
    |> List.map (fun token -> Surface_lex.show_token token.Surface_lex.token));
  Alcotest.(check (list string))
    "malformed escape diagnostic"
    [ "tokens.jac:2:5-6: error[E1214]: invalid string escape `\\q`" ]
    (List.map Diag.to_string malformed.diagnostics);
  let multiline = recover_lex "before\n\"line one\nbad\\q\"\nafter\n" in
  Alcotest.(check (list string))
    "multiline malformed string does not rewind before damage"
    [ "ident(before)"; "newline"; "invalid(E1214)"; "newline"; "ident(after)"; "newline" ]
    (multiline.tokens |> without_eof
    |> List.map (fun token -> Surface_lex.show_token token.Surface_lex.token));
  Alcotest.(check (list string))
    "multiline malformed escape diagnostic"
    [ "tokens.jac:3:4-5: error[E1214]: invalid string escape `\\q`" ]
    (List.map Diag.to_string multiline.diagnostics);
  let escaped_newline = recover_lex "\"bad\\\nafter\n" in
  Alcotest.(check (list string))
    "invalid escaped newline remains a synchronization token"
    [ "invalid(E1214)"; "newline"; "ident(after)"; "newline" ]
    (escaped_newline.tokens |> without_eof
    |> List.map (fun token -> Surface_lex.show_token token.Surface_lex.token));
  Alcotest.(check (list string))
    "escaped newline diagnostic"
    [ "tokens.jac:1:5-6: error[E1214]: invalid string escape `\\\n`" ]
    (List.map Diag.to_string escaped_newline.diagnostics)

let test_raw_bootstrap_candidates () =
  Alcotest.(check (list string))
    "raw candidates are lexical and grammar-neutral"
    [
      "keyword(jqd)";
      "raw-candidate";
      "newline";
      "keyword(quote)";
      "{";
      "newline";
      "comment( leading quote trivia)";
      "newline";
      "keyword(jqd)";
      "raw-candidate";
      "newline";
      "}";
      "newline";
      "ident(f)";
      "(";
      "keyword(jqd)";
      "raw-candidate";
      ")";
    ]
    (token_names
       "jqd { (lit 1) }\nquote {\n-- leading quote trivia\njqd   { (lit 2) }\n}\nf(jqd { (lit 3) })");
  let balanced = recover_lex "jqd { (mystery \"}\" ; } in a comment\n (nested (lit 1))) }" in
  Alcotest.(check (list string))
    "strings, comments, and parentheses do not close the candidate"
    [ "keyword(jqd)"; "raw-candidate" ]
    (balanced.tokens |> without_eof
    |> List.map (fun token -> Surface_lex.show_token token.Surface_lex.token));
  Alcotest.(check int) "balanced candidate has no diagnostics" 0 (List.length balanced.diagnostics);
  let malformed = recover_lex "f(jqd { (lit @) (lit 2) })\nafter = 7\n" in
  Alcotest.(check int)
    "bootstrap bytes are inert in the lexer" 0
    (List.length malformed.diagnostics);
  Alcotest.(check (list string))
    "illegal call position still captures one opaque candidate"
    [
      "ident(f)";
      "(";
      "keyword(jqd)";
      "raw-candidate";
      ")";
      "newline";
      "ident(after)";
      "=";
      "int(7)";
      "newline";
    ]
    (malformed.tokens |> without_eof
    |> List.map (fun token -> Surface_lex.show_token token.Surface_lex.token));
  let unclosed = recover_lex "jqd { (lit 1)" in
  Alcotest.(check (list string))
    "unclosed candidate reaches EOF without a lexer diagnostic"
    [ "keyword(jqd)"; "raw-candidate(unclosed)" ]
    (unclosed.tokens |> without_eof
    |> List.map (fun token -> Surface_lex.show_token token.Surface_lex.token));
  Alcotest.(check int) "unclosed candidate is lexically inert" 0 (List.length unclosed.diagnostics);
  let fallback = recover_lex "jqd { (lit 1 }\nafter = 7\n" in
  (match fallback.tokens with
  | _jqd :: { Surface_lex.token = RawCandidate candidate; span } :: _ ->
      Alcotest.(check string) "fallback candidate source" " (lit 1 " candidate.source;
      Alcotest.(check string)
        "fallback candidate content span" "tokens.jac:1:6-14"
        (Span.to_string candidate.content_span);
      Alcotest.(check string)
        "fallback candidate token span" "tokens.jac:1:5-15" (Span.to_string span);
      Alcotest.(check bool) "fallback candidate is closed" true candidate.closed
  | _ -> Alcotest.fail "fallback candidate was not emitted");
  Alcotest.(check (list string))
    "fallback rewinds subsequent surface source"
    [ "keyword(jqd)"; "raw-candidate"; "newline"; "ident(after)"; "="; "int(7)"; "newline" ]
    (fallback.tokens |> without_eof
    |> List.map (fun token -> Surface_lex.show_token token.Surface_lex.token));
  let precedence = recover_lex {|jqd { (mystery (lit "}") }; jqd { (lit 8) }; after = 7|} in
  (match precedence.tokens with
  | _jqd :: { Surface_lex.token = RawCandidate candidate; span } :: _ ->
      Alcotest.(check string)
        "balanced string does not mask structural fallback" {| (mystery (lit "}") |}
        candidate.source;
      Alcotest.(check string)
        "precedence candidate content span" "tokens.jac:1:6-26"
        (Span.to_string candidate.content_span);
      Alcotest.(check string)
        "precedence candidate token span" "tokens.jac:1:5-27" (Span.to_string span);
      Alcotest.(check bool) "precedence candidate is closed" true candidate.closed
  | _ -> Alcotest.fail "precedence candidate was not emitted");
  Alcotest.(check (list string))
    "structural fallback restores the later raw top and definition"
    [
      "keyword(jqd)";
      "raw-candidate";
      ";";
      "keyword(jqd)";
      "raw-candidate";
      ";";
      "ident(after)";
      "=";
      "int(7)";
    ]
    (precedence.tokens |> without_eof
    |> List.map (fun token -> Surface_lex.show_token token.Surface_lex.token));
  let structural_over_string = recover_lex {|jqd { (mystery } (lit "unterminated }|} in
  match structural_over_string.tokens with
  | _jqd :: { Surface_lex.token = RawCandidate candidate; span } :: _ ->
      Alcotest.(check string)
        "structural fallback outranks an open-string fallback" " (mystery " candidate.source;
      Alcotest.(check string)
        "structural precedence content span" "tokens.jac:1:6-16"
        (Span.to_string candidate.content_span);
      Alcotest.(check string)
        "structural precedence token span" "tokens.jac:1:5-17" (Span.to_string span);
      Alcotest.(check bool) "structural precedence candidate is closed" true candidate.closed
  | _ -> Alcotest.fail "structural precedence candidate was not emitted"

let test_forall_dot_boundary () =
  Alcotest.(check (list string))
    "quantifier dot is not part of a dotted name"
    [ "keyword(forall)"; "ident(a)"; "|"; "ident(e)"; "."; "ident(T)" ]
    (token_names "forall a | e. T")

let suite =
  [
    Alcotest.test_case "identifier golden" `Quick test_identifier_golden;
    Alcotest.test_case "keywords and escapes" `Quick test_keywords_and_escapes;
    Alcotest.test_case "punctuation and newlines" `Quick test_punctuation_and_newlines;
    Alcotest.test_case "literals" `Quick test_literals;
    Alcotest.test_case "comments" `Quick test_comments;
    Alcotest.test_case "hash and group refs" `Quick test_hash_and_group_references;
    Alcotest.test_case "namespace pun" `Quick test_namespace_pun_is_lexical;
    Alcotest.test_case "underscore roles" `Quick test_underscore_is_context_free;
    Alcotest.test_case "offsets and eof" `Quick test_offsets_and_eof;
    Alcotest.test_case "strict group indices" `Quick test_strict_group_indices;
    Alcotest.test_case "malformed token diagnostics" `Quick test_malformed_tokens;
    Alcotest.test_case "invalid raw UTF-8" `Quick test_invalid_raw_utf8;
    Alcotest.test_case "recover surrounding tokens" `Quick
      test_recovering_lexer_preserves_surrounding_tokens;
    Alcotest.test_case "recover malformed strings" `Quick
      test_recovering_lexer_resynchronizes_strings;
    Alcotest.test_case "raw bootstrap candidates" `Quick test_raw_bootstrap_candidates;
    Alcotest.test_case "forall dot boundary" `Quick test_forall_dot_boundary;
  ]
