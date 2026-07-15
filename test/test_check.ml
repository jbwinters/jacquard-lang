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

let once_handler body =
  Printf.sprintf
    "(defeffect linear () (op signal once () (tref int)))\n\
     (handle (app (var signal)) (ret (pvar x) (var x)) (opclause signal () k %s))"
    body

let once_transformer_handle body =
  Printf.sprintf
    "(handle (app (var signal)) (ret (pvar x) (lam ((ptuple)) (var x))) (opclause signal () k %s))"
    body

let once_polymorphic_transformer_handle body =
  Printf.sprintf
    "(handle (app (var signal)) (ret (pvar x) (lam ((pvar value)) (var x))) (opclause signal () k \
     %s))"
    body

let with_once_transformer expression =
  "(defeffect linear () (op signal once () (tref int)))\n" ^ expression

let check_ok h what src =
  match check_src h src with Ok _ -> () | Error ds -> Eval_support.fail_diags what ds

let contains haystack needle =
  let n = String.length needle and m = String.length haystack in
  let rec go i = i + n <= m && (String.sub haystack i n = needle || go (i + 1)) in
  go 0

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
  | Error [ d ] -> Alcotest.(check string) "mismatch code" "E0801" d.Diag.code
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

(* --- EL.2: built-in affine Resume for Once clauses --- *)

let test_once_resume_zero_or_one_per_path () =
  check_ok (make_cctx ()) "once resumption may be dropped" (once_handler "(lit 0)");
  check_ok (make_cctx ()) "once resumption may be consumed once"
    (once_handler "(app (var k) (lit 1))");
  check_ok (make_cctx ()) "exclusive branches have independent affine budgets"
    (once_handler
       "(match (var true) (clause (pcon true) (app (var k) (lit 1))) (clause (pcon false) (app \
        (var k) (lit 2))))")

