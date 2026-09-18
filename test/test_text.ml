open Jacquard

(* SL.5: text builtins — codepoint semantics (D9), reader-grammar conversions. *)

let store, ctx = Eval_support.make_prelude_ctx ()

let eval_ok src =
  match Eval_support.eval_with ctx store src with
  | Ok v -> v
  | Error e -> Alcotest.failf "eval failed on %s: %s" src (Runtime_err.to_string e)

let show src = Value.show (eval_ok src)
let quote s = "\"" ^ Printer.escape_text s ^ "\""
let lit s = Printf.sprintf "(lit %s)" (quote s)

(* the D9 honesty test, pinned so nobody "fixes" it casually: the thumbs-up with a skin
   tone is TWO codepoints (base + modifier), and length counts codepoints *)
let test_emoji_length () =
  Alcotest.(check string)
    "👍🏽 is two codepoints" "2"
    (show (Printf.sprintf "(app (var text.length) %s)" (lit "\u{1F44D}\u{1F3FD}")))

let test_length () =
  List.iter
    (fun (s, n) ->
      Alcotest.(check string)
        (s ^ " length") (string_of_int n)
        (show (Printf.sprintf "(app (var text.length) %s)" (lit s))))
    [ ("", 0); ("abc", 3); ("héllo", 5); ("日本語", 3); ("a\u{0301}", 2) (* combining accent *) ]

let test_slice () =
  List.iter
    (fun (s, a, b, want) ->
      Alcotest.(check string)
        (Printf.sprintf "slice %s %d %d" s a b)
        (Value.show (Value.VText want))
        (show (Printf.sprintf "(app (var text.slice) %s (lit %d) (lit %d))" (lit s) a b)))
    [
      ("héllo", 1, 3, "él");
      ("héllo", 0, 5, "héllo");
      ("héllo", 3, 1, "");
      ("héllo", -2, 99, "héllo") (* clamped *);
      ("日本語", 1, 2, "本");
      ("", 0, 1, "");
    ]

let test_split_join_units () =
  Alcotest.(check string)
    "split keeps empties" "cons(\"a\", cons(\"b\", cons(\"\", cons(\"c\", nil))))"
    (show (Printf.sprintf "(app (var text.split) %s %s)" (lit "a,b,,c") (lit ",")));
  Alcotest.(check string)
    "split empty text" "cons(\"\", nil)"
    (show (Printf.sprintf "(app (var text.split) %s %s)" (lit "") (lit ",")));
  (* empty separator: singleton codepoints, consistent with the absence of Char *)
  Alcotest.(check string)
    "split on empty separator" "cons(\"h\", cons(\"é\", cons(\"l\", nil)))"
    (show (Printf.sprintf "(app (var text.split) %s %s)" (lit "hél") (lit "")));
  Alcotest.(check string)
    "variadic join"
    (Value.show (Value.VText "a-b-c"))
    (show
       (Printf.sprintf "(app (var text.join) %s %s %s %s %s)" (lit "a") (lit "-") (lit "b")
          (lit "-") (lit "c")))

let test_trim_contains_empty () =
  Alcotest.(check string)
    "trim" (Value.show (Value.VText "x y"))
    (show (Printf.sprintf "(app (var text.trim) %s)" (lit " \t x y \n ")));
  Alcotest.(check string)
    "trim all-space" "\"\""
    (show (Printf.sprintf "(app (var text.trim) %s)" (lit "   ")));
  Alcotest.(check string)
    "contains? yes" "true"
    (show (Printf.sprintf "(app (var text.contains?) %s %s)" (lit "héllo") (lit "éll")));
  Alcotest.(check string)
    "contains? no" "false"
    (show (Printf.sprintf "(app (var text.contains?) %s %s)" (lit "héllo") (lit "z")));
  Alcotest.(check string)
    "contains? empty needle" "true"
    (show (Printf.sprintf "(app (var text.contains?) %s %s)" (lit "abc") (lit "")));
  Alcotest.(check string)
    "empty? yes" "true"
    (show (Printf.sprintf "(app (var text.empty?) %s)" (lit "")));
  Alcotest.(check string)
    "empty? no" "false"
    (show (Printf.sprintf "(app (var text.empty?) %s)" (lit " ")))

