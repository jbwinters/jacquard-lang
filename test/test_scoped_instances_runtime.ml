(* TS.2 slice 2: the State runtime of scoped effect instances (design
   docs/designs/scoped-effect-instances.md §10 A2). Programs are checked with the production
   registration and then evaluated in the same store; the cases mirror the executable model's
   targeted cases (test/test_scoped_instances_model.ml). *)

open Jacquard

type harness = { store : Store.t; eval : Eval.ctx; check : Check.ctx }

let make () =
  let store, eval = Eval_support.make_prelude_ctx () in
  let check =
    match Check.make_ctx store with Ok ctx -> ctx | Error ds -> Eval_support.fail_diags "check" ds
  in
  (match Prelude.builtin_signatures store with
  | Ok sigs -> Check.register_builtin_signatures check sigs
  | Error ds -> Eval_support.fail_diags "builtin sigs" ds);
  { store; eval; check }

let resolved h src =
  match Reader.parse_one ~file:"s.jqd" src with
  | Error ds -> Eval_support.fail_diags "parse" ds
  | Ok form -> (
      match Kernel.of_form form with
      | Error ds -> Eval_support.fail_diags "validate" ds
      | Ok top -> (
          match Resolve.resolve (Store.names_view h.store) top with
          | Error ds -> Eval_support.fail_diags "resolve" ds
          | Ok top -> top))

(* check, then install a declaration *)
let define h src =
  let top = resolved h src in
  (match Check.check_top h.check top with
  | Ok _ -> ()
  | Error ds -> Eval_support.fail_diags ("check " ^ src) ds);
  match top with
  | Kernel.Decl declaration -> (
      match Store.put_decl h.store declaration with
      | Ok _ -> ()
      | Error ds -> Eval_support.fail_diags "install" ds)
  | Kernel.Expr _ -> Alcotest.fail "define expects a declaration"

(* check, then evaluate an expression *)
let run h src =
  match resolved h src with
  | Kernel.Expr expression -> (
      (match Check.check_top h.check (Kernel.Expr expression) with
      | Ok _ -> ()
      | Error ds -> Eval_support.fail_diags ("check " ^ src) ds);
      match Eval.run_expr h.eval expression with
      | Ok value -> Value.show value
      | Error error -> Alcotest.failf "%s: %s" src (Runtime_err.to_string error))
  | Kernel.Decl _ -> Alcotest.fail "run expects an expression"

(* evaluate an unchecked expression: only unchecked evaluation can misuse a capability (A1.2) *)
let run_unchecked h src =
  match resolved h src with
  | Kernel.Expr expression -> Eval.run_expr h.eval expression
  | Kernel.Decl _ -> Alcotest.fail "run_unchecked expects an expression"

let scoped ?(var = "c") init body =
  Printf.sprintf "(app (var state.scoped) %s (lam ((pvar %s)) %s))" init var body

let seq first second = Printf.sprintf "(let nonrec (pwild) %s %s)" first second
let get c = Printf.sprintf "(app (var state.get-at) (var %s))" c
let put c v = Printf.sprintf "(app (var state.put-at) (var %s) %s)" c v

let test_stores () =
  let h = make () in
  Alcotest.(check string)
    "a body without State operations" "42"
    (run h (scoped "(lit 42)" "(lit 42)"));
  Alcotest.(check string)
    "a scope serves its own store" "5"
    (run h (scoped "(lit 0)" (seq (put "c" "(lit 5)") (get "c"))));
  Alcotest.(check string)
    "two stores of different types" "(1, \"a\")"
    (run h
       (scoped ~var:"n" "(lit 0)"
          (scoped ~var:"t" "(lit \"a\")"
             (seq (put "n" "(lit 1)") (Printf.sprintf "(tuple %s %s)" (get "n") (get "t"))))));
  (* same-typed instances: a put meant for the outer store reaches the outer store (§4) *)
  Alcotest.(check string)
    "same-typed instances keep their own stores" "(11, 20)"
    (run h
       (scoped ~var:"outer" "(lit 10)"
          (scoped ~var:"inner" "(lit 20)"
             (seq (put "outer" "(lit 11)")
                (Printf.sprintf "(tuple %s %s)" (get "outer") (get "inner"))))));
  Alcotest.(check string)
    "independent scopes" "(1, 2)"
    (run h
       (Printf.sprintf "(tuple %s %s)"
          (scoped "(lit 0)" (seq (put "c" "(lit 1)") (get "c")))
          (scoped "(lit 0)" (seq (put "c" "(lit 2)") (get "c")))))