let test_once_resume_immediate_transformer () =
  let canonical_state =
    "(defeffect local-state () (op local-get once () (tref int)) (op local-put once ((tref int)) \
     (ttuple)))\n\
     (app (handle (let nonrec (pwild) (app (var local-put) (lit 42)) (app (var local-get))) (ret \
     (pvar x) (lam ((pvar s)) (tuple (var x) (var s)))) (opclause local-get () k (lam ((pvar s)) \
     (app (app (var k) (var s)) (var s)))) (opclause local-put ((pvar next-state)) k (lam ((pvar \
     s)) (app (app (var k) (tuple)) (var next-state))))) (lit 41))"
  in
  check_ok (make_cctx ()) "canonical once State transformer is immediately eliminated"
    canonical_state;
  let successive_once clause_body =
    Printf.sprintf
      "(defeffect successive () (op first once () (tref int)) (op second once () (tref int)))\n\
       (app\n\
       (handle\n\
       (let nonrec (pvar x) (app (var first))\n\
       (let nonrec (pvar y) (app (var second))\n\
       (app (var add) (var x) (var y))))\n\
       (ret (pvar x) (lam ((pvar unit)) (var x)))\n\
       (opclause first () k %s)\n\
       (opclause second () later-k\n\
       (lam ((pvar unit)) (app (app (var later-k) (lit 2)) (var unit)))))\n\
       (tuple))"
      clause_body
  in
  check_ok (make_cctx ()) "successive Once transformers eliminate each produced answer immediately"
    (successive_once "(lam ((pvar unit)) (app (app (var k) (lit 1)) (var unit)))");
  let laundered_later =
    err_of (make_cctx ())
      (successive_once
         "(lam ((pvar unit))\n\
          (let nonrec (pvar later) (app (var k) (lit 1))\n\
          (let nonrec (pwild) (app (var later) (var unit))\n\
          (app (var later) (var unit)))))")
  in
  Alcotest.(check string)
    "a bound answer cannot launder a later Once token" "E0817" laundered_later.code;
  Alcotest.(check bool)
    "later-token laundering has a pointed explanation" true
    (contains laundered_later.message "may produce a transformer carrying a later once resumption");
  let intervening_multi =
    err_of (make_cctx ())
      (successive_once
         "(lam ((pvar unit))\n\
          (app (app (var k) (lit 1))\n\
          (let nonrec (pwild) (app (var flaky) (lit \"between\")) (var unit))))")
  in
  Alcotest.(check string)
    "a Multi effect cannot run while a later Once transformer is live" "E0817"
    intervening_multi.code;
  let duplicated_current =
    err_of (make_cctx ())
      (successive_once
         "(lam ((pvar unit))\n\
          (let nonrec (pwild) (app (app (var k) (lit 1)) (var unit))\n\
          (app (app (var k) (lit 1)) (var unit))))")
  in
  Alcotest.(check string)
    "direct duplication in a successive Once transformer remains affine" "E0816"
    duplicated_current.code;
  let direct body args =
    with_once_transformer (Printf.sprintf "(app %s %s)" (once_transformer_handle body) args)
  in
  let good_body = "(lam ((pvar unit)) (app (app (var k) (lit 1)) (var unit)))" in
  check_ok (make_cctx ()) "direct transformer over a value argument" (direct good_body "(tuple)");
  let polymorphic_handle =
    once_polymorphic_transformer_handle
      "(lam ((pvar value)) (app (app (var k) (lit 1)) (var value)))"
  in
  check_ok (make_cctx ()) "a variable is an immediate value argument"
    (with_once_transformer
       (Printf.sprintf "(let nonrec (pvar value) (tuple) (app %s (var value)))" polymorphic_handle));
  check_ok (make_cctx ()) "constructor trees are immediate value arguments"
    (with_once_transformer (Printf.sprintf "(app %s (app (var some) (lit 1)))" polymorphic_handle));
  check_ok (make_cctx ()) "an inert quote is an immediate value argument"
    (with_once_transformer (Printf.sprintf "(app %s (quote (lit 1)))" polymorphic_handle));
  let expect_escape what source =
    let diagnostic = err_of (make_cctx ()) source in
    Alcotest.(check string) (what ^ " code") "E0817" diagnostic.code;
    Alcotest.(check bool) (what ^ " has a source span") true (Option.is_some diagnostic.span)
  in
  let bare = once_transformer_handle good_body in
  expect_escape "transformer bound before application"
    (with_once_transformer
       (Printf.sprintf "(let nonrec (pvar transformer) %s (app (var transformer) (tuple)))" bare));
  expect_escape "transformer returned" (with_once_transformer bare);
  expect_escape "transformer stored" (with_once_transformer (Printf.sprintf "(tuple %s)" bare));
  expect_escape "transformer passed"
    (with_once_transformer
       (Printf.sprintf "(app (lam ((pvar transformer)) (app (var transformer) (tuple))) %s)" bare));
  expect_escape "transformer aliased and applied twice"
    (with_once_transformer
       (Printf.sprintf
          "(let nonrec (pvar transformer) %s (tuple (app (var transformer) (tuple)) (app (var \
           transformer) (tuple))))"
          bare));
  expect_escape "effectful immediate argument"
    (direct good_body "(app (var print) (lit \"not a value\"))");
  expect_escape "effectful argument keeps malformed outer call outside the transformer boundary"
    (direct good_body "(app (var print) (lit \"not a value\")) (tuple)");
  expect_escape "live-splice quote argument"
    (with_once_transformer
       (Printf.sprintf
          "(let nonrec (pvar code-value) (quote (lit 1)) (app %s (quote (unquote (var \
           code-value)))))"
          polymorphic_handle));
  expect_escape "nested transformer lambda"
    (direct "(lam ((pvar unit)) (lam ((pvar later)) (app (app (var k) (lit 1)) (var unit))))"
       "(tuple)");
  expect_escape "transformer quote capture"
    (direct "(lam ((pvar unit)) (quote (unquote (var k))))" "(tuple)");
  expect_escape "transformer data storage"
    (direct "(lam ((pvar unit)) (app (var some) (var k)))" "(tuple)");
  expect_escape "transformer nested handler clause"
    (direct
       "(lam ((pvar unit)) (handle (app (var signal)) (ret (pvar x) (var x)) (opclause signal () \
        inner (app (app (var k) (lit 1)) (var unit)))))"
       "(tuple)");
  let doubled =
    err_of (make_cctx ())
      (direct
         "(lam ((pvar unit)) (let nonrec (pwild) (app (app (var k) (lit 1)) (var unit)) (app (app \
          (var k) (lit 2)) (var unit))))"
         "(tuple)")
  in
  Alcotest.(check string) "double resume in transformer" "E0816" doubled.code;
  Alcotest.(check bool)
    "double transformer resume retains both witnesses" true
    (contains doubled.message "first consumption at c.jqd:"
    && contains doubled.message "second consumption at c.jqd:");
  let outer_arity = err_of (make_cctx ()) (direct good_body "(tuple) (tuple)") in
  Alcotest.(check string)
    "outer malformed application keeps arity precedence" "E0803" outer_arity.code;
  let resume_arity = err_of (make_cctx ()) (direct "(lam ((pvar unit)) (app (var k)))" "(tuple)") in
  Alcotest.(check string) "inner malformed resume keeps arity precedence" "E0803" resume_arity.code;
  let argument_type = err_of (make_cctx ()) (direct good_body "(lit 1)") in
  Alcotest.(check string)
    "value argument still receives ordinary type checking" "E0801" argument_type.code;
  check_ok (make_cctx ()) "ordinary State remains accepted"
    "(app (var state.run) (lam () (app (var get))) (lit 41))";
  check_ok (make_cctx ()) "ordinary Check remains accepted"
    "(app (var test.run) (lam () (app (var check) (var true) (lit \"still works\"))))"