let test_conversions () =
  Alcotest.(check string) "from-int" "\"-42\"" (show "(app (var text.from-int) (lit -42))");
  Alcotest.(check string)
    "to-int" "some(42)"
    (show (Printf.sprintf "(app (var text.to-int) %s)" (lit "42")));
  (* exactly the reader's grammar: real spellings, garbage, and overflow are rejected *)
  List.iter
    (fun s ->
      Alcotest.(check string)
        ("to-int rejects " ^ s) "none"
        (show (Printf.sprintf "(app (var text.to-int) %s)" (lit s))))
    [ "4.5"; "abc"; ""; "1e3"; "123456789012345678901234567890"; "1x"; "+" ];
  Alcotest.(check string)
    "to-real real spelling" "some(2.5)"
    (show (Printf.sprintf "(app (var text.to-real) %s)" (lit "2.5")));
  Alcotest.(check string)
    "to-real int spelling" "some(3.0)"
    (show (Printf.sprintf "(app (var text.to-real) %s)" (lit "3")));
  Alcotest.(check string)
    "to-real +inf.0" "some(+inf.0)"
    (show (Printf.sprintf "(app (var text.to-real) %s)" (lit "+inf.0")));
  Alcotest.(check string)
    "to-real rejects" "none"
    (show (Printf.sprintf "(app (var text.to-real) %s)" (lit "1.2.3")))

(* APP.6: fixed-decimal presentation is separate from the round-trip spelling *)
let test_fixed () =
  List.iter
    (fun (r, precision, want) ->
      Alcotest.(check string)
        (Printf.sprintf "fixed %s %d" r precision)
        (Value.show (Value.VText want))
        (show (Printf.sprintf "(app (var text.from-real-fixed) (lit %s) (lit %d))" r precision)))
    [
      ("3.14159265358979", 3, "3.142");
      ("2.5", 0, "2") (* ties to even on the exact binary value *);
      ("3.5", 0, "4");
      ("2.675", 2, "2.67") (* the double is just below the tie *);
      ("0.125", 2, "0.12");
      ("-0.0004", 3, "0.000") (* a zero result drops its sign *);
      ("-0.0", 1, "0.0");
      ("-1.5", 0, "-2");
      ("1e21", 2, "1000000000000000000000.00");
      ("51.855", 3, "51.855");
      ("+inf.0", 4, "+inf.0");
      ("-inf.0", 4, "-inf.0");
      ("+nan.0", 4, "+nan.0");
      ("0.1", 20, "0.10000000000000000555");
    ];
  Alcotest.(check string)
    "from-real is untouched" "\"0.1\""
    (show "(app (var text.from-real) (lit 0.1))");
  List.iter
    (fun precision ->
      match
        Eval_support.eval_with ctx store
          (Printf.sprintf "(app (var text.from-real-fixed) (lit 1.5) (lit %d))" precision)
      with
      | Error (Runtime_err.Arithmetic message) ->
          Alcotest.(check bool)
            "precision message" true
            (String.length message > 0
            && String.starts_with
                 ~prefix:"text.from-real-fixed expects a precision between 0 and 20" message)
      | Error other -> Alcotest.failf "unexpected error %s" (Runtime_err.to_string other)
      | Ok v -> Alcotest.failf "precision %d accepted: %s" precision (Value.show v))
    [ -1; 21 ]

let test_real_from_int () =
  List.iter
    (fun (i, want) ->
      Alcotest.(check string)
        ("real.from-int " ^ i) want
        (show (Printf.sprintf "(app (var real.from-int) (lit %s))" i)))
    [
      ("0", "0.0");
      ("-7", "-7.0");
      ("9007199254740993", "9007199254740992.0") (* inexact: nearest even *);
      ("4611686018427387903", "4.611686018427388e+18");
    ]

(* APP.6: ASCII/codepoint classification of singleton texts; no Char type *)
let test_character_classes () =
  List.iter
    (fun (c, digit, letter, space, value, code) ->
      let call name = show (Printf.sprintf "(app (var %s) %s)" name (lit c)) in
      Alcotest.(check string) (c ^ " digit?") digit (call "text.ascii-digit?");
      Alcotest.(check string) (c ^ " letter?") letter (call "text.ascii-letter?");
      Alcotest.(check string) (c ^ " space?") space (call "text.ascii-space?");
      Alcotest.(check string) (c ^ " digit-value") value (call "text.ascii-digit-value");
      Alcotest.(check string) (c ^ " codepoint") code (call "text.codepoint"))
    [
      ("7", "true", "false", "false", "some(7)", "some(55)");
      ("a", "false", "true", "false", "none", "some(97)");
      ("Z", "false", "true", "false", "none", "some(90)");
      (" ", "false", "false", "true", "none", "some(32)");
      ("\t", "false", "false", "true", "none", "some(9)");
      ("", "false", "false", "false", "none", "none");
      ("77", "false", "false", "false", "none", "none");
      ("\u{00e9}", "false", "false", "false", "none", "some(233)");
      ("\u{0663}", "false", "false", "false", "none", "some(1635)")
      (* Arabic-Indic three is not an ASCII digit *);
      ("\u{65e5}", "false", "false", "false", "none", "some(26085)");
      ("\u{1F600}", "false", "false", "false", "none", "some(128512)");
      ("\x7f", "false", "false", "false", "none", "some(127)");
      ("\xff", "false", "false", "false", "none", "none") (* a malformed byte is not a scalar *);
      ("\xed\xa0\x80", "false", "false", "false", "none", "none")
      (* an encoded surrogate is not a scalar *);
    ]

let prop_int_roundtrip =
  QCheck.Test.make ~count:200 ~name:"to-int (from-int n) = some n" QCheck.int (fun n ->
      show (Printf.sprintf "(app (var text.to-int) (app (var text.from-int) (lit %d)))" n)
      = Printf.sprintf "some(%d)" n)

(* bit-exact: from-real uses Printer.real_repr, to-real the reader's classifier *)
let prop_real_roundtrip =
  QCheck.Test.make ~count:200 ~name:"to-real (from-real r) is bit-exact" QCheck.float (fun r ->
      (* real_repr canonicalizes every NaN to +nan.0, so payload bits are out of scope *)
      QCheck.assume (not (Float.is_nan r));
      match
        eval_ok
          (Printf.sprintf "(app (var text.to-real) (app (var text.from-real) (lit %s)))"
             (Printer.real_repr r))
      with
      | Value.VCon { name = "some"; args = [ Value.VReal r' ]; _ } ->
          Int64.equal (Int64.bits_of_float r) (Int64.bits_of_float r')
      | v -> Alcotest.failf "expected some(real), got %s" (Value.show v))

(* join (split s sep) sep = s for any nonempty separator *)
let prop_split_join_inverse =
  let ident =
    QCheck.Gen.(string_size ~gen:(oneof_list [ 'a'; 'b'; ','; '-'; 'x' ]) (int_bound 12))
  in
  QCheck.Test.make ~count:200 ~name:"join after split is identity (nonempty sep)"
    (QCheck.make
       QCheck.Gen.(pair ident (oneof_list [ ","; "-"; "ab" ]))
       ~print:(fun (s, sep) -> s ^ " / " ^ sep))
    (fun (s, sep) ->
      match eval_ok (Printf.sprintf "(app (var text.split) %s %s)" (lit s) (lit sep)) with
      | split ->
          let rec texts = function
            | Value.VCon { name = "nil"; args = []; _ } -> []
            | Value.VCon { name = "cons"; args = [ Value.VText text; rest ]; _ } ->
                text :: texts rest
            | value -> Alcotest.failf "text.split returned %s" (Value.show value)
          in
          let pieces = texts split in
          let source =
            Printf.sprintf "(app (var text.join-list) %s %s)"
              (let rec list = function
                 | [] -> "(var nil)"
                 | text :: rest -> Printf.sprintf "(app (var cons) %s %s)" (lit text) (list rest)
               in
               list pieces)
              (lit sep)
          in
          show source = Value.show (Value.VText s))

(* show instances render the same spellings as Value.show, pinned so they cannot drift *)
let test_show_instances_match_value_show () =
  List.iter
    (fun n ->
      Alcotest.(check string)
        (Printf.sprintf "int.show %d" n)
        (Value.show (Value.VText (Value.show (Value.VInt n))))
        (show (Printf.sprintf "(app (app (var show.fn) (var int.show)) (lit %d))" n)))
    [ 0; 42; -17; max_int ];
  Alcotest.(check string)
    "bool.show true" "\"true\""
    (show "(app (app (var show.fn) (var bool.show)) (var true))");
  Alcotest.(check string)
    "bool.show false" "\"false\""
    (show "(app (app (var show.fn) (var bool.show)) (var false))");
  Alcotest.(check string)
    "show.for-list" "\"[1, 2, 3]\""
    (show
       "(app (app (var show.fn) (app (var show.for-list) (var int.show))) (app (var cons) (lit 1) \
        (app (var cons) (lit 2) (app (var cons) (lit 3) (var nil)))))")

let test_text_dictionaries () =
  Alcotest.(check string)
    "text.ord bytewise" "less"
    (show (Printf.sprintf "(app (app (var ord.fn) (var text.ord)) %s %s)" (lit "abc") (lit "abd")));
  Alcotest.(check string)
    "text.eq" "true"
    (show
       (Printf.sprintf "(app (app (var eq.fn) (var text.eq)) %s %s)" (lit "héllo") (lit "héllo")));
  Alcotest.(check string)
    "text.eq? true" "true"
    (show (Printf.sprintf "(app (var text.eq?) %s %s)" (lit "héllo") (lit "héllo")));
  Alcotest.(check string)
    "text.eq? false" "false"
    (show (Printf.sprintf "(app (var text.eq?) %s %s)" (lit "héllo") (lit "hello")));
  (* sort a list of texts through the captive dictionary machinery *)
  Alcotest.(check string)
    "sort by text.ord" "cons(\"a\", cons(\"b\", cons(\"c\", nil)))"
    (show
       (Printf.sprintf
          "(app (var list.sort) (app (var cons) %s (app (var cons) %s (app (var cons) %s (var \
           nil)))) (var text.ord))"
          (lit "c") (lit "a") (lit "b")))

(* malformed UTF-8: each bad byte is one codepoint (replacement-style), including
   overlongs, surrogates, and beyond-U+10FFFF (the Unicode well-formedness table) *)
let test_malformed_utf8 () =
  let len_of bytes =
    match
      Eval_support.eval_with ctx store
        (Printf.sprintf "(app (var text.length) (lit \"%s\"))" (Printer.escape_text bytes))
    with
    | Ok (Value.VInt n) -> n
    | Ok v -> Alcotest.failf "not an int: %s" (Value.show v)
    | Error e -> Alcotest.failf "eval failed: %s" (Runtime_err.to_string e)
  in
  List.iter
    (fun (what, bytes, want) -> Alcotest.(check int) what want (len_of bytes))
    [
      ("lone lead byte", "\xC3", 1);
      ("overlong 2-byte C0", "\xC0\x80", 2);
      ("overlong 3-byte E0 80 80", "\xE0\x80\x80", 3);
      ("surrogate ED A0 80", "\xED\xA0\x80", 3);
      ("beyond U+10FFFF F4 90 80 80", "\xF4\x90\x80\x80", 4);
      ("valid E0 A0 80", "\xE0\xA0\x80", 1);
      ("valid ED 9F BF", "\xED\x9F\xBF", 1);
      ("valid F4 8F BF BF", "\xF4\x8F\xBF\xBF", 1);
      ("valid F0 90 80 80", "\xF0\x90\x80\x80", 1);
    ]

let suite =
  [
    Alcotest.test_case "emoji length is 2 (D9)" `Quick test_emoji_length;
    Alcotest.test_case "length" `Quick test_length;
    Alcotest.test_case "slice" `Quick test_slice;
    Alcotest.test_case "split and join" `Quick test_split_join_units;
    Alcotest.test_case "trim, contains?, empty?" `Quick test_trim_contains_empty;
    Alcotest.test_case "conversions follow the reader grammar" `Quick test_conversions;
    Alcotest.test_case "fixed-decimal presentation" `Quick test_fixed;
    Alcotest.test_case "real.from-int" `Quick test_real_from_int;
    Alcotest.test_case "ASCII and codepoint classes" `Quick test_character_classes;
    QCheck_alcotest.to_alcotest prop_int_roundtrip;
    QCheck_alcotest.to_alcotest prop_real_roundtrip;
    QCheck_alcotest.to_alcotest prop_split_join_inverse;
    Alcotest.test_case "show instances match Value.show" `Quick test_show_instances_match_value_show;
    Alcotest.test_case "text dictionaries" `Quick test_text_dictionaries;
    Alcotest.test_case "malformed utf-8 counts per byte" `Quick test_malformed_utf8;
  ]
