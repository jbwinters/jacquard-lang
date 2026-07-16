open Jacquard

(* W2.4: deep handlers and multi-shot resumptions — the plan's riskiest task. The multi-shot
   smoke test is deliberately first: it is the reason the interpreter is CPS. *)

(* Harness plus a placeholder type and the effects these tests use. Op signatures only need
   to RESOLVE (types are erased at runtime); the real prelude signatures land in W2.6. *)
let make () =
  let h = Eval_support.make () in
  ignore
    (Eval_support.put_src h.Eval_support.store h.Eval_support.names "(deftype any () (con any-v))");
  ignore
    (Eval_support.put_src h.Eval_support.store h.Eval_support.names
       "(defeffect choice () (op choose () (tref bool)))");
  ignore
    (Eval_support.put_src h.Eval_support.store h.Eval_support.names
       "(defeffect failure () (op abort () (tref any)))");
  ignore
    (Eval_support.put_src h.Eval_support.store h.Eval_support.names
       "(defeffect state () (op get () (tref any)) (op put ((tref any)) (tref any)))");
  ignore
    (Eval_support.put_src h.Eval_support.store h.Eval_support.names
       "(defeffect ticker () (op tick () (tref any)))");
  ignore
    (Eval_support.put_src h.Eval_support.store h.Eval_support.names
       "(defeffect beeper () (op beep () (tref any)))");
  ignore
    (Eval_support.put_src h.Eval_support.store h.Eval_support.names
       "(defeffect linear () (op signal once () (tref any)))");
  h

(* THE multi-shot smoke test: a Choose op whose handler resumes with true and again with
   false, collecting both branch results — distinct values, both present. Resumptions are
   immutable frame lists, so invoking one twice is just reusing the list. *)
let test_multishot_choose () =
  let h = make () in
  Alcotest.(check string)
    "both branches collected" "(1, 2)"
    (Value.show
       (Eval_support.eval_ok h
          "(handle (match (app (var choose)) (clause (pcon true) (lit 1)) (clause (pcon false) \
           (lit 2))) (ret (pvar x) (var x)) (opclause choose () k (tuple (app (var k) (var true)) \
           (app (var k) (var false)))))"))

(* the same resumption invoked three times still works (immutable capture) *)
let test_multishot_thrice () =
  let h = make () in
  Alcotest.(check string)
    "three resumes" "(2, 4, 6)"
    (Value.show
       (Eval_support.eval_ok h
          "(handle (app (var mul) (lit 2) (app (var choose))) (ret (pvar x) (var x)) (opclause \
           choose () k (tuple (app (var k) (lit 1)) (app (var k) (lit 2)) (app (var k) (lit 3)))))"))

let apply_runtime_resume h resume value = Eval.call h.Eval_support.ctx resume [ Value.VInt value ]

let expect_runtime_int label expected = function
  | Ok (Value.VInt actual) -> Alcotest.(check int) label expected actual
  | Ok value -> Alcotest.failf "%s: expected %d, got %s" label expected (Value.show value)
  | Error error ->
      Alcotest.failf "%s: unexpected runtime defect: %s" label (Runtime_err.to_string error)

let capture_once_resume h =
  let expression = Eval_support.parse_expr h "(app (var add) (app (var tick)) (lit 1))" in
  match Eval.run_state_capturing_once h.Eval_support.ctx (Eval.expr_state expression) with
  | Ok (Eval.OCOp { name = "tick"; resume; _ }) -> resume
  | Ok (Eval.OCOp { name; _ }) -> Alcotest.failf "expected to capture tick, got %s" name
  | Ok (Eval.OCValue value) ->
      Alcotest.failf "expected a captured continuation, got %s" (Value.show value)
  | Error error ->
      Alcotest.failf "capturing once continuation failed: %s" (Runtime_err.to_string error)

(* EL.0 exercises the runtime boundary directly. EL.1 will decide which operation declarations
   construct [VOnceResume]; ordinary handler captures above remain [VResume] and therefore
   multi-shot. *)
let test_once_first_resume_and_drop () =
  let h = make () in
  expect_runtime_int "real captured continuation resumes" 42
    (apply_runtime_resume h (capture_once_resume h) 41);
  let dropped = capture_once_resume h in
  Alcotest.(check string) "dropping is legal" "<resume>" (Value.show dropped)

