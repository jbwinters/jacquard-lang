open Jacquard

let form = Alcotest.testable Form.pp Form.equal_ignoring_meta

let parse_ok ~what s =
  match Reader.parse_string ~file:"t.jqd" s with
  | Ok fs -> fs
  | Error ds ->
      Alcotest.failf "%s: parse failed: %s" what (String.concat "; " (List.map Diag.to_string ds))

let test_canonical_layout () =
  let f = List.hd (parse_ok ~what:"app" "(app (var add) (lit 1) (lit 2))") in
  Alcotest.(check string)
    "form args each on own line" "(app\n  (var add)\n  (lit 1)\n  (lit 2))" (Printer.print f);
  let l = List.hd (parse_ok ~what:"lit" "(lit 1)") in
  Alcotest.(check string) "scalar-only form inline" "(lit 1)" (Printer.print l);
  let g = List.hd (parse_ok ~what:"lam" "(lam ((pvar x)) (var x))") in
  Alcotest.(check string)
    "groups print as bare parens" "(lam\n  ((pvar x))\n  (var x))" (Printer.print g)

let test_real_reprs () =
  let cases = [ 0.1; 1.0; -0.5; 1e300; 3.14; 1.0 /. 3.0; -0.0; 2e-8 ] in
  List.iter
    (fun r ->
      let s = Printer.real_repr r in
      Alcotest.(check bool)
        (Printf.sprintf "%s reparses identically" s)
        true
        (Int64.equal (Int64.bits_of_float (float_of_string s)) (Int64.bits_of_float r)))
    cases;
  Alcotest.(check string) "nan" "+nan.0" (Printer.real_repr nan);
  Alcotest.(check string) "inf" "+inf.0" (Printer.real_repr infinity);
  Alcotest.(check string) "-inf" "-inf.0" (Printer.real_repr neg_infinity)

let roundtrip ~what (f : Form.t) =
  let printed = Printer.print f in
  match Reader.parse_one ~file:"rt.jqd" printed with
  | Error ds ->
      Alcotest.failf "%s: printed form does not reparse:\n%s\n%s" what printed
        (String.concat "; " (List.map Diag.to_string ds))
  | Ok f' ->
      Alcotest.check form (what ^ ": reparse equal ignoring meta") f f';
      Alcotest.(check string) (what ^ ": printing is idempotent") printed (Printer.print f')

(* --- roundtrip over every valid corpus file --- *)

let corpus_dir = "../corpus/valid"

let test_roundtrip_corpus () =
  let files =
    Sys.readdir corpus_dir |> Array.to_list
    |> List.filter (fun f -> Filename.check_suffix f ".jqd")
    |> List.sort String.compare
  in
  Alcotest.(check bool) "corpus has >= 10 valid files" true (List.length files >= 10);
  List.iter
    (fun file ->
      let path = Filename.concat corpus_dir file in
      let ic = open_in_bin path in
      let src = really_input_string ic (in_channel_length ic) in
      close_in ic;
      let forms = parse_ok ~what:file src in
      List.iter (roundtrip ~what:file) forms)
    files

(* --- roundtrip over random printable forms --- *)

let gen_printable_form : Form.t QCheck.Gen.t =
  let open QCheck.Gen in
  (* includes the SL.1 library grammar: dotted segments and trailing ?/! marks *)
  let ident =
    oneof_list [ "x"; "y"; "add"; "safe-div"; "m2"; "n"; "list.map"; "empty?"; "head!"; "a.b-c.d?" ]
  in
  let head = oneof_list [ "app"; "lam"; "lit"; "var"; "tuple"; "match"; "clause" ] in
  let real = oneof [ float; oneof_list [ nan; infinity; neg_infinity; 0.1; -0.0; 1e300 ] ] in
  sized
  @@ fix (fun self n ->
      let scalar =
        oneof
          [
            map (fun i -> Form.Int i) int;
            map (fun r -> Form.Real r) real;
            map (fun s -> Form.Text s) string_small;
            map (fun s -> Form.Sym s) ident;
            map (fun s -> Form.Hash (Hash.of_string s)) string_small;
          ]
      in
      let sub = self (n / 4) in
      let group =
        map
          (fun fs -> Form.form "group" (List.map (fun f -> Form.F f) fs))
          (list_size (int_bound 3) sub)
      in
      let arg =
        if n = 0 then scalar
        else oneof [ scalar; map (fun f -> Form.F f) sub; map (fun g -> Form.F g) group ]
      in
      map2 (fun h args -> Form.form h args) head (list_size (int_bound 4) arg))

let prop_roundtrip_print_parse =
  QCheck.Test.make ~count:1000 ~name:"prop_roundtrip_print_parse"
    (QCheck.make gen_printable_form ~print:Printer.print) (fun f ->
      match Reader.parse_one ~file:"rt.jqd" (Printer.print f) with
      | Ok f' -> Form.equal_ignoring_meta f f'
      | Error _ -> false)

(* Forms the notation cannot represent must fail loudly, never print silently
   corrupted output (they would reparse as a different form). *)
let test_unprintable_forms_raise () =
  let check what f =
    match Printer.print f with
    | exception Printer.Bug_unprintable _ -> ()
    | s -> Alcotest.failf "%s should raise Bug_unprintable, printed %S" what s
  in
  check "empty symbol" (Form.form "var" [ Form.Sym "" ]);
  check "symbol with space" (Form.form "var" [ Form.Sym "a b" ]);
  check "uppercase symbol" (Form.form "var" [ Form.Sym "Foo" ]);
  check "invalid head" (Form.form "Bad" [ Form.Int 1 ]);
  check "group with leading scalar" (Form.form "group" [ Form.Int 1 ])

let suite =
  [
    Alcotest.test_case "canonical layout" `Quick test_canonical_layout;
    Alcotest.test_case "unprintable forms raise" `Quick test_unprintable_forms_raise;
    Alcotest.test_case "real representations" `Quick test_real_reprs;
    Alcotest.test_case "roundtrip over valid corpus" `Quick test_roundtrip_corpus;
    QCheck_alcotest.to_alcotest prop_roundtrip_print_parse;
  ]
