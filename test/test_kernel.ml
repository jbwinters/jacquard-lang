open Jacquard

let hex = Hash.to_hex (Hash.of_string "seed")

let parse s =
  match Reader.parse_one ~file:"k.wft" s with
  | Ok f -> f
  | Error ds ->
      Alcotest.failf "test source %S does not parse: %s" s
        (String.concat "; " (List.map Diag.to_string ds))

let accepts what s =
  match Kernel.of_form (parse s) with
  | Ok _ -> ()
  | Error ds ->
      Alcotest.failf "%s: expected %S to validate: %s" what s
        (String.concat "; " (List.map Diag.to_string ds))

let rejects what code s =
  match Kernel.of_form (parse s) with
  | Ok _ -> Alcotest.failf "%s: expected %S to be rejected with %s" what s code
  | Error [ d ] -> Alcotest.(check string) (what ^ ": code") code d.Diag.code
  | Error _ -> Alcotest.failf "%s: expected exactly one diagnostic" what

(* Every kernel form: >= 1 accepting, >= 2 rejecting (wrong arity, wrong sort).
   (name, accepted sources, rejected (code, source) pairs) *)
let table =
  [
    (* --- expr, 12 forms --- *)
    ( "lit",
      [ "(lit 1)"; "(lit 3.14)"; "(lit \"hi\")" ],
      [ ("E0202", "(lit)"); ("E0202", "(lit 1 2)"); ("E0203", "(lit x)") ] );
    ("var", [ "(var x)" ], [ ("E0202", "(var)"); ("E0203", "(var 42)"); ("E0202", "(var x y)") ]);
    ( "ref",
      [ Printf.sprintf "(ref #%s term)" hex; Printf.sprintf "(ref #%s op)" hex ],
      [
        ("E0202", "(ref)");
        ("E0203", "(ref x term)");
        ("E0210", Printf.sprintf "(ref #%s banana)" hex);
      ] );
    ( "lam",
      [ "(lam ((pvar x)) (var x))"; "(lam () (lit 1))"; "(lam ((pwild) (pvar y)) (var y))" ],
      [
        ("E0202", "(lam ((pvar x)))");
        ("E0203", "(lam x (var x))");
        ("E0205", "(lam ((plit 1)) (lit 1))");
      ] );
    ( "app",
      [ "(app (var f))"; "(app (var f) (lit 1) (lit 2))" ],
      [ ("E0202", "(app)"); ("E0203", "(app 42)"); ("E0203", "(app (var f) 42)") ] );
    ( "let",
      [ "(let nonrec (pvar x) (lit 1) (var x))"; "(let rec (pvar f) (lam () (lit 1)) (var f))" ],
      [
        ("E0202", "(let nonrec (pvar x) (lit 1))");
        ("E0211", "(let sometimes (pvar x) (lit 1) (var x))");
        ("E0203", "(let nonrec x (lit 1) (var x))");
      ] );
    ( "match",
      [ "(match (var x) (clause (pwild) (lit 1)))" ],
      [
        ("E0209", "(match (var x))");
        ("E0201", "(match (var x) (pvar y))");
        ("E0202", "(match (var x) (clause (pwild)))");
      ] );
    ( "tuple",
      [ "(tuple)"; "(tuple (lit 1) (lit 2))" ],
      [ ("E0203", "(tuple 42)"); ("E0203", "(tuple (lit 1) x)") ] );
    ( "handle",
      [
        "(handle (app (var body)) (ret (pvar x) (var x)))";
        "(handle (app (var body)) (ret (pvar x) (var x)) (opclause abort () k (lit 0)))";
      ],
      [
        ("E0202", "(handle (app (var body)))");
        ("E0212", "(handle (app (var body)) (clause (pvar x) (var x)))");
        ("E0212", "(handle (app (var body)) (ret (pvar x) (var x)) (ret (pvar y) (var y)))");
      ] );
    ( "quote",
      [ "(quote (lit 1))"; "(quote (anything (goes here) 42))" ],
      [ ("E0202", "(quote)"); ("E0203", "(quote 42)"); ("E0202", "(quote (lit 1) (lit 2))") ] );
    ( "unquote",
      [
        "(quote (app (unquote (var f)) (lit 1)))";
        (* an unquote under a NESTED quote is data (level 1), so its splice is not checked *)
        "(quote (quote (unquote (nonsense))))";
      ],
      [
        ("E0204", "(unquote (var f))");
        ("E0202", "(quote (unquote))");
        ("E0201", "(quote (unquote (nonsense)))");
      ] );
    ( "ann",
      [ "(ann (lit 1) (tref int))" ],
      [
        ("E0202", "(ann (lit 1))");
        ("E0203", "(ann (lit 1) 42)");
        ("E0201", "(ann (lit 1) (pvar x))");
      ] );
    (* internal marker, not one of the 27: accepted so store objects re-validate;
       hashing gates it (E0503, see test_canon) *)
    ( "groupref (internal)",
      [ "(groupref 0)" ],
      [ ("E0202", "(groupref)"); ("E0203", "(groupref x)"); ("E0203", "(groupref -1)") ] );
    (* --- pat, 6 forms (validated in pattern positions) --- *)
    ( "pwild",
      [ "(lam ((pwild)) (lit 1))" ],
      [
        ("E0202", "(match (var x) (clause (pwild 1) (lit 1)))");
        ("E0201", "(match (var x) (clause (wild) (lit 1)))");
      ] );
    ( "pvar",
      [ "(match (var x) (clause (pvar y) (var y)))" ],
      [
        ("E0202", "(match (var x) (clause (pvar) (lit 1)))");
        ("E0203", "(match (var x) (clause (pvar 42) (lit 1)))");
      ] );
    ( "plit",
      [ "(match (var x) (clause (plit 0) (lit 1)))" ],
      [
        ("E0202", "(match (var x) (clause (plit) (lit 1)))");
        ("E0203", "(match (var x) (clause (plit y) (lit 1)))");
      ] );
    ( "pcon",
      [
        "(match (var x) (clause (pcon true) (lit 1)))";
        Printf.sprintf "(match (var x) (clause (pcon #%s (pvar y)) (var y)))" hex;
      ],
      [
        ("E0202", "(match (var x) (clause (pcon) (lit 1)))");
        ("E0203", "(match (var x) (clause (pcon 42) (lit 1)))");
        ("E0203", "(match (var x) (clause (pcon true 42) (lit 1)))");
      ] );
    ( "ptuple",
      [ "(match (var x) (clause (ptuple (pvar a) (pvar b)) (var a)))" ],
      [
        ("E0203", "(match (var x) (clause (ptuple 42) (lit 1)))");
        ("E0201", "(match (var x) (clause (ptuple (lit 1)) (lit 1)))");
      ] );
    ( "pas",
      [ "(match (var x) (clause (pas whole (ptuple (pvar a) (pwild))) (var whole)))" ],
      [
        ("E0202", "(match (var x) (clause (pas whole) (lit 1)))");
        ("E0203", "(match (var x) (clause (pas (pvar y) (pwild)) (lit 1)))");
      ] );
    (* --- type, 6 forms (validated in ann positions) --- *)
    ( "tref",
      [ "(ann (lit 1) (tref int))"; Printf.sprintf "(ann (lit 1) (tref #%s))" hex ],
      [ ("E0202", "(ann (lit 1) (tref))"); ("E0203", "(ann (lit 1) (tref 42))") ] );
    ( "tvar",
      [ "(ann (lit 1) (tvar a))" ],
      [ ("E0202", "(ann (lit 1) (tvar))"); ("E0203", "(ann (lit 1) (tvar 42))") ] );
    ( "tapp",
      [ "(ann (var x) (tapp (tref option) (tref int)))" ],
      [
        ("E0202", "(ann (var x) (tapp (tref option)))");
        ("E0203", "(ann (var x) (tapp (tref option) 42))");
      ] );
    ( "tarrow",
      [
        "(ann (var f) (tarrow ((tref int)) (row) (tref int)))";
        "(ann (var f) (tarrow ((tref int)) (row (eref console) e) (tref int)))";
      ],
      [
        ("E0202", "(ann (var f) (tarrow ((tref int)) (row)))");
        ("E0203", "(ann (var f) (tarrow x (row) (tref int)))");
        ("E0203", "(ann (var f) (tarrow ((tref int)) (row (tref console)) (tref int)))");
      ] );
    ( "ttuple",
      [ "(ann (var x) (ttuple))"; "(ann (var x) (ttuple (tref int) (tvar a)))" ],
      [ ("E0203", "(ann (var x) (ttuple 42))"); ("E0201", "(ann (var x) (ttuple (pvar y)))") ] );
    ( "tforall",
      [ "(ann (var f) (tforall ((tvar a)) ((rvar e)) (tarrow ((tvar a)) (row e) (tvar a))))" ],
      [
        ("E0202", "(ann (var f) (tforall ((tvar a)) (tvar a)))");
        ("E0203", "(ann (var f) (tforall ((rvar a)) () (tvar a)))");
        ("E0203", "(ann (var f) (tforall () ((tvar e)) (tvar a)))");
      ] );
    (* --- decl, 3 forms --- *)
    ( "defterm",
      [ "(defterm ((binding one () (lit 1))))" ],
      [
        ("E0202", "(defterm)");
        ("E0202", "(defterm ())");
        ("E0201", "(defterm ((clause (pwild) (lit 1))))");
        ("E0202", "(defterm ((binding one ((tref int) (tref int)) (lit 1))))");
      ] );
    ( "deftype",
      [
        "(deftype bool () (con false) (con true))";
        "(deftype option ((tvar a)) (con none) (con some (field (tvar a))))";
        "(deftype point () (con point (field x (tref int)) (field y (tref int))))";
      ],
      [
        ("E0202", "(deftype bool ())");
        ("E0203", "(deftype bool x (con true))");
        ("E0201", "(deftype bool () (binding one () (lit 1)))");
      ] );
    ( "defeffect",
      [ "(defeffect console () (op print ((tref text)) (ttuple)))" ],
      [
        ("E0202", "(defeffect console ())");
        ("E0202", "(defeffect console () (op print ((tref text))))");
        ("E0201", "(defeffect console () (con print))");
      ] );
  ]