let test_once_resume_gate_style_transfer () =
  test_once_resume_immediate_transformer ();
  check_ok (make_cctx ()) "moving Resume into an affine helper parameter"
    (once_handler
       "(let nonrec (pvar gate) (lam ((pvar next)) (app (var next) (lit 1))) (app (var gate) (var \
        k)))");
  check_ok (make_cctx ()) "the receiving parameter also gets branch-local budgets"
    (once_handler
       "(let nonrec (pvar gate) (lam ((pvar next)) (match (var true) (clause (pcon true) (app (var \
        next) (lit 1))) (clause (pcon false) (app (var next) (lit 2))))) (app (var gate) (var k)))");
  check_ok (make_cctx ()) "a stored gate is contextually checked at Resume transfer"
    ("(defeffect linear () (op signal once () (tref int)))\n"
   ^ "(defterm ((binding gate () (lam ((pvar next)) (app (var next) (lit 1))))))\n"
   ^ "(handle (app (var signal)) (ret (pvar x) (var x)) "
   ^ "(opclause signal () k (app (var gate) (var k))))")

let test_once_resume_branch_flow_is_bounded () =
  let correlated second_true second_false =
    Printf.sprintf
      "(defeffect linear () (op signal once () (tref int)))\n\
       (lam ((pvar flag)) (handle (app (var signal)) (ret (pvar x) (var x)) (opclause signal () k \
       (let nonrec (pwild) (match (var flag) (clause (pcon true) (app (var k) (lit 1))) (clause \
       (pcon false) (lit 0))) (match (var flag) (clause (pcon true) %s) (clause (pcon false) \
       %s))))))"
      second_true second_false
  in
  check_ok (make_cctx ()) "sequential matches over one immutable value preserve complementary arms"
    (correlated "(lit 0)" "(app (var k) (lit 2))");
  check_ok (make_cctx ()) "an immutable let alias preserves scrutinee identity"
    "(defeffect linear () (op signal once () (tref int)))\n\
    \     (lam ((pvar flag)) (handle (app (var signal)) (ret (pvar x) (var x)) (opclause signal () k\n\
    \     (let nonrec (pvar alias) (var flag) (let nonrec (pwild) (match (var flag) (clause (pcon \
     true)\n\
    \     (app (var k) (lit 1))) (clause (pcon false) (lit 0))) (match (var alias) (clause (pcon \
     true)\n\
    \     (lit 0)) (clause (pcon false) (app (var k) (lit 2)))))))))";
  check_ok (make_cctx ()) "a stable constructor tree preserves aligned nested arms"
    (once_handler
       "(let nonrec (pwild) (match (app (var some) (lit 1)) (clause (pcon some (pwild)) (app (var\n\
       \        k) (lit 1))) (clause (pcon none) (lit 0))) (match (app (var some) (lit 1)) (clause \
        (pcon\n\
       \        some (pvar value)) (lit 0)) (clause (pcon none) (app (var k) (lit 2)))))");
  let correlated_overlap = err_of (make_cctx ()) (correlated "(app (var k) (lit 2))" "(lit 0)") in
  Alcotest.(check string)
    "a feasible repeated arm still consumes twice" "E0816" correlated_overlap.code;
  let shadowed =
    err_of (make_cctx ())
      "(defeffect linear () (op signal once () (tref int)))\n\
       (lam ((pvar flag)) (handle (app (var signal)) (ret (pvar x) (var x)) (opclause signal () k \
       (let nonrec (pwild) (match (var flag) (clause (pcon true) (app (var k) (lit 1))) (clause \
       (pcon false) (lit 0))) (let nonrec (pvar flag) (var false) (match (var flag) (clause (pcon \
       true) (lit 0)) (clause (pcon false) (app (var k) (lit 2)))))))))"
  in
  Alcotest.(check string) "a shadowed name cannot forge scrutinee correlation" "E0816" shadowed.code;
  let unstable =
    err_of (make_cctx ())
      (once_handler
         "(let nonrec (pwild) (match (app (var flaky) (lit \"first\")) (clause (pcon true) (app\n\
         \          (var k) (lit 1))) (clause (pcon false) (lit 0))) (match (app (var flaky) (lit \
          \"second\"))\n\
         \          (clause (pcon true) (lit 0)) (clause (pcon false) (app (var k) (lit 2)))))")
  in
  Alcotest.(check string) "unstable scrutinees remain conservative" "E0816" unstable.code;
  let no_use_match =
    "(match (var true) (clause (pcon true) (lit 0)) (clause (pcon false) (lit 1)))"
  in
  let rec sequence count body =
    if count = 0 then body
    else sequence (count - 1) (Printf.sprintf "(let nonrec (pwild) %s %s)" no_use_match body)
  in
  (* Each match has two token-free paths. Enumerating concrete flow lists makes this fixture require
     2^40 states, while the affine abstraction needs one constant-size state per syntax node. The
     assertion is semantic, not a flaky wall-clock threshold. *)
  check_ok (make_cctx ()) "forty sequential branches keep bounded affine state"
    (once_handler (sequence 40 "(app (var k) (lit 1))"))

