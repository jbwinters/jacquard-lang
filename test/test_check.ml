open Jacquard

(* W3.2: expression inference — golden signatures over corpus/sigs, plus the specific
   done-when cases (identity, console row, value restriction, annotation mismatch). *)

let golden_file = "../corpus/golden/sigs.golden"

let make_cctx () =
  let store, _ectx = Eval_support.make_prelude_ctx () in
  match Check.make_ctx store with
  | Error ds -> Eval_support.fail_diags "make_ctx" ds
  | Ok ctx -> (
      match Prelude.builtin_signatures store with
      | Error ds -> Eval_support.fail_diags "builtin sigs" ds
      | Ok sigs ->
          Check.register_builtin_signatures ctx sigs;
          (store, ctx))

let check_src (store, ctx) src : (Check.top_sig, Diag.t list) result =
  match Reader.parse_string ~file:"c.jqd" src with
  | Error ds -> Error ds
  | Ok forms ->
      let rec go last = function
        | [] -> ( match last with Some s -> Ok s | None -> Error [])
        | f :: rest -> (
            match Kernel.of_form f with
            | Error ds -> Error ds
            | Ok top -> (
                match Resolve.resolve (Store.names_view store) top with
                | Error ds -> Error ds
                | Ok resolved -> (
                    match Check.check_top ctx resolved with
                    | Error ds -> Error ds
                    | Ok s -> (
                        match resolved with
                        | Kernel.Decl d -> (
                            match Store.put_decl store d with
                            | Ok _ -> go (Some s) rest
                            | Error ds -> Error ds)
                        | Kernel.Expr _ -> go (Some s) rest))))
      in
      go None forms

let sig_of h src =
  match check_src h src with
  | Ok { Check.names = [ (_, s) ]; _ } -> Check.show_scheme (snd h) s
  | Ok { Check.names; _ } ->
      String.concat "; " (List.map (fun (n, s) -> n ^ " : " ^ Check.show_scheme (snd h) s) names)
  | Error ds -> Eval_support.fail_diags "check" ds

let err_of h src =
  match check_src h src with
  | Ok _ -> Alcotest.failf "expected %s to fail the checker" src
  | Error [ d ] -> d
  | Error ds -> Alcotest.failf "expected one diagnostic, got %d" (List.length ds)

(* --- the 20-program golden corpus --- *)

let test_golden_sigs () =
  match Corpus_support.sig_lines ~prelude_dir:"../prelude" ~sigs_dir:"../corpus/sigs" with
  | Error ds -> Eval_support.fail_diags "sig corpus" ds
  | Ok actual ->
      let expected =
        Corpus_support.read_file golden_file
        |> String.split_on_char '\n'
        |> List.filter (fun l -> l <> "")
      in
      Alcotest.(check bool)
        "sigs corpus has >= 20 files" true
        (List.length (Corpus_support.jqd_files "../corpus/sigs") >= 20);
      Alcotest.(check (list string))
        "elaborated signatures match corpus/golden/sigs.golden (regenerate with `dune exec \
         test/gen_sig_goldens.exe`)"
        expected actual

(* --- named done-when cases --- *)

let test_identity () =
  let h = make_cctx () in
  Alcotest.(check string) "identity" "forall a. (a) ->{} a" (sig_of h "(lam ((pvar x)) (var x))")

let test_console_row_shows () =
  let h = make_cctx () in
  Alcotest.(check string)
    "console function row" "() ->{Console} ()"
    (sig_of h "(lam () (app (var print) (lit \"x\")))");
  (* composition of pure and effectful propagates the row *)
  Alcotest.(check string)
    "propagates through composition" "() ->{Console} Int"
    (sig_of h
       "(lam () (let nonrec (pvar u) (app (var print) (lit \"x\")) (app (var add) (lit 1) (lit \
        2))))")

