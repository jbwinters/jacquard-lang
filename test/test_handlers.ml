open Weft

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
    [ "safe-div.wft"; "to-option.wft" ];
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
    Alcotest.test_case "multi-shot thrice" `Quick test_multishot_thrice;
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