let test_once_resume_helper_summaries_are_bounded () =
  let branch_call callee =
    Printf.sprintf
      "(match (var true) (clause (pcon true) (app (var %s) (var next))) (clause (pcon false) (app \
       (var %s) (var next))))"
      callee callee
  in
  let rec helpers index body =
    if index < 0 then body
    else
      let name = Printf.sprintf "gate-%d" index in
      let helper_body =
        if index = 0 then "(app (var next) (lit 1))"
        else branch_call (Printf.sprintf "gate-%d" (index - 1))
      in
      helpers (index - 1)
        (Printf.sprintf "(let nonrec (pvar %s) (lam ((pvar next)) %s) %s)" name helper_body body)
  in
  (* Every helper after gate-0 transfers into its predecessor in both exclusive arms. Rechecking
     bodies per transfer gives T(n)=2T(n-1); memoized contextual summaries visit each helper once. *)
  check_ok (make_cctx ()) "deep duplicate-arm helper transfers reuse affine summaries"
    (once_handler (helpers 24 "(app (var gate-24) (var k))"))

let test_once_resume_double_consumption_spans () =
  test_once_resume_branch_flow_is_bounded ();
  test_once_resume_helper_summaries_are_bounded ();
  let d =
    err_of (make_cctx ())
      (once_handler "(let nonrec (pwild) (app (var k) (lit 1)) (app (var k) (lit 2)))")
  in
  Alcotest.(check string) "affine duplication code" "E0816" d.Diag.code;
  Alcotest.(check bool)
    "both consumption spans are named" true
    (contains d.message "first consumption at c.jqd:"
    && contains d.message "second consumption at c.jqd:");
  Alcotest.(check bool) "the second consumption is the primary span" true (Option.is_some d.span);
  let branch_then_later =
    err_of (make_cctx ())
      (once_handler
         "(let nonrec (pwild) (match (var true) (clause (pcon true) (app (var k) (lit 1))) (clause \
          (pcon false) (lit 0))) (app (var k) (lit 2)))")
  in
  Alcotest.(check string)
    "a prior branch and a later call overlap on one possible path" "E0816" branch_then_later.code;
  let bad_gate =
    err_of (make_cctx ())
      (once_handler
         "(let nonrec (pvar gate) (lam ((pvar next)) (let nonrec (pwild) (app (var next) (lit 1)) \
          (app (var next) (lit 2)))) (app (var gate) (var k)))")
  in
  Alcotest.(check string) "the receiving parameter is checked affinely" "E0816" bad_gate.code