let test_table () =
  List.iter
    (fun (name, oks, errs) ->
      List.iter (fun s -> accepts name s) oks;
      List.iter (fun (code, s) -> rejects name code s) errs)
    table

(* --- structural rules, one dedicated test each --- *)

let test_unquote_only_under_quote () =
  rejects "top-level unquote" "E0204" "(unquote (var f))";
  rejects "unquote in app" "E0204" "(app (unquote (var f)) (lit 1))";
  accepts "unquote under quote" "(quote (foo (unquote (app (var mk) (lit 1)))))";
  accepts "unquote under nested data" "(quote (a (b (unquote (var x)))))";
  (* quasiquote levels: under a nested quote the unquote is data; two unquotes deep it is
     live again relative to the inner quote *)
  accepts "unquote under nested quote is unchecked data" "(quote (quote (unquote (nonsense))))";
  rejects "double unquote under double quote is live" "E0201"
    "(quote (quote (unquote (unquote (nonsense)))))"

let test_lam_params_irrefutable () =
  rejects "plit param" "E0205" "(lam ((plit 0)) (lit 1))";
  rejects "pcon param" "E0205" "(lam ((pcon true)) (lit 1))";
  rejects "nested refutable in ptuple" "E0205" "(lam ((ptuple (pvar x) (plit 0))) (var x))";
  accepts "pas of irrefutable" "(lam ((pas p (ptuple (pvar x) (pwild)))) (var p))"