let test_once_second_resume_traps () =
  let h = make () in
  let resume = capture_once_resume h in
  expect_runtime_int "first resume succeeds" 2 (apply_runtime_resume h resume 1);
  match apply_runtime_resume h resume 2 with
  | Error Runtime_err.Once_resumed_twice ->
      Alcotest.(check string)
        "stable E0906 rendering"
        "error[E0906]: a once continuation may be resumed at most once per captured instance"
        (Runtime_err.to_string Runtime_err.Once_resumed_twice)
  | Error error ->
      Alcotest.failf "expected E0906 once-resumption defect, got %s" (Runtime_err.to_string error)
  | Ok value -> Alcotest.failf "second once resume unexpectedly returned %s" (Value.show value)

let test_once_instances_are_independent () =
  let h = make () in
  let left = capture_once_resume h in
  let right = capture_once_resume h in
  expect_runtime_int "left instance" 11 (apply_runtime_resume h left 10);
  expect_runtime_int "right instance" 21 (apply_runtime_resume h right 20)

let test_once_state_survives_untrusted_callback () =
  let h = make () in
  let resume = capture_once_resume h in
  let callback =
    Value.VBuiltin
      ( "consume-once",
        function
        | [ captured ] -> (
            match Eval.call h.Eval_support.ctx captured [ Value.VInt 40 ] with
            | Ok (Value.VInt 41) -> Ok captured
            | Ok value ->
                Error
                  (Runtime_err.Type_error
                     (Printf.sprintf "callback got unexpected value %s" (Value.show value)))
            | Error error -> Error error)
        | args ->
            Error (Runtime_err.Arity (Printf.sprintf "expected 1 arg, got %d" (List.length args)))
      )
  in
  let returned =
    match Eval.call h.Eval_support.ctx callback [ resume ] with
    | Ok value -> value
    | Error error ->
        Alcotest.failf "hostile callback failed early: %s" (Runtime_err.to_string error)
  in
  match Eval.call h.Eval_support.ctx returned [ Value.VInt 41 ] with
  | Error Runtime_err.Once_resumed_twice -> ()
  | Error error ->
      Alcotest.failf "expected callback-consumed E0906, got %s" (Runtime_err.to_string error)
  | Ok value -> Alcotest.failf "callback reset once state and returned %s" (Value.show value)

let test_once_validated_state_cannot_reset_consumption () =
  let h = make () in
  let resume = capture_once_resume h in
  let argument = Kernel.{ it = Lit (LInt 40); meta = Meta.empty } in
  let initial_state =
    Eval.SApply (resume, [ Value.FAppFn { args = [ argument ]; scope = Value.empty_scope } ])
  in
  let validated =
    match Eval.validate_state_once h.Eval_support.ctx initial_state with
    | Ok state -> state
    | Error error -> Alcotest.failf "once state validation failed: %s" (Runtime_err.to_string error)
  in
  (match
     Eval.run_validated_state_capturing h.Eval_support.ctx
       (Eval.fresh_validated_state h.Eval_support.ctx validated)
   with
  | Ok (Eval.VCValue (Value.VInt 41)) -> ()
  | Ok (Eval.VCValue value) -> Alcotest.failf "first validated run returned %s" (Value.show value)
  | Ok (Eval.VCOp _) -> Alcotest.fail "first validated run unexpectedly captured an operation"
  | Error error -> Alcotest.failf "first validated run failed: %s" (Runtime_err.to_string error));
  match
    Eval.run_validated_state_capturing h.Eval_support.ctx
      (Eval.fresh_validated_state h.Eval_support.ctx validated)
  with
  | Error Runtime_err.Once_resumed_twice -> ()
  | Error error ->
      Alcotest.failf "expected validated-state E0906, got %s" (Runtime_err.to_string error)
  | Ok (Eval.VCValue value) ->
      Alcotest.failf "validated-state reuse reset consumption and returned %s" (Value.show value)
  | Ok (Eval.VCOp _) -> Alcotest.fail "validated-state reuse unexpectedly captured an operation"

let test_runtime_multishot_instance_unchanged () =
  let h = make () in
  let resume = Value.VResume [] in
  expect_runtime_int "first multi resume" 10 (apply_runtime_resume h resume 10);
  expect_runtime_int "second multi resume" 20 (apply_runtime_resume h resume 20)

