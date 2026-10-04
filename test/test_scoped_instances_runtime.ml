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
    "ambient throw inside a scope" "err(4)"
    (run h
       (scoped "(lit 3)"
          (Printf.sprintf "(app (var throw.to-result) (lam () %s))"
             (seq (put "c" "(lit 4)") (Printf.sprintf "(app (var throw) %s)" (get "c"))))));
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
  stale "a non-token capability, forwarded by a scope"
    (scoped ~var:"d" "(lit 1)" "(app (var state.get-at) (lit 5))");
  (* both capture modes: the trap fires before capture, ordinary or routed *)
  let routed label src =
    let events = ref 0 in
    match
      Eval.with_observer h.eval
        (fun _ -> incr events)
        (fun () ->
          match resolved h src with
          | Kernel.Expr expression ->
              Eval.run_state_capturing_once_routed h.eval (Eval.expr_state expression)
          | Kernel.Decl _ -> Alcotest.fail "expected an expression")
    with
    | Error (Runtime_err.Stale_capability _) ->
        Alcotest.(check int) (label ^ ": no root observer is notified") 0 !events
    | Ok _ -> Alcotest.failf "%s was captured" label
    | Error error -> Alcotest.failf "%s: %s" label (Runtime_err.to_string error)
  in
  routed "a stale capability under routed capture"
    (Printf.sprintf "(app (var state.put-at) %s (lit 1))" leak);
  (* routed dispatch refuses an instance operation *)
  (match
     Eval.dispatch_root_operation ~call:0 h.eval ~resume:(Value.VTuple [])
       ~op:Instance_contract.state_get_at ~name:"state.get-at" ~effect_:"state-instance" []
   with
  | Error (Runtime_err.Stale_capability _) -> ()
  | Ok _ -> Alcotest.fail "routed dispatch served an instance operation"
  | Error error -> Alcotest.failf "routed dispatch: %s" (Runtime_err.to_string error));
  stale "a stale capability forwarded by another scope"
    (scoped ~var:"d" "(lit 1)" (Printf.sprintf "(app (var state.get-at) %s)" leak));
  (* no root handler can be granted for an instance operation *)
  match
    Eval.register_root_handler h.eval Instance_contract.state_get_at (fun _ -> Ok (Value.VInt 0))
  with
  | () -> Alcotest.fail "an instance operation was granted at the root"
  | exception Invalid_argument _ -> ()

(* a checked program can smuggle a capability out of its scope only through unchecked eval
   (A1.2); the trap catches its later use (A2.4) *)