let test_let_binder_irrefutable () =
  rejects "pcon binder" "E0206" "(let nonrec (pcon true) (var b) (lit 1))";
  accepts "ptuple binder" "(let nonrec (ptuple (pvar a) (pvar b)) (var p) (var a))"

let test_let_rec_shape () =
  rejects "rec binder not pvar" "E0207" "(let rec (ptuple (pvar f)) (lam () (lit 1)) (var f))";
  rejects "rec refutable binder still E0207" "E0207" "(let rec (plit 0) (lam () (lit 1)) (lit 1))";
  rejects "rec value not lam" "E0208" "(let rec (pvar f) (lit 1) (var f))";
  accepts "rec ok" "(let rec (pvar f) (lam ((pvar n)) (app (var f) (var n))) (var f))"

let test_match_nonempty () = rejects "empty match" "E0209" "(match (var x))"

let test_handle_single_ret () =
  rejects "second ret rejected" "E0212"
    "(handle (var b) (ret (pvar x) (var x)) (ret (pvar y) (var y)))";
  rejects "missing ret" "E0212" "(handle (var b) (opclause abort () k (lit 0)))"

(* --- to_form . of_form is the identity on the typed AST --- *)

let corpus_dir = "../corpus/valid"

let read_file path =
  let ic = open_in_bin path in
  let s = really_input_string ic (in_channel_length ic) in
  close_in ic;
  s