let test_declared_once_handler_traps () =
  let h = make () in
  match
    Eval_support.eval_err h
      "(handle (app (var signal)) (ret (pvar x) (var x)) (opclause signal () k (let nonrec (pwild) \
       (app (var k) (lit 1)) (app (var k) (lit 2)))))"
  with
  | Runtime_err.Once_resumed_twice -> ()
  | error -> Alcotest.failf "declared Once must select E0906, got %s" (Runtime_err.to_string error)

let declared_once_root_kont h =
  let expression = Eval_support.parse_expr h "(app (var add) (app (var signal)) (lit 1))" in
  match Eval.run_state_capturing h.Eval_support.ctx (Eval.expr_state expression) with
  | Ok (Eval.COp { name = "signal"; kont; _ }) -> kont
  | Ok (Eval.COp { name; _ }) -> Alcotest.failf "expected root signal capture, got %s" name
  | Ok (Eval.CValue value) ->
      Alcotest.failf "expected declared Once root capture, got %s" (Value.show value)
  | Error error ->
      Alcotest.failf "declared Once root capture failed: %s" (Runtime_err.to_string error)

let test_declared_once_root_capture_is_sealed () =
  let h = make () in
  let kont = declared_once_root_kont h in
  let resume value =
    Result.bind (Eval.resume_captured_state h.Eval_support.ctx kont (Value.VInt value))
      (fun state -> Eval.run_state_capturing h.Eval_support.ctx state)
  in
  (match resume 40 with
  | Ok (Eval.CValue (Value.VInt 41)) -> ()
  | Ok (Eval.CValue value) -> Alcotest.failf "first root resume returned %s" (Value.show value)
  | Ok (Eval.COp _) -> Alcotest.fail "first root resume unexpectedly captured another operation"
  | Error error -> Alcotest.failf "first root resume failed: %s" (Runtime_err.to_string error));
  match resume 50 with
  | Error Runtime_err.Once_resumed_twice -> ()
  | Error error -> Alcotest.failf "expected sealed root E0906, got %s" (Runtime_err.to_string error)
  | Ok (Eval.CValue value) ->
      Alcotest.failf "ordinary root API duplicated Once frames and returned %s" (Value.show value)
  | Ok (Eval.COp _) -> Alcotest.fail "ordinary root API duplicated Once into another capture"

let test_declared_once_validated_capture_is_sealed () =
  let h = make () in
  let expression = Eval_support.parse_expr h "(app (var add) (app (var signal)) (lit 1))" in
  let initial =
    match Eval.validate_state_once h.Eval_support.ctx (Eval.expr_state expression) with
    | Ok state -> state
    | Error error ->
        Alcotest.failf "validating declared Once state failed: %s" (Runtime_err.to_string error)
  in
  let kont =
    match
      Eval.run_validated_state_capturing h.Eval_support.ctx
        (Eval.fresh_validated_state h.Eval_support.ctx initial)
    with
    | Ok (Eval.VCOp { name = "signal"; kont; _ }) -> kont
    | Ok (Eval.VCOp { name; _ }) -> Alcotest.failf "expected validated signal, got %s" name
    | Ok (Eval.VCValue value) ->
        Alcotest.failf "expected validated Once capture, got %s" (Value.show value)
    | Error error ->
        Alcotest.failf "validated Once capture failed: %s" (Runtime_err.to_string error)
  in
  let first = Eval.resume_validated_state h.Eval_support.ctx kont (Value.VInt 40) in
  (match first with
  | Error error -> Alcotest.failf "first validated resume failed: %s" (Runtime_err.to_string error)
  | Ok state -> (
      match Eval.run_validated_state_capturing h.Eval_support.ctx state with
      | Ok (Eval.VCValue (Value.VInt 41)) -> ()
      | Ok (Eval.VCValue value) ->
          Alcotest.failf "first validated resume returned %s" (Value.show value)
      | Ok (Eval.VCOp _) -> Alcotest.fail "first validated resume captured another operation"
      | Error error ->
          Alcotest.failf "first validated resumed run failed: %s" (Runtime_err.to_string error)));
  match Eval.resume_validated_state h.Eval_support.ctx kont (Value.VInt 50) with
  | Error Runtime_err.Once_resumed_twice -> ()
  | Error error ->
      Alcotest.failf "expected sealed validated E0906, got %s" (Runtime_err.to_string error)
  | Ok _ -> Alcotest.fail "validated root API minted a second Once budget"