let test_eval_smuggling () =
  let h = make () in
  (match Prelude.install_eval h.eval with
  | Ok () -> ()
  | Error ds -> Eval_support.fail_diags "install_eval" ds);
  let smuggled =
    scoped "(lit 0)" "(app (app (var eval-code) (quote (lam ((pvar x)) (var x)))) (var c))"
  in
  (* the choice unifies the smuggled value with the live scope's capability *)
  let program =
    scoped ~var:"d" "(lit 1)"
      (Printf.sprintf
         "(app (var state.get-at) (match (var false) (clause (pcon true) (var d)) (clause (pcon \
          false) %s)))"
         smuggled)
  in
  (match Check.check_top h.check (resolved h program) with
  | Ok _ -> ()
  | Error ds -> Eval_support.fail_diags "the smuggling program checks" ds);
  match resolved h program with
  | Kernel.Expr expression -> (
      match Eval.run_expr h.eval expression with
      | Error (Runtime_err.Stale_capability _) -> ()
      | Ok value -> Alcotest.failf "the smuggled capability returned %s" (Value.show value)
      | Error error -> Alcotest.failf "smuggling: %s" (Runtime_err.to_string error))
  | Kernel.Decl _ -> Alcotest.fail "expected an expression"

let throw_scoped ?(var = "c") body =
  Printf.sprintf "(app (var throw.scoped) (lam ((pvar %s)) %s))" var body

let emit_scoped ?(var = "c") body =
  Printf.sprintf "(app (var emit.scoped) (lam ((pvar %s)) %s))" var body

let throw_at c v = Printf.sprintf "(app (var throw.throw-at) (var %s) %s)" c v
let emit_at c v = Printf.sprintf "(app (var emit.emit-at) (var %s) %s)" c v

let test_throw_emit () =
  let h = make () in
  Alcotest.(check string) "a Throw scope that returns" "ok(1)" (run h (throw_scoped "(lit 1)"));
  Alcotest.(check string)
    "a Throw scope that throws" "err(7)"
    (run h (throw_scoped (throw_at "c" "(lit 7)")));
  (* a nested Throw on the outer capability skips every intervening computation (A3.7) *)
  Alcotest.(check string)
    "nested Throw forwards to its own scope" "err(\"outer\")"
    (run h
       (throw_scoped ~var:"o"
          (scoped ~var:"s" "(lit 0)"
             (throw_scoped ~var:"i" (seq (throw_at "o" "(lit \"outer\")") (put "s" "(lit 1)"))))));
  Alcotest.(check string)
    "two Throw scopes of different types" "ok(err(\"text\"))"
    (run h
       (throw_scoped ~var:"n"
          (throw_scoped ~var:"t"
             (seq
                "(match (var false) (clause (pcon true) (app (var throw.throw-at) (var n) (lit \
                 1))) (clause (pcon false) (tuple)))"
                (throw_at "t" "(lit \"text\")")))));
  (* ambient handlers and instance scopes do not intercept each other *)
  Alcotest.(check string)
    "an ambient handler does not catch an instance throw" "err(7)"
    (run h
       (throw_scoped
          (Printf.sprintf "(app (var throw.to-result) (lam () %s))" (throw_at "c" "(lit 7)"))));
  Alcotest.(check string)
    "throw.catch does not catch an instance throw" "err(8)"
    (run h
       (throw_scoped
          (Printf.sprintf "(app (var throw.catch) (lam () %s) (lam ((pvar e)) (lit 0)))"
             (throw_at "c" "(lit 8)"))));
  Alcotest.(check string)
    "an instance scope does not catch an ambient throw (throw.catch)" "9"
    (run h
       (Printf.sprintf
          "(app (var throw.catch) (lam () (match %s (clause (pwild) (lit 0)))) (lam ((pvar e)) \
           (var e)))"
          (throw_scoped "(app (var throw) (lit 9))")));
  Alcotest.(check string)
    "an instance scope does not catch an ambient throw" "err(5)"
    (run h
       (Printf.sprintf "(app (var throw.to-result) (lam () %s))"
          (throw_scoped "(app (var throw) (lit 5))")));
  (* Emit keeps chronological order and forwards between nested scopes *)
  Alcotest.(check string)
    "nested Emit scopes" "(((), cons(2, nil)), cons(1, cons(3, nil)))"
    (run h
       (emit_scoped ~var:"o"
          (emit_scoped ~var:"i"
             (seq (emit_at "o" "(lit 1)") (seq (emit_at "i" "(lit 2)") (emit_at "o" "(lit 3)"))))));
  (* Throw inside State keeps the store; State inside Emit emits what it reads *)
  Alcotest.(check string)
    "Throw inside State" "(err(\"e\"), 5)"
    (run h
       (scoped ~var:"s" "(lit 0)"
          (Printf.sprintf "(tuple %s %s)"
             (throw_scoped ~var:"t" (seq (put "s" "(lit 5)") (throw_at "t" "(lit \"e\")")))
             (get "s"))));
  Alcotest.(check string)
    "State inside Emit" "((), cons(2, nil))"
    (run h
       (emit_scoped ~var:"e"
          (scoped ~var:"s" "(lit 1)" (seq (put "s" "(lit 2)") (emit_at "e" (get "s"))))));
  (* a multi-shot handler around an Emit scope: each branch keeps its own list, with no E0906 *)
  define h "(defeffect fork2 () (op choose () (tref bool)))";
  Alcotest.(check string)
    "multi-shot around an Emit scope" "((1, cons(0, cons(1, nil))), (2, cons(0, cons(2, nil))))"
    (run h
       (Printf.sprintf
          "(handle %s (ret (pvar x) (tuple (var x) (var x))) (opclause choose () k (tuple (match \
           (app (var k) (var true)) (clause (ptuple (pvar a) (pwild)) (var a))) (match (app (var \
           k) (var false)) (clause (ptuple (pvar b) (pwild)) (var b))))))"
          (emit_scoped ~var:"e"
             (seq (emit_at "e" "(lit 0)")
                (Printf.sprintf
                   "(match (app (var choose)) (clause (pcon true) %s) (clause (pcon false) %s))"
                   (seq (emit_at "e" "(lit 1)") "(lit 1)")
                   (seq (emit_at "e" "(lit 2)") "(lit 2)"))))));
  (* the stale trap covers both operations (A2.4) *)
  let stale label src =
    match run_unchecked h src with
    | Error (Runtime_err.Stale_capability _) -> ()
    | Ok value -> Alcotest.failf "%s returned %s" label (Value.show value)
    | Error error -> Alcotest.failf "%s: %s" label (Runtime_err.to_string error)
  in
  stale "a stale Throw capability"
    (Printf.sprintf "(match %s (clause (pcon ok (pvar d)) %s) (clause (pwild) (lit 0)))"
       (throw_scoped "(var c)") (throw_at "d" "(lit 1)"));
  stale "a stale Emit capability"
    (Printf.sprintf "(match %s (clause (ptuple (pvar d) (pwild)) %s))" (emit_scoped "(var c)")
       (emit_at "d" "(lit 1)"))

(* host protocol v0 stays fixed and first-order (TS.2): a capability value and a capability-typed
   target are both refused at the boundary (E1604) *)
let test_host_boundary () =
  let h = make () in
  let budget () = Host_protocol_v0.create_boundary_budget Host_protocol_v0.hard_limits in
  let code = function
    | Error (diagnostic :: _) -> Diag.code_or_uncoded diagnostic
    | Error [] -> "no diagnostic"
    | Ok _ -> "accepted"
  in
  (match run_unchecked h (scoped "(lit 0)" "(var c)") with
  | Ok capability ->
      Alcotest.(check string)
        "a capability value cannot cross v0" "E1604"
        (code (Host_protocol_v0.encode_boundary_value ~budget:(budget ()) capability))
  | Error error -> Alcotest.failf "leak: %s" (Runtime_err.to_string error));
  define h
    "(defterm ((binding cap.read ((tarrow ((tapp (tref state-ref) (tref int))) (row (eref \
     state-instance)) (tref int))) (lam ((pvar c)) (app (var state.get-at) (var c))))))";
  let target =
    match Store.lookup_kind h.store "cap.read" Resolve.KTerm with
    | Some { Resolve.hash; _ } -> hash
    | None -> Alcotest.fail "cap.read was not installed"
  in
  let int_type =
    match Store.lookup_kind h.store "int" Resolve.KType with
    | Some { Resolve.hash; _ } -> Types.TCon (hash, [])
    | None -> Alcotest.fail "int is missing"
  in
  let encode_type ty =
    match Host_protocol_v0.encode_boundary_type ~budget:(budget ()) ty with
    | Ok json -> json
    | Error _ -> Alcotest.fail "int does not encode"
  in
  let invoke =
    `Assoc
      [
        ("arguments", `List []);
        ("capabilities", `Assoc [ ("effects", `List []); ("operations", `List []) ]);
        ( "interface",
          `Assoc
            [
              ("effects", `List []);
              ("parameters", `List [ encode_type int_type ]);
              ("result", encode_type int_type);
            ] );
        ("invocation_id", `String "0000000000000000");
        ("kind", `String "invoke");
        ("protocol", `String Host_protocol_v0.protocol);
        ( "target",
          `Assoc [ ("callable", `String (Hash.to_hex target)); ("kind", `String "store-term-v0") ]
        );
      ]
  in
  (* a capability parameter's label is quantified, so the target is refused as a polymorphic term
     (E1603) before its boundary types are walked; either way it never crosses v0 *)
  Alcotest.(check string)
    "a capability-typed target is refused at preflight" "E1603"
    (code
       (Host_protocol_v0.parse_invoke ~limits:Host_protocol_v0.hard_limits ~checker:h.check invoke))

let suite =
  [
    Alcotest.test_case "stores, same-typed and independent scopes" `Quick test_stores;
    Alcotest.test_case "forwarding through an inner scope" `Quick test_forwarding;
    Alcotest.test_case "multi-shot resumption inside and around a scope" `Quick test_multi_shot;
    Alcotest.test_case "ambient handlers around a scope" `Quick test_ambient_handlers;
    Alcotest.test_case "the stale-capability trap" `Quick test_stale_trap;
    Alcotest.test_case "a capability smuggled through eval is trapped" `Quick test_eval_smuggling;
    Alcotest.test_case "Throw and Emit scopes" `Quick test_throw_emit;
    Alcotest.test_case "host v0 refuses capabilities" `Quick test_host_boundary;
  ]