let test_forwarding () =
  let h = make () in
  define h
    "(defterm ((binding bump () (lam ((pvar c)) (app (var state.put-at) (var c) (app (var add) \
     (app (var state.get-at) (var c)) (lit 1)))))))";
  define h
    "(defterm ((binding twice () (lam ((pvar f)) (let nonrec (pwild) (app (var f)) (app (var \
     f)))))))";
  (* the inner scope forwards the outer capability's operations, through higher-order transport *)
  Alcotest.(check string)
    "forwarding through an inner scope" "(3, 0)"
    (run h
       (scoped ~var:"outer" "(lit 1)"
          (scoped ~var:"inner" "(lit 0)"
             (seq "(app (var twice) (lam () (app (var bump) (var outer))))"
                (Printf.sprintf "(tuple %s %s)" (get "outer") (get "inner"))))))

let test_multi_shot () =
  let h = make () in
  define h "(defeffect fork () (op split () (tref bool)))";
  let both body =
    Printf.sprintf
      "(handle %s (ret (pvar x) (var x)) (opclause split () k (app (var add) (app (var k) (var \
       true)) (app (var k) (var false)))))"
      body
  in
  let step c =
    seq "(app (var split))"
      (seq (put c (Printf.sprintf "(app (var add) %s (lit 1))" (get c))) (get c))
  in
  (* a scope inside the resumed region is copied per branch: each branch sees 1 *)
  Alcotest.(check string)
    "a scope inside a multi-shot region" "2"
    (run h (both (scoped "(lit 0)" (step "c"))));
  (* a scope outside it is shared and threaded through the branches in order: 1, then 2 *)
  Alcotest.(check string)
    "a scope around a multi-shot region" "3"
    (run h (scoped "(lit 0)" (both (step "c"))))

let test_ambient_handlers () =
  let h = make () in
  Alcotest.(check string)
    "ambient emit around a scope" "(5, cons(0, cons(5, nil)))"
    (run h
       (Printf.sprintf "(app (var emit.collect) (lam () %s))"
          (scoped "(lit 0)"
             (seq
                (Printf.sprintf "(app (var emit) %s)" (get "c"))
                (seq (put "c" "(lit 5)")
                   (seq (Printf.sprintf "(app (var emit) %s)" (get "c")) (get "c")))))));
  Alcotest.(check string)
    "ambient emit inside a scope" "((), cons(4, nil))"
    (run h
       (scoped "(lit 3)"
          (Printf.sprintf "(app (var emit.collect) (lam () %s))"
             (seq
                (put "c" "(app (var add) (app (var state.get-at) (var c)) (lit 1))")
                (Printf.sprintf "(app (var emit) %s)" (get "c"))))));
  Alcotest.(check string)
    "ambient throw around a scope" "err(7)"
    (run h
       (Printf.sprintf "(app (var throw.to-result) (lam () %s))"
          (scoped "(lit 0)"
             (seq (put "c" "(lit 7)") (Printf.sprintf "(app (var throw) %s)" (get "c"))))))

let test_stale_trap () =
  let h = make () in
  (* unchecked evaluation can return a capability from its scope (E0832 refuses it statically) *)
  let leak = scoped "(lit 0)" "(var c)" in
  (match run_unchecked h leak with
  | Ok value ->
      Alcotest.(check string) "a capability displays opaquely" "<capability>" (Value.show value)
  | Error error -> Alcotest.failf "leak: %s" (Runtime_err.to_string error));
  let stale label src =
    let events = ref 0 in
    match Eval.with_observer h.eval (fun _ -> incr events) (fun () -> run_unchecked h src) with
    | Error (Runtime_err.Stale_capability _) ->
        Alcotest.(check int) (label ^ ": no root observer is notified") 0 !events
    | Ok value -> Alcotest.failf "%s returned %s" label (Value.show value)
    | Error error -> Alcotest.failf "%s: %s" label (Runtime_err.to_string error)
  in
  stale "a stale capability at the root" (Printf.sprintf "(app (var state.get-at) %s)" leak);
  stale "a stale capability forwarded by another scope"
    (scoped ~var:"d" "(lit 1)" (Printf.sprintf "(app (var state.get-at) %s)" leak));
  (* no root handler can be granted for an instance operation *)
  match
    Eval.register_root_handler h.eval Instance_contract.state_get_at (fun _ -> Ok (Value.VInt 0))
  with
  | () -> Alcotest.fail "an instance operation was granted at the root"
  | exception Invalid_argument _ -> ()

let suite =
  [
    Alcotest.test_case "stores, same-typed and independent scopes" `Quick test_stores;
    Alcotest.test_case "forwarding through an inner scope" `Quick test_forwarding;
    Alcotest.test_case "multi-shot resumption inside and around a scope" `Quick test_multi_shot;
    Alcotest.test_case "ambient handlers around a scope" `Quick test_ambient_handlers;
    Alcotest.test_case "the stale-capability trap" `Quick test_stale_trap;
  ]