let test_runtime_resumption_modes () =
  (* Keep the released Alcotest inventory stable while grouping the EL.0 hostile matrix under the
     existing low-level multi-shot regression case. *)
  test_multishot_thrice ();
  test_once_first_resume_and_drop ();
  test_once_second_resume_traps ();
  test_once_instances_are_independent ();
  test_once_state_survives_untrusted_callback ();
  test_once_validated_state_cannot_reset_consumption ();
  test_runtime_multishot_instance_unchanged ();
  test_declared_once_handler_traps ();
  test_declared_once_root_capture_is_sealed ();
  test_declared_once_validated_capture_is_sealed ()

(* The nasty multi-shot/deep interaction in one test:
   - choose's handler resumes the same continuation twice;
   - each resumed branch performs tick after the choice point;
   - the captured continuation must include the handler frame, so tick is caught by the SAME
     deep handler inside each branch;
   - tick returns an incrementing token, making branch values distinct and proving exact count. *)
let test_multishot_deep_inner_effect_exact_count () =
  let h = make () in
  let v =
    Eval_support.eval_ok h
      "(handle (let nonrec (pvar branch) (app (var choose)) (let nonrec (pvar ticked) (app (var \
       tick)) (match (var branch) (clause (pcon true) (app (var add) (lit 100) (var ticked))) \
       (clause (pcon false) (app (var add) (lit 200) (var ticked)))))) (ret (pvar x) (var x)) \
       (opclause choose () k (tuple (app (var k) (var true)) (app (var k) (var false)))) (opclause \
       tick () k (let nonrec (pvar n) (app (var bump)) (app (var k) (var n)))))"
  in
  Alcotest.(check string) "distinct branch values" "(101, 202)" (Value.show v);
  (match v with
  | Value.VTuple [ Value.VInt 101; Value.VInt 202 ] -> ()
  | _ -> Alcotest.failf "expected exactly two branch results, got %s" (Value.show v));
  Alcotest.(check int) "inner effect handled exactly once per branch" 2 !(h.bumps)

(* State effect: get/put handler threads state through a function-of-state encoding; a
   program using both returns the expected pair. *)
let state_handler body =
  Printf.sprintf
    "(app (handle %s (ret (pvar x) (lam ((pvar s)) (tuple (var x) (var s)))) (opclause get () k \
     (lam ((pvar s)) (app (app (var k) (var s)) (var s)))) (opclause put ((pvar ns)) k (lam ((pvar \
     s)) (app (app (var k) (tuple)) (var ns))))) (lit 41))"
    body

let test_state_effect () =
  let h = make () in
  (* put (get + 1); get  — from initial state 41 *)
  Alcotest.(check string)
    "value and final state" "(42, 42)"
    (Value.show
       (Eval_support.eval_ok h
          (state_handler
             "(let nonrec (pwild) (app (var put) (app (var add) (app (var get)) (lit 1))) (app \
              (var get)))")));
  (* pure body never performs: state untouched *)
  Alcotest.(check string)
    "pure body" "(7, 41)"
    (Value.show (Eval_support.eval_ok h (state_handler "(lit 7)")))

(* Abort: a clause that never resumes short-circuits past pending frames. *)
let test_abort_short_circuits () =
  let h = make () in
  Alcotest.(check string)
    "pending add abandoned" "none"
    (Value.show
       (Eval_support.eval_ok h
          "(handle (app (var add) (lit 1) (app (var abort))) (ret (pvar x) (app (var some) (var \
           x))) (opclause abort () k (var none)))"));
  (* the corpus safe-div/to-option pair works end to end *)
  List.iter
    (fun file ->
      let src = Corpus_support.read_file ("../corpus/valid/" ^ file) in
      match Reader.parse_string ~file src with
      | Ok [ f ] ->
          let d = Result.get_ok (Kernel.decl_of_form f) in
          let d = Result.get_ok (Resolve.resolve_decl h.Eval_support.names d) in
          ignore (Result.get_ok (Store.put_decl h.Eval_support.store d))
      | _ -> Alcotest.failf "%s should hold one decl" file)
    [ "safe-div.jqd"; "to-option.jqd" ];
  Alcotest.(check string)
    "safe-div 10 2" "some(5)"
    (Value.show
       (Eval_support.eval_ok h
          "(app (var to-option) (lam () (app (var safe-div) (lit 10) (lit 2))))"));
  Alcotest.(check string)
    "safe-div 1 0" "none"
    (Value.show
       (Eval_support.eval_ok h "(app (var to-option) (lam () (app (var safe-div) (lit 1) (lit 0))))"))