let test_value_restriction () =
  let h = make_cctx () in
  (* a lam binding generalizes: usable at two types *)
  (match
     check_src h
       "(let nonrec (pvar i) (lam ((pvar x)) (var x)) (tuple (app (var i) (lit 1)) (app (var i) \
        (lit \"s\"))))"
   with
  | Ok _ -> ()
  | Error ds -> Eval_support.fail_diags "value generalizes" ds);
  (* a non-value binding does not: second use at a different type fails *)
  match
    check_src h
      "(let nonrec (pvar i) (app (lam ((pvar x)) (var x)) (lam ((pvar y)) (var y))) (tuple (app \
       (var i) (lit 1)) (app (var i) (lit \"s\"))))"
  with
  | Ok _ -> Alcotest.fail "non-value must not generalize"
  | Error [ d ] ->
      Alcotest.(check string) "focused code" "E0816" d.Diag.code;
      Alcotest.(check (option string))
        "actionable value-restriction hint"
        (Some "eta-expand the binding to a lambda value, or give each use its own binding")
        d.Diag.hint
  | Error _ -> Alcotest.fail "expected one diagnostic"

let test_ann_mismatch_elaborated () =
  let h = make_cctx () in
  let d = err_of h "(ann (lit 1) (tref text))" in
  Alcotest.(check string) "code" "E0804" d.Diag.code;
  Alcotest.(check bool)
    "both types printed" true
    (let has needle =
       let n = String.length needle and m = String.length d.Diag.message in
       let rec go i = i + n <= m && (String.sub d.Diag.message i n = needle || go (i + 1)) in
       go 0
     in
     has "text" && has "int")

let test_ann_skolem_escape () =
  let h = make_cctx () in
  (* claiming (a) -> a for a function returning int must fail: a is rigid *)
  let d =
    err_of h
      "(ann (lam ((pvar x)) (lit 1)) (tforall ((tvar a)) () (tarrow ((tvar a)) (row) (tvar a))))"
  in
  Alcotest.(check string) "code" "E0804" d.Diag.code

let test_effect_row_mismatch () =
  let h = make_cctx () in
  (* annotation says pure, body prints *)
  let d = err_of h "(ann (lam () (app (var print) (lit \"x\"))) (tarrow () (row) (ttuple)))" in
  Alcotest.(check string) "code" "E0804" d.Diag.code

let test_application_arity () =
  let h = make_cctx () in
  let d = err_of h "(app (lam ((pvar x)) (var x)) (lit 1) (lit 2))" in
  Alcotest.(check string) "code" "E0803" d.Diag.code

let test_not_a_function () =
  let h = make_cctx () in
  let d = err_of h "(app (lit 3) (lit 1))" in
  Alcotest.(check string) "code" "E0802" d.Diag.code

let test_handler_removes_effect () =
  let h = make_cctx () in
  (* fully handled: the row comes out empty; the value is pure *)
  Alcotest.(check string)
    "handled program is pure" "Option Int"
    (sig_of h
       "(handle (app (var div) (lit 1) (lit 0)) (ret (pvar x) (app (var some) (var x))) (opclause \
        abort () k (var none)))")

let test_resume_type_enforced () =
  let h = make_cctx () in
  (* resume takes the op result (here: polymorphic abort result unifies), so applying resume
     to two arguments is an arity error *)
  let d =
    err_of h
      "(handle (app (var abort)) (ret (pvar x) (var x)) (opclause abort () k (app (var k) (lit 1) \
       (lit 2))))"
  in
  Alcotest.(check string) "code" "E0803" d.Diag.code