let test_once_resume_type_errors_precede_duplication () =
  let unary_gate call =
    once_handler
      (Printf.sprintf "(let nonrec (pvar gate) (lam ((pvar next)) (app (var next) (lit 1))) %s)"
         call)
  in
  let too_few = err_of (make_cctx ()) (unary_gate "(app (var gate))") in
  Alcotest.(check string) "too-few helper arity wins" "E0803" too_few.code;
  let valid_slot_too_many = err_of (make_cctx ()) (unary_gate "(app (var gate) (var k) (lit 0))") in
  Alcotest.(check string)
    "valid Resume slot does not hide too-many helper arity" "E0803" valid_slot_too_many.code;
  let local_out_of_range = err_of (make_cctx ()) (unary_gate "(app (var gate) (lit 0) (var k))") in
  Alcotest.(check string)
    "out-of-range local-helper transfer defers to arity" "E0803" local_out_of_range.code;
  let stored_out_of_range =
    err_of (make_cctx ())
      ("(defeffect linear () (op signal once () (tref int)))\n"
     ^ "(defterm ((binding gate () (lam ((pvar next)) (app (var next) (lit 1))))))\n"
     ^ "(handle (app (var signal)) (ret (pvar x) (var x)) "
     ^ "(opclause signal () k (app (var gate) (lit 0) (var k))))")
  in
  Alcotest.(check string)
    "out-of-range stored-helper transfer defers to arity" "E0803" stored_out_of_range.code;
  let local_recursive_gate call =
    once_handler
      (Printf.sprintf
         "(let rec (pvar gate) (lam ((pvar left) (pvar right)) (app (var gate) (var left) (var \
          right))) %s)"
         call)
  in
  let stored_recursive_gate call =
    "(defeffect linear () (op signal once () (tref int)))\n"
    ^ "(defterm ((binding gate ((tarrow ((tref int) (tref int)) (row) (tref int))) "
    ^ "(lam ((pvar left) (pvar right)) (app (var gate) (var left) (var right))))))\n"
    ^ "(handle (app (var signal)) (ret (pvar x) (var x)) "
    ^ Printf.sprintf "(opclause signal () k %s))" call
  in
  let local_recursive_too_few =
    err_of (make_cctx ()) (local_recursive_gate "(app (var gate) (lit 0))")
  in
  Alcotest.(check string)
    "too-few local recursive helper stays arity" "E0803" local_recursive_too_few.code;
  let stored_recursive_too_few =
    err_of (make_cctx ()) (stored_recursive_gate "(app (var gate) (lit 0))")
  in
  Alcotest.(check string)
    "too-few stored recursive helper stays arity" "E0803" stored_recursive_too_few.code;
  let local_recursive_in_range =
    err_of (make_cctx ()) (local_recursive_gate "(app (var gate) (var k) (lit 0))")
  in
  Alcotest.(check string)
    "in-range local recursive transfer stays escape" "E0817" local_recursive_in_range.code;
  let stored_recursive_in_range =
    err_of (make_cctx ()) (stored_recursive_gate "(app (var gate) (var k) (lit 0))")
  in
  Alcotest.(check string)
    "in-range stored recursive transfer stays escape" "E0817" stored_recursive_in_range.code;
  let local_recursive_valid_slot_too_many =
    err_of (make_cctx ()) (local_recursive_gate "(app (var gate) (lit 0) (var k) (lit 0))")
  in
  Alcotest.(check string)
    "valid local recursive slot outranks too-many arity" "E0817"
    local_recursive_valid_slot_too_many.code;
  let stored_recursive_valid_slot_too_many =
    err_of (make_cctx ()) (stored_recursive_gate "(app (var gate) (lit 0) (var k) (lit 0))")
  in
  Alcotest.(check string)
    "valid stored recursive slot outranks too-many arity" "E0817"
    stored_recursive_valid_slot_too_many.code;
  let local_recursive_index_two =
    err_of (make_cctx ()) (local_recursive_gate "(app (var gate) (lit 0) (lit 0) (var k))")
  in
  Alcotest.(check string)
    "out-of-range local recursive binary index two defers to arity" "E0803"
    local_recursive_index_two.code;
  let stored_recursive_index_two =
    err_of (make_cctx ()) (stored_recursive_gate "(app (var gate) (lit 0) (lit 0) (var k))")
  in
  Alcotest.(check string)
    "out-of-range stored recursive binary index two defers to arity" "E0803"
    stored_recursive_index_two.code;
  let arity =
    err_of (make_cctx ()) (once_handler "(let nonrec (pwild) (app (var k)) (app (var k) (lit 1)))")
  in
  Alcotest.(check string) "malformed resume arity wins" "E0803" arity.code;
  let argument =
    err_of (make_cctx ())
      (once_handler "(let nonrec (pwild) (app (var k) (lit \"not-an-int\")) (app (var k) (lit 1)))")
  in
  Alcotest.(check string) "malformed resume argument type wins" "E0801" argument.code;
  let binary_duplication =
    err_of (make_cctx ())
      (once_handler
         "(let nonrec (pvar gate) (lam ((pvar left) (pvar right)) (let nonrec (pwild) (app (var \
          left) (lit 1)) (app (var right) (lit 2)))) (app (var gate) (var k) (var k)))")
  in
  Alcotest.(check string)
    "two valid helper slots still share one affine budget" "E0816" binary_duplication.code;
  let standalone_body =
    match
      Reader.parse_string ~file:"standalone.jqd"
        "(let nonrec (pvar gate) (lam ((pvar next)) (app (var next) (lit 1))) (app (var gate) (lit \
         0) (var k)))"
    with
    | Ok [ form ] -> (
        match Kernel.expr_of_form form with
        | Ok expr -> expr
        | Error ds -> Eval_support.fail_diags "standalone affine fixture validation" ds)
    | Ok _ -> Alcotest.fail "standalone affine fixture must contain one expression"
    | Error ds -> Eval_support.fail_diags "standalone affine fixture parse" ds
  in
  (match Affine_resume.check_clause ~resume:"k" standalone_body with
  | Error [ d ] -> Alcotest.(check string) "standalone safety fallback" "E0817" d.code
  | Error ds -> Alcotest.failf "standalone safety expected one diagnostic, got %d" (List.length ds)
  | Ok () -> Alcotest.fail "standalone affine checking must reject an out-of-range transfer");
  let standalone_recursive_body =
    match
      Reader.parse_string ~file:"standalone-recursive.jqd"
        "(let rec (pvar gate) (lam ((pvar left) (pvar right)) (app (var gate) (var left) (var \
         right))) (app (var gate) (lit 0) (lit 0) (var k)))"
    with
    | Ok [ form ] -> (
        match Kernel.expr_of_form form with
        | Ok expr -> expr
        | Error ds -> Eval_support.fail_diags "standalone recursive affine fixture validation" ds)
    | Ok _ -> Alcotest.fail "standalone recursive affine fixture must contain one expression"
    | Error ds -> Eval_support.fail_diags "standalone recursive affine fixture parse" ds
  in
  match Affine_resume.check_clause ~resume:"k" standalone_recursive_body with
  | Error [ d ] -> Alcotest.(check string) "standalone recursive safety fallback" "E0817" d.code
  | Error ds ->
      Alcotest.failf "standalone recursive safety expected one diagnostic, got %d" (List.length ds)
  | Ok () ->
      Alcotest.fail "standalone affine checking must reject a recursive out-of-range transfer"