(* Deep semantics: a second perform inside the resumption is handled by the same handler. *)
let test_deep_second_perform () =
  let h = make () in
  ignore
    (Eval_support.eval_ok h
       "(handle (let nonrec (pwild) (app (var tick)) (app (var tick))) (ret (pvar x) (var x)) \
        (opclause tick () k (let nonrec (pwild) (app (var note) (lit 7)) (app (var k) (tuple)))))");
  Alcotest.(check int) "handler ran for both performs" 2 (List.length (Eval_support.recorded h))

(* Forwarding: inner handler for one effect, an op of another effect performed inside, the
   outer handler catches it. *)
let test_forwarding () =
  let h = make () in
  Alcotest.(check string)
    "outer handler catches forwarded op" "9"
    (Value.show
       (Eval_support.eval_ok h
          "(handle (handle (app (var beep)) (ret (pvar x) (var x)) (opclause tick () k (lit 0))) \
           (ret (pvar y) (var y)) (opclause beep () k (app (var k) (lit 9))))"))

(* nearest enclosing handler wins for the same effect *)
let test_nearest_handler_wins () =
  let h = make () in
  Alcotest.(check string)
    "inner shadows outer" "1"
    (Value.show
       (Eval_support.eval_ok h
          "(handle (handle (app (var tick)) (ret (pvar x) (var x)) (opclause tick () k (lit 1))) \
           (ret (pvar y) (var y)) (opclause tick () k (lit 2)))"))

(* Return clause transforms the body value. *)
let test_return_clause_transforms () =
  let h = make () in
  Alcotest.(check string)
    "wrap in some" "some(5)"
    (Value.show
       (Eval_support.eval_ok h
          "(handle (lit 5) (ret (pvar x) (app (var some) (var x))) (opclause abort () k (var \
           none)))"))

(* deep: the return clause runs per resumption, so each collected branch went through ret *)
let test_return_clause_runs_per_resumption () =
  let h = make () in
  Alcotest.(check string)
    "ret doubles each branch" "(2, 4)"
    (Value.show
       (Eval_support.eval_ok h
          "(handle (match (app (var choose)) (clause (pcon true) (lit 1)) (clause (pcon false) \
           (lit 2))) (ret (pvar x) (app (var mul) (lit 2) (var x))) (opclause choose () k (tuple \
           (app (var k) (var true)) (app (var k) (var false)))))"))

(* Unhandled op at root: the error names the effect and the op. *)
let test_unhandled_names_effect_and_op () =
  let h = make () in
  match Eval_support.eval_err h "(app (var abort))" with
  | Runtime_err.Unhandled { effect_; op } ->
      Alcotest.(check string) "effect" "failure" effect_;
      Alcotest.(check string) "op" "abort" op
  | e -> Alcotest.failf "expected Unhandled, got %s" (Runtime_err.to_string e)

(* a handler for a different effect does not swallow the miss *)
let test_unhandled_past_other_handler () =
  let h = make () in
  match
    Eval_support.eval_err h
      "(handle (app (var abort)) (ret (pvar x) (var x)) (opclause tick () k (lit 0)))"
  with
  | Runtime_err.Unhandled { effect_; op } ->
      Alcotest.(check string) "effect" "failure" effect_;
      Alcotest.(check string) "op" "abort" op
  | e -> Alcotest.failf "expected Unhandled, got %s" (Runtime_err.to_string e)

(* Same-effect perform inside a handler's own op-clause body goes OUTWARD (the clause body
   runs under the outer continuation), the subtle half of deep semantics. *)