let test_to_form_of_form_identity () =
  let check_src what src =
    let forms =
      match Reader.parse_string ~file:what src with
      | Ok fs -> fs
      | Error _ -> Alcotest.failf "%s does not parse" what
    in
    List.iter
      (fun f ->
        match Kernel.of_form f with
        | Error ds ->
            Alcotest.failf "%s: does not validate: %s" what
              (String.concat "; " (List.map Diag.to_string ds))
        | Ok t -> (
            let f' = Kernel.to_form t in
            match Kernel.of_form f' with
            | Error _ -> Alcotest.failf "%s: to_form output does not re-validate" what
            | Ok t' ->
                if not (t = t') then Alcotest.failf "%s: of_form(to_form t) <> t" what;
                (* and the emitted form is the same triple, meta included *)
                if not (Form.equal_ignoring_meta f f' && Meta.equal f.Form.meta f'.Form.meta) then
                  Alcotest.failf "%s: to_form lost structure or root meta" what))
      forms
  in
  (* every valid corpus file... *)
  Sys.readdir corpus_dir |> Array.to_list
  |> List.filter (fun f -> Filename.check_suffix f ".wft")
  |> List.iter (fun f -> check_src f (read_file (Filename.concat corpus_dir f)));
  (* ...plus sources exercising forms the corpus lacks *)
  List.iter (fun (name, oks, _) -> List.iter (fun s -> check_src ("table:" ^ name) s) oks) table;
  (* ...and the identity must hold on RESOLVED trees too (Ref/GroupRef/name-meta) *)
  Sys.readdir corpus_dir |> Array.to_list
  |> List.filter (fun f -> Filename.check_suffix f ".wft")
  |> List.iter (fun file ->
      match Reader.parse_string ~file (read_file (Filename.concat corpus_dir file)) with
      | Error _ -> Alcotest.failf "%s does not parse" file
      | Ok forms ->
          List.iter
            (fun f ->
              match Result.bind (Kernel.of_form f) (Resolve.resolve Corpus_support.stub_names) with
              | Error ds ->
                  Alcotest.failf "%s: resolution failed: %s" file
                    (String.concat "; " (List.map Diag.to_string ds))
              | Ok resolved -> (
                  match Kernel.of_form (Kernel.to_form resolved) with
                  | Ok resolved' when resolved = resolved' -> ()
                  | Ok _ -> Alcotest.failf "%s: resolved identity broken" file
                  | Error _ -> Alcotest.failf "%s: resolved to_form does not re-validate" file))
            forms)

let suite =
  [
    Alcotest.test_case "27-form accept/reject table" `Quick test_table;
    Alcotest.test_case "unquote only under quote" `Quick test_unquote_only_under_quote;
    Alcotest.test_case "lam params irrefutable" `Quick test_lam_params_irrefutable;
    Alcotest.test_case "let binder irrefutable" `Quick test_let_binder_irrefutable;
    Alcotest.test_case "let rec shape" `Quick test_let_rec_shape;
    Alcotest.test_case "match nonempty" `Quick test_match_nonempty;
    Alcotest.test_case "handle single ret" `Quick test_handle_single_ret;
    Alcotest.test_case "to_form then of_form is identity" `Quick test_to_form_of_form_identity;
  ]