let test_once_resume_aliases_share_one_budget () =
  test_once_resume_type_errors_precede_duplication ();
  let d =
    err_of (make_cctx ())
      (once_handler
         "(let nonrec (pvar k2) (var k) (let nonrec (pwild) (app (var k) (lit 1)) (app (var k2) \
          (lit 2))))")
  in
  Alcotest.(check string) "duplicate alias code" "E0816" d.code;
  check_ok (make_cctx ()) "a single moved alias remains affine"
    (once_handler "(let nonrec (pvar k2) (var k) (app (var k2) (lit 1)))")

let check_escape what body expected_fragment =
  let d = err_of (make_cctx ()) (once_handler body) in
  Alcotest.(check string) (what ^ " code") "E0817" d.code;
  Alcotest.(check bool)
    (what ^ " wording") true
    (contains d.message expected_fragment && Option.is_some d.span)

let test_once_resume_escape_goldens () =
  check_escape "lambda capture" "(let nonrec (pvar f) (lam () (app (var k) (lit 1))) (lit 0))"
    "escapes into a closure captured here";
  check_escape "quote inside lambda capture"
    "(let nonrec (pvar f) (lam () (quote (unquote (var k)))) (lit 0))"
    "escapes into a closure captured here";
  check_escape "quote capture" "(let nonrec (pvar q) (quote (unquote (var k))) (lit 0))"
    "escapes into quoted code captured here";
  check_escape "constructor storage" "(let nonrec (pvar saved) (app (var some) (var k)) (lit 0))"
    "cannot be stored in data";
  check_escape "return" "(var k)" "escapes by being returned";
  check_escape "self argument" "(app (var k) (var k))"
    "parameter that is not known to be Resume-typed";
  check_escape "non-callable argument" "(app (lit 0) (var k))"
    "parameter that is not known to be Resume-typed";
  let d =
    err_of (make_cctx ())
      (once_handler "(let nonrec (pvar escaped) (app (var add) (var k) (lit 1)) (lit 0))")
  in
  Alcotest.(check string) "unknown call escape code" "E0817" d.code;
  Alcotest.(check bool)
    "unknown call escape wording" true
    (contains d.message "parameter that is not known to be Resume-typed")