let test_clause_body_perform_escapes_outward () =
  let h = make () in
  Alcotest.(check string)
    "outer handler catches the clause body's perform" "99"
    (Value.show
       (Eval_support.eval_ok h
          "(handle (handle (app (var tick)) (ret (pvar x) (var x)) (opclause tick () k (app (var \
           tick)))) (ret (pvar y) (var y)) (opclause tick () k (lit 99)))"));
  match
    Eval_support.eval_err h
      "(handle (app (var tick)) (ret (pvar x) (var x)) (opclause tick () k (app (var tick))))"
  with
  | Runtime_err.Unhandled { op = "tick"; _ } -> ()
  | e -> Alcotest.failf "expected Unhandled tick, got %s" (Runtime_err.to_string e)

(* Top-level term bodies evaluate in ISOLATION (review finding): their effects cannot be
   captured by handlers around the referencing expression, so no handled-branch value can be
   memoized and leak past its handler's dynamic extent. *)
let test_toplevel_body_effects_isolated () =
  let h = make () in
  ignore
    (Eval_support.put_src h.Eval_support.store h.Eval_support.names
       "(defterm ((binding thing () (app (var tick)))))");
  (* a handler around the REFERENCE must not catch the body's effect *)
  (match
     Eval_support.eval_err h
       "(handle (var thing) (ret (pvar x) (var x)) (opclause tick () k (app (var k) (lit 5))))"
   with
  | Runtime_err.Unhandled { effect_ = "ticker"; op = "tick" } -> ()
  | e -> Alcotest.failf "expected Unhandled ticker.tick, got %s" (Runtime_err.to_string e));
  (* and nothing branch-dependent was memoized: a later bare reference still dies *)
  (match Eval_support.eval_err h "(var thing)" with
  | Runtime_err.Unhandled _ -> ()
  | e -> Alcotest.failf "expected Unhandled, got %s" (Runtime_err.to_string e));
  (* a body that handles its own effects is a value and memoizes fine *)
  ignore
    (Eval_support.put_src h.Eval_support.store h.Eval_support.names
       "(defterm ((binding selfh () (handle (app (var tick)) (ret (pvar x) (var x)) (opclause tick \
        () k (app (var k) (lit 7)))))))");
  Alcotest.(check string)
    "self-handled body evaluates" "(7, 7)"
    (Value.show (Eval_support.eval_ok h "(tuple (var selfh) (var selfh))"))

(* ops are first-class values: pass one to a function that performs it *)
let test_op_as_value () =
  let h = make () in
  Alcotest.(check string)
    "op passed and performed" "3"
    (Value.show
       (Eval_support.eval_ok h
          "(handle (app (lam ((pvar do-it)) (app (var do-it))) (var tick)) (ret (pvar x) (var x)) \
           (opclause tick () k (app (var k) (lit 3))))"))

let suite =
  [
    Alcotest.test_case "MULTI-SHOT smoke test (Choose)" `Quick test_multishot_choose;
    Alcotest.test_case "runtime resumption modes (multi + once hostile matrix)" `Quick
      test_runtime_resumption_modes;
    Alcotest.test_case "multi-shot resumes catch inner effects exactly" `Quick
      test_multishot_deep_inner_effect_exact_count;
    Alcotest.test_case "state effect threads state" `Quick test_state_effect;
    Alcotest.test_case "abort short-circuits" `Quick test_abort_short_circuits;
    Alcotest.test_case "deep: second perform same handler" `Quick test_deep_second_perform;
    Alcotest.test_case "forwarding to outer handler" `Quick test_forwarding;
    Alcotest.test_case "nearest handler wins" `Quick test_nearest_handler_wins;
    Alcotest.test_case "return clause transforms" `Quick test_return_clause_transforms;
    Alcotest.test_case "return clause runs per resumption" `Quick
      test_return_clause_runs_per_resumption;
    Alcotest.test_case "unhandled names effect and op" `Quick test_unhandled_names_effect_and_op;
    Alcotest.test_case "unhandled past other handler" `Quick test_unhandled_past_other_handler;
    Alcotest.test_case "clause body perform escapes outward" `Quick
      test_clause_body_perform_escapes_outward;
    Alcotest.test_case "top-level body effects isolated" `Quick test_toplevel_body_effects_isolated;
    Alcotest.test_case "op as first-class value" `Quick test_op_as_value;
  ]