let test_resume_wrong_typed_argument () =
  let h = make_cctx () in
  (* print's op result is (): resuming with an int is a type error *)
  let d =
    err_of h
      "(handle (app (var print) (lit \"x\")) (ret (pvar x) (var x)) (opclause print ((pvar t)) k \
       (app (var k) (lit 1))))"
  in
  Alcotest.(check string) "code" "E0801" d.Diag.code

let test_op_clause_arity () =
  let h = make_cctx () in
  (* print takes one parameter; a two-param clause is rejected *)
  let d =
    err_of h
      "(handle (app (var print) (lit \"x\")) (ret (pvar x) (var x)) (opclause print ((pvar a) \
       (pvar b)) k (app (var k) (tuple))))"
  in
  Alcotest.(check string) "code" "E0803" d.Diag.code

let test_declaration_kind_checks () =
  let h = make_cctx () in
  (* wrong arity in a field type *)
  (match
     check_src h "(deftype bad ((tvar a)) (con mk (field (tapp (tref option) (tvar a) (tvar a)))))"
   with
  | Error [ d ] -> Alcotest.(check string) "arity" "E0810" d.Diag.code
  | _ -> Alcotest.fail "expected E0810");
  (* unbound tyvar in a field *)
  (match check_src h "(deftype bad2 () (con mk (field (tvar zz))))" with
  | Error [ d ] -> Alcotest.(check string) "unbound" "E0811" d.Diag.code
  | _ -> Alcotest.fail "expected E0811");
  (* op returning an unbound var: its own code, distinct from type-decl unbound *)
  match check_src h "(defeffect bade () (op o () (tvar zz)))" with
  | Error [ d ] -> Alcotest.(check string) "op unbound" "E0812" d.Diag.code
  | _ -> Alcotest.fail "expected E0812"

let test_group_annotations () =
  let h = make_cctx () in
  (* even/odd with annotations honored as checks *)
  (match
     check_src h
       "(defterm ((binding even2 ((tarrow ((tref int)) (row) (tref bool))) (lam ((pvar n)) (match \
        (var n) (clause (plit 0) (var true)) (clause (pvar m) (app (var odd2) (app (var sub) (var \
        m) (lit 1))))))) (binding odd2 () (lam ((pvar n)) (match (var n) (clause (plit 0) (var \
        false)) (clause (pvar m) (app (var even2) (app (var sub) (var m) (lit 1)))))))))"
   with
  | Ok { Check.names; _ } ->
      Alcotest.(check (list string))
        "both members typed"
        [ "even2 : (Int) ->{} Bool"; "odd2 : (Int) ->{} Bool" ]
        (List.map (fun (n, s) -> n ^ " : " ^ Check.show_scheme (snd h) s) names)
  | Error ds -> Eval_support.fail_diags "even/odd annotated" ds);
  (* a lying annotation is rejected *)
  match
    check_src h
      "(defterm ((binding liar ((tarrow ((tref int)) (row) (tref text))) (lam ((pvar n)) (var \
       n)))))"
  with
  | Error [ d ] -> Alcotest.(check string) "annotation mismatch" "E0804" d.Diag.code
  | _ -> Alcotest.fail "expected E0804"

let suite =
  [
    Alcotest.test_case "golden signatures (20+ programs)" `Quick test_golden_sigs;
    Alcotest.test_case "identity" `Quick test_identity;
    Alcotest.test_case "console row shows and propagates" `Quick test_console_row_shows;
    Alcotest.test_case "value restriction" `Quick test_value_restriction;
    Alcotest.test_case "ann mismatch elaborated" `Quick test_ann_mismatch_elaborated;
    Alcotest.test_case "ann skolem escape" `Quick test_ann_skolem_escape;
    Alcotest.test_case "effect row mismatch in ann" `Quick test_effect_row_mismatch;
    Alcotest.test_case "application arity" `Quick test_application_arity;
    Alcotest.test_case "not a function" `Quick test_not_a_function;
    Alcotest.test_case "handler removes effect" `Quick test_handler_removes_effect;
    Alcotest.test_case "resume type enforced" `Quick test_resume_type_enforced;
    Alcotest.test_case "resume wrong-typed argument" `Quick test_resume_wrong_typed_argument;
    Alcotest.test_case "op clause arity" `Quick test_op_clause_arity;
    Alcotest.test_case "declaration kind checks" `Quick test_declaration_kind_checks;
    Alcotest.test_case "group annotations honored" `Quick test_group_annotations;
  ]