let test_once_resume_stored_helper_escape_uses_author_span () =
  let d =
    err_of (make_cctx ())
      ("(defeffect linear () (op signal once () (tref int)))\n"
     ^ "(defterm ((binding bad-gate () (lam ((pvar next)) (app (var some) (var next))))))\n"
     ^ "(handle (app (var signal)) (ret (pvar x) (var x)) "
     ^ "(opclause signal () k (app (var bad-gate) (var k))))")
  in
  Alcotest.(check string) "stored helper escape code" "E0817" d.code;
  (match d.span with
  | Some span -> Alcotest.(check string) "primary span is the author input" "c.jqd" span.Span.file
  | None -> Alcotest.fail "stored helper escape must retain an author source span");
  Alcotest.(check bool)
    "diagnostic does not expose the transient Store object path" false
    (contains (Diag.to_string d) "/objects/")

let test_once_resume_stored_helper_has_distinct_logical_witnesses () =
  let d =
    err_of (make_cctx ())
      ("(defeffect linear () (op signal once () (tref int)))\n"
     ^ "(defterm ((binding bad-gate () (lam ((pvar next)) (let nonrec (pwild) (app (var next) (lit \
        1)) (app (var next) (lit 2)))))))\n" ^ "(handle (app (var signal)) (ret (pvar x) (var x)) "
     ^ "(opclause signal () k (app (var bad-gate) (var k))))")
  in
  Alcotest.(check string) "stored helper duplication code" "E0816" d.code;
  let rendered = Diag.to_string d in
  Alcotest.(check bool)
    "stored helper witnesses use an honest stable logical source" true
    (contains rendered "<stored:bad-gate@" && not (contains rendered "/objects/"));
  let first_marker = "first consumption at " and second_marker = ", second consumption at " in
  let find_from text needle start =
    let rec go index =
      if index + String.length needle > String.length text then None
      else if String.sub text index (String.length needle) = needle then Some index
      else go (index + 1)
    in
    go start
  in
  match (find_from d.message first_marker 0, find_from d.message second_marker 0) with
  | Some first_start, Some second_start ->
      let first_start = first_start + String.length first_marker in
      let second_start = second_start + String.length second_marker in
      let first =
        String.sub d.message first_start (second_start - String.length second_marker - first_start)
      in
      let second = String.sub d.message second_start (String.length d.message - second_start) in
      Alcotest.(check bool) "stored helper consumption spans are distinct" true (first <> second)
  | _ -> Alcotest.failf "missing two stored-helper witnesses in: %s" d.message

let test_multi_resume_remains_ordinary_function () =
  test_once_resume_stored_helper_escape_uses_author_span ();
  test_once_resume_stored_helper_has_distinct_logical_witnesses ();
  check_ok (make_cctx ()) "legacy Multi clauses remain unrestricted"
    "(handle (app (var get)) (ret (pvar x) (var x)) (opclause get () k (let nonrec (pwild) (app \
     (var k) (lit 1)) (app (var k) (lit 2)))))"

let test_declaration_kind_checks () =
  let h = make_cctx () in
  (match check_src h "(defeffect linear () (op signal once () (tref int)))" with
  | Ok _ -> ()
  | Error ds -> Eval_support.fail_diags "Once operation declaration" ds);
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

let manifest_text (_, ctx) row =
  Check.manifest_errors ctx ~grantable:Prelude.grantable_names ~granted:[] row
  |> List.map Diag.to_string |> String.concat "\n"

let test_manifest_uses_resolved_effect_identity () =
  let handle = make_cctx () in
  let checked =
    check_src handle
      "(defeffect net () (op package.fetch once () (tref text)))\n(app (var package.fetch))"
  in
  let text =
    match checked with
    | Ok { Check.row = Some row; _ } -> manifest_text handle row
    | Ok _ -> Alcotest.fail "custom effect expression had no manifest"
    | Error diagnostics -> Eval_support.fail_diags "custom effect manifest" diagnostics
  in
  Alcotest.(check bool)
    "colliding user effect remains unrated" true
    (contains text "unrated user effect");
  Alcotest.(check bool)
    "unpackaged effect gets an honest qualified fallback" true (contains text "unpackaged:");
  Alcotest.(check bool)
    "colliding user effect includes full hash" true
    (match Store.lookup_kind (fst handle) "net" Resolve.KEffect with
    | Some entry -> contains text (Hash.to_hex entry.hash)
    | None -> false);
  Alcotest.(check bool)
    "colliding user effect gets no official risk" false (contains text "world/high");
  Alcotest.(check bool)
    "colliding user effect gets no built-in grant hint" false
    (contains text "grant it with --allow net");
  Alcotest.(check bool)
    "unknown-effects remediation is explicit" true
    (contains text "unregistered user effects have no built-in --allow grant")

let test_manifest_renders_blessed_risk () =
  let handle = make_cctx () in
  (match check_src handle "(app (var net.get) (lit \"https://example.com\"))" with
  | Ok { Check.row = Some row; _ } ->
      let text = manifest_text handle row in
      Alcotest.(check bool) "blessed tier and risk" true (contains text "net [world/high]");
      Alcotest.(check bool)
        "blessed reviewer meaning" true
        (contains text "reach a network endpoint through the granted handler")
  | Ok _ -> Alcotest.fail "Net expression had no manifest"
  | Error diagnostics -> Eval_support.fail_diags "Net manifest" diagnostics);
  let workspace = make_cctx () in
  match
    check_src workspace "(app (var workspace.read-file) (app (var path-value) (lit \"README.md\")))"
  with
  | Ok { Check.row = Some row; _ } ->
      Alcotest.(check string)
        "Workspace is a handled facade, not a pure or root-grantable effect"
        "error[E0814]: this program requires workspace [world/high] — request mediated workspace \
         reads, writes, or fetches without directly acquiring raw authority, which is not granted \
         (performed via `workspace.read-file`)\n\
        \  hint: handle Workspace in the program (Workspace is a world facade and is not \
         root-grantable)"
        (manifest_text workspace row)
  | Ok _ -> Alcotest.fail "Workspace expression had no manifest"
  | Error diagnostics -> Eval_support.fail_diags "Workspace manifest" diagnostics

let test_show_row_preserves_same_name_identities () =
  let store, ctx = make_cctx () in
  let add operation =
    Eval_support.put_src store (Store.names_view store)
      (Printf.sprintf "(defeffect same-name () (op %s once () (tref text)))" operation)
    |> fun hashes -> List.assoc "same-name" hashes.Canon.named
  in
  let first = add "first-op" in
  let second = add "second-op" in
  let expected =
    [ first; second ] |> List.sort Hash.compare
    |> List.map (fun hash -> Printf.sprintf "same-name [#%s]" (Hash.to_hex hash))
    |> String.concat ", "
  in
  Alcotest.(check string)
    "same ename identities stay distinct" expected
    (Check.show_row ctx (Types.closed_row [ second; first ]));
  Alcotest.(check string)
    "input order cannot perturb tie-breaking" expected
    (Check.show_row ctx (Types.closed_row [ first; second ]))

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
    Alcotest.test_case "once Resume: zero/one and exclusive paths" `Quick
      test_once_resume_zero_or_one_per_path;
    Alcotest.test_case "once Resume: gate-style transfer" `Quick
      test_once_resume_gate_style_transfer;
    Alcotest.test_case "once Resume: double consumption names both spans" `Quick
      test_once_resume_double_consumption_spans;
    Alcotest.test_case "once Resume: aliases share one budget" `Quick
      test_once_resume_aliases_share_one_budget;
    Alcotest.test_case "once Resume: escape goldens" `Quick test_once_resume_escape_goldens;
    Alcotest.test_case "multi Resume stays ordinary" `Quick
      test_multi_resume_remains_ordinary_function;
    Alcotest.test_case "declaration kind checks" `Quick test_declaration_kind_checks;
    Alcotest.test_case "group annotations honored" `Quick test_group_annotations;
    Alcotest.test_case "manifest keys blessing by identity" `Quick
      test_manifest_uses_resolved_effect_identity;
    Alcotest.test_case "manifest renders blessed risk" `Quick test_manifest_renders_blessed_risk;
    Alcotest.test_case "show row preserves same-name identities" `Quick
      test_show_row_preserves_same_name_identities;
  ]
