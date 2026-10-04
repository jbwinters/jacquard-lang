(* TS.2: the checker side of scoped effect instances (design
   docs/designs/scoped-effect-instances.md §9, §10 A2), on the production State declarations that
   every [Check.make_ctx] context registers. *)

open Jacquard

let fresh () = Test_check.make_cctx ()

let test_registration () =
  let store, ctx = fresh () in
  Alcotest.(check int)
    "a production context registers State, Throw and Emit" 3
    (List.length (Check.instance_registrations ctx));
  Alcotest.(check int)
    "an unregistered control registers nothing" 0
    (List.length (Check.instance_registrations (snd (Test_check.make_cctx ~instances:false ()))));
  (* registrations are validated against the store *)
  let valid = Instances_fixture.registration store in
  (* each case runs on a fresh unregistered context, where the valid registration is accepted, so
     each refusal is due to the defect it names rather than to a duplicate *)
  let fresh_unregistered () = snd (Test_check.make_cctx ~instances:false ()) in
  Check.register_instances (fresh_unregistered ()) [ valid ];
  let refused label registration =
    match Check.register_instances (fresh_unregistered ()) [ registration ] with
    | () -> Alcotest.failf "%s was accepted" label
    | exception Invalid_argument _ -> ()
  in
  refused "an effect that is a type" { valid with instance_effect = valid.capability };
  refused "an operation of another effect"
    { valid with operations = [ Instances_fixture.hash store Resolve.KOp "print" ] };
  refused "no operations" { valid with operations = [] };
  refused "a capability that is an effect" { valid with capability = valid.instance_effect };
  refused "a scoped combinator that is a type" { valid with scoped = valid.capability };
  refused "a negative callback position" { valid with callback_position = -1 };
  refused "a callback position other than slice 1's" { valid with callback_position = 0 };
  (match Check.register_instances ctx [ valid ] with
  | () -> Alcotest.fail "a repeated registration was accepted"
  | exception Invalid_argument _ -> ());
  (* a refused batch registers nothing, even its valid members *)
  let _, unregistered = Test_check.make_cctx ~instances:false () in
  (match Check.register_instances unregistered [ valid; valid ] with
  | () -> Alcotest.fail "a batch repeating a registration was accepted"
  | exception Invalid_argument _ -> ());
  Alcotest.(check int)
    "a refused batch registers nothing" 0
    (List.length (Check.instance_registrations unregistered));
  Alcotest.(check int)
    "refused registrations add nothing" 3
    (List.length (Check.instance_registrations ctx))

let fixture () = fresh ()

let scheme_of h src =
  match Test_check.check_src h src with
  | Ok { Check.names = [ (_, scheme) ]; _ } -> scheme
  | Ok _ -> Alcotest.failf "expected one binding: %s" src
  | Error diagnostics ->
      Alcotest.failf "%s: %s" src (String.concat "\n" (List.map Diag.to_string diagnostics))

let code_of h src =
  match Test_check.check_src h src with
  | Ok _ -> Alcotest.failf "expected a refusal: %s" src
  | Error diagnostics -> String.concat "," (List.map Diag.code_or_uncoded diagnostics)

let test_operation_schemes () =
  let ((store, _) as h) = fixture () in
  let registration = Instances_fixture.registration store in
  (* an instance operation types through its capability: the row is one entry carrying the
     capability's label and payload *)
  let read =
    scheme_of h "(defterm ((binding read () (lam ((pvar c)) (app (var state.get-at) (var c))))))"
  in
  (match Types.repr (Types.instantiate ~level:1 read) with
  | Types.TArrow ([ parameter ], row, result) -> (
      match (Types.repr parameter, (Types.repr_row row).instances) with
      | Types.TCon (capability, [ label; payload ]), [ entry ] ->
          Alcotest.(check bool)
            "the parameter is the capability" true
            (Hash.equal capability registration.capability);
          Alcotest.(check bool)
            "the entry is the instance effect" true
            (Hash.equal entry.effect_id registration.instance_effect);
          Alcotest.(check bool)
            "with the capability's label" true
            (Types.same_label label entry.label);
          Alcotest.(check bool)
            "and its payload, which is the result" true
            (match entry.payload with
            | [ entry_payload ] ->
                Types.repr entry_payload == Types.repr payload
                && Types.repr result == Types.repr payload
            | _ -> false);
          Alcotest.(check (list string))
            "no ambient effect" []
            (List.map Hash.to_hex (Types.repr_row row).effects)
      | _ -> Alcotest.fail "unexpected capability shape")
  | _ -> Alcotest.fail "unexpected operation shape");
  (* a let-bound alias keeps the label per use: two capabilities give two entries *)
  let two =
    scheme_of h
      "(defterm ((binding two () (lam ((pvar c) (pvar d)) (let nonrec (pvar r) (var state.get-at) \
       (let nonrec (pwild) (app (var r) (var c)) (app (var r) (var d))))))))"
  in
  (match Types.repr (Types.instantiate ~level:1 two) with
  | Types.TArrow (_, row, _) ->
      Alcotest.(check int)
        "an alias used on two capabilities records two instances" 2
        (List.length (Types.repr_row row).instances)
  | _ -> Alcotest.fail "unexpected shape");
  (* the same capability twice is one entry *)
  let same =
    scheme_of h
      "(defterm ((binding same () (lam ((pvar c)) (let nonrec (pwild) (app (var state.get-at) (var \
       c)) (app (var state.put-at) (var c) (app (var state.get-at) (var c))))))))"
  in
  match Types.repr (Types.instantiate ~level:1 same) with
  | Types.TArrow (_, row, _) ->
      Alcotest.(check int)
        "one capability, one entry" 1
        (List.length (Types.repr_row row).instances)
  | _ -> Alcotest.fail "unexpected shape"

let test_opacity_storage_and_handlers () =
  let h = fixture () in
  (* the private carrier's name is hidden after the prelude loads (design §10 A2.1), so source
     cannot even name it; the checker's E0835 guards the hash itself *)
  Alcotest.(check string)
    "constructing a capability is refused" "E0301"
    (code_of h "(var state-ref-opaque)");
  Alcotest.(check string)
    "constructing a capability by its hash is refused" "E0835"
    (code_of h
       (Printf.sprintf "(ref #%s con)" (Hash.to_hex Instance_contract.state_ref_opaque_constructor)));
  Alcotest.(check string)
    "matching on a capability is refused" "E0301"
    (code_of h "(lam ((pvar c)) (match (var c) (clause (pcon state-ref-opaque) (lit 1))))");
  Alcotest.(check string)
    "a capability in a nominal field is refused" "E0836"
    (code_of h "(deftype box () (con box (field held (tapp (tref state-ref) (tref int)))))");
  Alcotest.(check string)
    "a capability in a user operation signature is refused" "E0836"
    (code_of h "(defeffect leak () (op leak once ((tapp (tref state-ref) (tref int))) (ttuple)))");
  ignore
    (scheme_of h
       "(defterm ((binding hold () (lam ((pvar c)) (app (var some) (lam () (app (var state.get-at) \
        (var c))))))))");
  Alcotest.(check string)
    "a user handler clause for an instance operation is refused" "E0834"
    (code_of h
       "(lam ((pvar c)) (handle (app (var state.get-at) (var c)) (ret (pvar x) (var x)) (opclause \
        state.get-at ((pvar r)) k (app (var k) (lit 1)))))")

let cap = "(tapp (tref state-ref) (tref int))"

let entries_of scheme =
  match Types.repr (Types.instantiate ~level:1 scheme) with
  | Types.TArrow (_, row, _) -> List.length (Types.repr_row row).instances
  | _ -> Alcotest.fail "expected a function"

let test_annotations () =
  let h = fixture () in
  (* a row annotation's instance effect elaborates to its capability parameter's entry *)
  let bump =
    scheme_of h
      (Printf.sprintf
         "(defterm ((binding bump ((tarrow (%s) (row (eref state-instance)) (ttuple))) (lam ((pvar \
          c)) (app (var state.put-at) (var c) (app (var state.get-at) (var c)))))))"
         cap)
  in
  Alcotest.(check int) "the annotated bump has its capability's entry" 1 (entries_of bump);
  (* annotating an existing capability gets a flexible label *)
  ignore
    (scheme_of h
       (Printf.sprintf
          "(defterm ((binding peek () (lam ((pvar c)) (app (var state.get-at) (ann (var c) %s))))))"
          cap));
  (* a thunk whose row names the instance effect sees the enclosing arrow's capability *)
  ignore
    (scheme_of h
       (Printf.sprintf
          "(defterm ((binding use ((tarrow ((tarrow () (row (eref state-instance)) (ttuple)) %s) \
           (row (eref state-instance)) (ttuple))) (lam ((pvar k) (pvar c)) (app (var k))))))"
          cap));
  ignore
    (scheme_of h
       (Printf.sprintf
          "(defterm ((binding use-first ((tarrow (%s (tarrow () (row (eref state-instance)) \
           (ttuple))) (row (eref state-instance)) (ttuple))) (lam ((pvar c) (pvar k)) (app (var \
           k))))))"
          cap));
  ignore
    (scheme_of h
       "(defterm ((binding first ((tarrow ((tarrow () (row) (ttuple))) (row) (ttuple))) (lam \
        ((pvar k)) (app (var k))))))");
  (* capability first is accepted (limit L1) *)
  ignore
    (scheme_of h
       "(defterm ((binding ok () (lam ((pvar c)) (app (var use-first) (var c) (lam () (app (var \
        state.put-at) (var c) (lit 1))))))))");
  (* limit L1: the thunk's row meets the closed parameter row before the capability *)
  Alcotest.(check string)
    "L1: thunk before its capability is refused" "E0801"
    (code_of h
       "(defterm ((binding late () (lam ((pvar c)) (app (var use) (lam () (app (var state.put-at) \
        (var c) (lit 2))) (var c))))))");
  Alcotest.(check string)
    "L1: no capability unification relates c and d" "E0801"
    (code_of h
       "(defterm ((binding crossed () (lam ((pvar c) (pvar d)) (app (var use-first) (var c) (lam \
        () (app (var state.put-at) (var d) (lit 1))))))))");
  (* E0830: nothing determines the instance *)
  Alcotest.(check string)
    "a thunk-only annotation names no capability" "E0830"
    (code_of h
       "(lam ((pvar c)) (ann (lam () (app (var state.get-at) (var c))) (tarrow () (row (eref \
        state-instance)) (tref int))))");
  Alcotest.(check string)
    "L3: a result-only capability is not among the parameters" "E0830"
    (code_of h
       (Printf.sprintf
          "(defterm ((binding mint ((tarrow () (row (eref state-instance)) %s)) (lam () (app (var \
           mint))))))"
          cap));
  (* limit L3: each capability annotation gets its own label *)
  Alcotest.(check string)
    "L3: an annotation cannot share a label between positions" "E0804"
    (code_of h
       (Printf.sprintf
          "(defterm ((binding keep ((tarrow (%s) (row) %s)) (lam ((pvar c)) (var c)))))" cap cap));
  (* one entry per capability parameter: two capabilities give two entries *)
  Alcotest.(check int)
    "two capability parameters give two entries" 2
    (entries_of
       (scheme_of h
          (Printf.sprintf
             "(defterm ((binding both ((tarrow (%s %s) (row (eref state-instance)) (ttuple))) (lam \
              ((pvar c) (pvar d)) (app (var state.put-at) (var d) (app (var state.get-at) (var \
              c)))))))"
             cap cap)))

(* [scoped init body] is a scoped call whose callback binds [c]. *)
let scoped ?(var = "c") init body =
  Printf.sprintf "(app (var state.scoped) %s (lam ((pvar %s)) %s))" init var body

let defterm name value = Printf.sprintf "(defterm ((binding %s () %s)))" name value

let choose left right =
  Printf.sprintf "(match (var true) (clause (pcon true) %s) (clause (pcon false) %s))" left right

let test_scoped_form () =
  let h = fixture () in
  let check_ok label src =
    match Test_check.check_src h src with
    | Ok _ -> ()
    | Error diagnostics ->
        Alcotest.failf "%s: %s" label (String.concat "\n" (List.map Diag.to_string diagnostics))
  in
  (* a scope types its body, subtracts its own instance, and returns the body's result *)
  Alcotest.(check string)
    "a scope returns its body's result" "() ->{} Int"
    (Test_check.sig_of h
       (defterm "count"
          (Printf.sprintf "(lam () %s)" (scoped "(lit 0)" "(app (var state.get-at) (var c))"))));
  (* the two-store program: each operation reaches its own instance and payload *)
  check_ok "two stores"
    (defterm "two"
       (Printf.sprintf "(lam () %s)"
          (scoped "(lit 0)"
             (scoped ~var:"t" "(lit \"a\")"
                "(let nonrec (pwild) (app (var state.put-at) (var c) (lit 1)) (app (var \
                 state.get-at) (var t)))"))));
  (* helpers over a capability and its instance work inside a scope *)
  check_ok "bump helper"
    "(defterm ((binding bump () (lam ((pvar c)) (app (var state.put-at) (var c) (app (var \
     state.get-at) (var c)))))))";
  check_ok "helper in a scope"
    (defterm "use-bump"
       (Printf.sprintf "(lam () %s)" (scoped "(lit 0)" "(app (var bump) (var c))")));
  (* the initializer's effects charge the caller *)
  (match
     Test_check.check_src h
       (defterm "noisy"
          (Printf.sprintf "(lam () %s)"
             (scoped "(app (var print) (lit \"x\"))" "(app (var state.get-at) (var c))")))
   with
  | Ok { Check.names = [ (_, scheme) ]; _ } -> (
      match Types.repr (Types.instantiate ~level:1 scheme) with
      | Types.TArrow (_, row, _) ->
          let row = Types.repr_row row in
          Alcotest.(check int)
            "the initializer's effect is the caller's" 1 (List.length row.effects);
          Alcotest.(check int)
            "and no instance entry leaves the scope" 0 (List.length row.instances)
      | _ -> Alcotest.fail "unexpected shape")
  | _ -> Alcotest.fail "noisy did not check");
  (* the payload is the initializer's type *)
  Alcotest.(check string)
    "the payload agrees with the initializer" "E0801"
    (code_of h (scoped "(lit 0)" "(app (var state.put-at) (var c) (lit \"x\"))"));
  (* E0831: only a direct call with a literal one-parameter lambda *)
  let e0831 label src = Alcotest.(check string) label "E0831" (code_of h src) in
  e0831 "an alias" (defterm "my-scoped" "(var state.scoped)");
  e0831 "a forwarding wrapper"
    (defterm "with-counter" "(lam ((pvar f)) (app (var state.scoped) (lit 0) (var f)))");
  e0831 "wrong arity" "(app (var state.scoped) (lit 0))";
  e0831 "a two-parameter callback"
    "(app (var state.scoped) (lit 0) (lam ((pvar c) (pvar d)) (lit 1)))";
  e0831 "an annotated head"
    "(app (ann (var state.scoped) (tarrow ((tref int) (tvar f)) (row) (tref int))) (lit 0) (lam \
     ((pvar c)) (lit 1)))";
  (* E0832: the model's escapes *)
  let e0832 label src = Alcotest.(check string) label "E0832" (code_of h src) in
  e0832 "returning the capability" (scoped "(lit 0)" "(var c)");
  e0832 "returning a thunk over it" (scoped "(lit 0)" "(lam () (app (var state.get-at) (var c)))");
  e0832 "in a tuple" (scoped "(lit 0)" "(tuple (var c) (lit 1))");
  e0832 "in a container" (scoped "(lit 0)" "(app (var some) (var c))");
  (* through an outward effect payload, the second half of non-escape *)
  e0832 "an emitted capability"
    (Printf.sprintf "(app (var emit.collect) (lam () %s))"
       (scoped "(lit 0)" "(app (var emit) (var c))"));
  e0832 "a thrown capability"
    (Printf.sprintf "(app (var throw.to-result) (lam () %s))"
       (scoped "(lit 0)" "(let nonrec (pwild) (app (var throw) (var c)) (tuple))"));
  e0832 "an emitted capability under a user handler"
    (Printf.sprintf
       "(handle %s (ret (pvar x) (var x)) (opclause emit ((pvar v)) k (app (var k) (tuple))))"
       (scoped "(lit 0)" "(app (var emit) (var c))"));
  e0832 "rank-2 callback (A1.9)"
    (defterm "run"
       (Printf.sprintf "(lam ((pvar k)) %s)" (scoped "(lit 0)" "(app (var k) (var c))")));
  e0832 "a non-value alias bound outside the scope (A1.9)"
    (defterm "alias"
       (Printf.sprintf
          "(lam () (let nonrec (pvar r) (app (lam ((pvar x)) (var x)) (var state.get-at)) %s))"
          (scoped "(lit 0)" "(app (var r) (var c))")));
  check_ok "both"
    "(defterm ((binding both () (lam ((pvar f) (pvar g)) (let nonrec (pwild) (app (var f)) (app \
     (var g)))))))";
  e0832 "L4: an outer thunk sharing a row with an instance thunk"
    (defterm "outer"
       (Printf.sprintf "(lam ((pvar k)) %s)"
          (scoped "(lit 0)"
             "(app (var both) (var k) (lam () (app (var state.put-at) (var c) (lit 1))))")));
  e0832 "L4: a choice between an outer thunk and an instance thunk"
    (defterm "pick"
       (Printf.sprintf "(lam ((pvar k)) %s)"
          (scoped "(lit 0)" (choose "(var k)" "(lam () (app (var state.put-at) (var c) (lit 1)))"))));
  check_ok "L4 workaround: call k directly"
    (defterm "direct"
       (Printf.sprintf "(lam ((pvar k)) %s)"
          (scoped "(lit 0)"
             "(let nonrec (pwild) (app (var k)) (app (var state.put-at) (var c) (lit 1)))")));
  e0832 "A1.9: a group member receiving the capability"
    "(defterm ((binding walk () (lam ((pvar t)) (app (var state.scoped) (lit 0) (lam ((pvar c)) \
     (app (var visit) (var c) (var t)))))) (binding visit () (lam ((pvar c) (pvar t)) (app (var \
     walk) (var t))))))";
  (* model counterexample 3 and A1.9: instances are not interchangeable *)
  let nested body = scoped ~var:"a" "(lit 0)" (scoped ~var:"b" "(lit 0)" body) in
  check_ok "use-first"
    (Printf.sprintf
       "(defterm ((binding use-first ((tarrow (%s (tarrow () (row (eref state-instance)) \
        (ttuple))) (row (eref state-instance)) (ttuple))) (lam ((pvar c) (pvar k)) (app (var \
        k))))))"
       cap);
  Alcotest.(check string)
    "a thunk over b where one over a is expected" "E0801"
    (code_of h
       (nested "(app (var use-first) (var a) (lam () (app (var state.put-at) (var b) (lit 1))))"));
  check_ok "the same thunk over a"
    (defterm "same-a"
       (Printf.sprintf "(lam () %s)"
          (nested "(app (var use-first) (var a) (lam () (app (var state.put-at) (var a) (lit 1))))")));
  Alcotest.(check string)
    "choosing between live instances" "E0801"
    (code_of h (nested (Printf.sprintf "(app (var state.get-at) %s)" (choose "(var a)" "(var b)"))));
  check_ok "pair"
    "(defterm ((binding pair () (lam ((pvar f) (pvar x) (pvar y)) (let nonrec (pwild) (app (var f) \
     (var x)) (app (var f) (var y)))))))";
  Alcotest.(check string)
    "a rank-1 callback on two instances" "E0801"
    (code_of h (nested "(app (var pair) (var state.get-at) (var a) (var b))"));
  (* limit L1 inside a scope *)
  check_ok "use"
    (Printf.sprintf
       "(defterm ((binding use ((tarrow ((tarrow () (row (eref state-instance)) (ttuple)) %s) (row \
        (eref state-instance)) (ttuple))) (lam ((pvar k) (pvar c)) (app (var k))))))"
       cap);
  Alcotest.(check string)
    "L1: thunk before its capability" "E0801"
    (code_of h
       (scoped "(lit 0)" "(app (var use) (lam () (app (var state.put-at) (var c) (lit 2))) (var c))"));
  (* limit L1's third case: a rigid signature proof unifies parameters left to right *)
  Alcotest.(check string)
    "L1: the callback before its capability in a signature proof" "E0804"
    (code_of h
       (Printf.sprintf
          "(defterm ((binding run ((tarrow ((tarrow ((tarrow () (row (eref state-instance)) (tref \
           int))) (row) (tref int)) %s) (row) (tref int))) (lam ((pvar k) (pvar c)) (app (var k) \
           (lam () (app (var state.get-at) (var c))))))))"
          cap));
  check_ok "L1: capability first in a signature proof"
    (Printf.sprintf
       "(defterm ((binding run-first ((tarrow (%s (tarrow ((tarrow () (row (eref state-instance)) \
        (tref int))) (row) (tref int))) (row) (tref int))) (lam ((pvar c) (pvar k)) (app (var k) \
        (lam () (app (var state.get-at) (var c))))))))"
       cap);
  (* an annotated callback is checked with flexible labels *)
  check_ok "annotated callback"
    (defterm "annotated"
       (Printf.sprintf
          "(lam () (app (var state.scoped) (lit 0) (ann (lam ((pvar c)) (app (var state.get-at) \
           (var c))) (tarrow (%s) (row (eref state-instance)) (tref int)))))"
          cap))

let test_fresh_continuations () =
  let h = fixture () in
  let check_ok label src =
    match Test_check.check_src h src with
    | Ok _ -> ()
    | Error diagnostics ->
        Alcotest.failf "%s: %s" label (String.concat "\n" (List.map Diag.to_string diagnostics))
  in
  let e0833 label src = Alcotest.(check string) label "E0833" (code_of h src) in
  let in_scope body = defterm "probe" (Printf.sprintf "(lam () %s)" (scoped "(lit 0)" body)) in
  (* A1.4: an instance operation in a fresh-continuation callback is refused *)
  e0833 "a spawned child using the capability"
    (in_scope "(app (var async.spawn) (lam () (app (var state.put-at) (var c) (lit 1))))");
  e0833 "an async.scope body using the capability"
    (in_scope "(app (var async.scope) (lam () (app (var state.get-at) (var c))))");
  e0833 "a likelihood-weighting thunk using the capability"
    (in_scope "(app (var dist.sample-lw) (lam () (app (var state.get-at) (var c))) (lit 1) (lit 1))");
  (* values read from an instance may be handed to spawned work *)
  check_ok "spawning with a value read from the instance"
    (in_scope
       "(let nonrec (pvar v) (app (var state.get-at) (var c)) (app (var async.spawn) (lam () (var \
        v))))");
  (* the flag is OR-ed through a row-polymorphic helper (limit L2) *)
  check_ok "bg" "(defterm ((binding bg () (lam ((pvar k)) (app (var async.spawn) (var k))))))";
  e0833 "L2: a helper sharing the spawn row"
    (in_scope "(app (var bg) (lam () (app (var state.put-at) (var c) (lit 1))))");
  check_ok "par"
    "(defterm ((binding par () (lam ((pvar k1) (pvar k2)) (let nonrec (pvar t) (app (var \
     async.spawn) (var k1)) (let nonrec (pwild) (app (var k2)) (app (var async.await) (var \
     t))))))))";
  e0833 "L2: a callback that runs in the parent but shares the spawn row"
    (in_scope "(app (var par) (lam () (lit 1)) (lam () (app (var state.get-at) (var c))))");
  (* the refusal keeps its own code where an ordinary row mismatch would be relabeled *)
  e0833 "an annotated spawn helper"
    (Printf.sprintf
       "(defterm ((binding spawn-bump ((tarrow (%s) (row (eref state-instance) (eref async)) \
        (ttuple))) (lam ((pvar c)) (let nonrec (pwild) (app (var async.spawn) (lam () (app (var \
        state.put-at) (var c) (lit 1)))) (tuple))))))"
       cap)

let test_determinacy_and_consumers () =
  let ((store, _) as h) = fixture () in
  let check_ok label src =
    match Test_check.check_src h src with
    | Ok _ -> ()
    | Error diagnostics ->
        Alcotest.failf "%s: %s" label (String.concat "\n" (List.map Diag.to_string diagnostics))
  in
  check_ok "loop" "(defterm ((binding loop () (lam () (app (var loop))))))";
  (* A1.6: a quantified label that no capability type determines is refused at publication *)
  Alcotest.(check string)
    "an instance no capability determines" "E0830"
    (code_of h (defterm "read-unknown" "(lam () (app (var state.get-at) (app (var loop))))"));
  Alcotest.(check string)
    "at a local let" "E0830"
    (code_of h
       (defterm "local"
          "(lam () (let nonrec (pvar r) (lam () (app (var state.get-at) (app (var loop)))) (lit \
           1)))"));
  Alcotest.(check string)
    "at a local let rec" "E0830"
    (code_of h
       (defterm "local-rec"
          "(lam () (let rec (pvar r) (lam () (app (var state.get-at) (app (var loop)))) (lit 1)))"));
  Alcotest.(check string)
    "in an effect declaration's operation" "E0830"
    (code_of h
       "(defeffect bad () (op invoke ((tarrow () (row (eref state-instance)) (tref int))) (tref \
        int)))");
  Alcotest.(check string)
    "a top-level expression holding an instance entry" "E0830"
    (code_of h "(app (var state.get-at) (app (var loop)))");
  Alcotest.(check string)
    "a top-level expression hiding an instance in an effect payload" "E0830"
    (code_of h "(app (var emit) (lam () (app (var state.get-at) (app (var loop)))))");
  (* quantification reaches labels inside ambient payloads; display does not show them *)
  (match Test_check.check_src h (defterm "send" "(lam () (app (var emit) (var state.get-at)))") with
  | Ok { Check.names = [ (_, scheme) ]; _ } ->
      Alcotest.(check bool)
        "a label inside a payload is quantified" true
        (List.exists (fun id -> id < 0) (fst (Types.quantified scheme)));
      Alcotest.(check bool)
        "but not displayed" false
        (List.exists (fun id -> id < 0) (fst (Types.quantified ~walk:`Display scheme)))
  | _ -> Alcotest.fail "send did not check");
  (* a capability in the result determines the label (limit L3's inferred case) *)
  check_ok "result-only capability"
    (defterm "mint"
       "(lam () (let nonrec (pvar x) (app (var loop)) (let nonrec (pwild) (app (var state.put-at) \
        (var x) (lit 1)) (var x))))");
  (* ordinary row polymorphism is unaffected *)
  check_ok "apply" (defterm "apply" "(lam ((pvar k)) (app (var k)))");
  check_ok "apply a scoped thunk"
    (defterm "apply-scoped"
       (Printf.sprintf "(lam () %s)"
          (scoped "(lit 0)" "(app (var apply) (lam () (app (var state.get-at) (var c))))")));
  (* E0815 sees instance entries *)
  Alcotest.(check string)
    "a definition body performing an instance operation" "E0815"
    (code_of h (defterm "eager" "(app (var state.get-at) (app (var loop)))"));
  (* display hides labels and names the instance effect *)
  Alcotest.(check string)
    "display" "forall a. (StateRef a) ->{StateInstance} a"
    (Test_check.sig_of h (defterm "peek-at" "(lam ((pvar c)) (app (var state.get-at) (var c)))"));
  (* purity and tier count instance entries *)
  let instance_only =
    {
      Types.effects = [];
      payloads = [];
      instances =
        [
          {
            Types.effect_id = Instances_fixture.hash store Resolve.KEffect "state-instance";
            label = Types.TLabel (Types.fresh_id (), "l");
            payload = [];
          };
        ];
      tail = Types.RClosed;
    }
  in
  Alcotest.(check bool)
    "a row of entries only is not pure" false
    (Types.is_closed_pure instance_only);
  Alcotest.(check bool)
    "nor in the tier classification" false
    (Tier.classify_row instance_only = Tier.Pure)

let test_trusted_scheme () =
  let scheme_text (_, ctx) =
    match Check.force_term ctx Instance_contract.state_scoped with
    | Ok scheme -> Check.show_scheme ctx scheme
    | Error diagnostics ->
        Alcotest.failf "state.scoped: %s" (String.concat "\n" (List.map Diag.to_string diagnostics))
  in
  (* registration seeds the trusted scheme; the body is never checked under registration (A2.3) *)
  Alcotest.(check string)
    "the seeded scheme" "forall a b | e. (b, (StateRef b) ->{StateInstance | e} a) ->{| e} a"
    (scheme_text (fresh ()));
  (* checking the trusted declaration directly under registration fails closed (A2.3) *)
  (let store, ctx = fresh () in
   match Store.locate_internal store Instance_contract.state_scoped with
   | Ok { Store.decl; _ } -> (
       match Check.check_top ctx (Kernel.Decl decl) with
       | Ok _ -> Alcotest.fail "the trusted body was checked under registration"
       | Error diagnostics ->
           Alcotest.(check (list string))
             "direct checking is refused" [ "E0834" ]
             (List.map Diag.code_or_uncoded diagnostics))
   | Error _ -> Alcotest.fail "state.scoped is not in the store");
  (* on an unregistered context the body checks as an ordinary handler, forcing one payload *)
  Alcotest.(check string)
    "the body on an unregistered context"
    "forall a b | e. (b, (StateRef b) ->{StateInstance | e} a) ->{StateInstance | e} a"
    (scheme_text (Test_check.make_cctx ~instances:false ()))

let throw_scoped ?(var = "c") body =
  Printf.sprintf "(app (var throw.scoped) (lam ((pvar %s)) %s))" var body

let emit_scoped ?(var = "c") body =
  Printf.sprintf "(app (var emit.scoped) (lam ((pvar %s)) %s))" var body

let test_throw_emit () =
  let ((store, ctx) as h) = fixture () in
  let check_ok label src =
    match Test_check.check_src h src with
    | Ok _ -> ()
    | Error diagnostics ->
        Alcotest.failf "%s: %s" label (String.concat "\n" (List.map Diag.to_string diagnostics))
  in
  let code label expected src = Alcotest.(check string) label expected (code_of h src) in
  let scheme_text ctx hash =
    match Check.force_term ctx hash with
    | Ok scheme -> Check.show_scheme ctx scheme
    | Error diagnostics ->
        Alcotest.failf "scheme: %s" (String.concat "\n" (List.map Diag.to_string diagnostics))
  in
  let throw = Instance_contract.throw_family and emit = Instance_contract.emit_family in
  (* seeded schemes (A3.4) and the bodies on an unregistered context (A3.7) *)
  Alcotest.(check string)
    "throw.scoped's seeded scheme"
    "forall a b | e. ((ThrowRef a) ->{ThrowInstance | e} b) ->{| e} Result a b"
    (scheme_text ctx throw.scoped);
  Alcotest.(check string)
    "emit.scoped's seeded scheme"
    "forall a b | e. ((EmitRef b) ->{EmitInstance | e} a) ->{| e} (a, List b)"
    (scheme_text ctx emit.scoped);
  let _, unregistered = Test_check.make_cctx ~instances:false () in
  Alcotest.(check string)
    "throw.scoped's body unregistered"
    "forall a b | e. ((ThrowRef a) ->{ThrowInstance | e} b) ->{ThrowInstance | e} Result a b"
    (scheme_text unregistered throw.scoped);
  Alcotest.(check string)
    "emit.scoped's body unregistered"
    "forall a b | e. ((EmitRef b) ->{EmitInstance | e} a) ->{EmitInstance | e} (a, List b)"
    (scheme_text unregistered emit.scoped);
  List.iter
    (fun (family : Instance_contract.family) ->
      match Store.locate_internal store family.scoped with
      | Ok { Store.decl; _ } -> (
          match Check.check_top ctx (Kernel.Decl decl) with
          | Ok _ -> Alcotest.fail "a trusted body was checked under registration"
          | Error diagnostics ->
              Alcotest.(check (list string))
                "direct checking is refused" [ "E0834" ]
                (List.map Diag.code_or_uncoded diagnostics))
      | Error _ -> Alcotest.fail "a scoped term is not in the store")
    [ throw; emit ];
  (* shapes are validated (A3.4) *)
  let state = Instances_fixture.registration store in
  let refused label registration =
    match Check.register_instances unregistered [ registration ] with
    | () -> Alcotest.failf "%s was accepted" label
    | exception Invalid_argument _ -> ()
  in
  refused "a State effect with the Throw shape" { state with shape = Instance_contract.Throw };
  refused "a State effect as Throw at position 0"
    { state with shape = Instance_contract.Throw; callback_position = 0 };
  let registration_of (family : Instance_contract.family) : Check.instance_registration =
    {
      scoped = family.scoped;
      instance_effect = family.instance_effect;
      capability = family.capability;
      operations = family.operations;
      callback_position = 0;
      shape = family.shape;
    }
  in
  let throw_registration = registration_of throw and emit_registration = registration_of emit in
  Check.register_instances (snd (Test_check.make_cctx ~instances:false ())) [ throw_registration ];
  Check.register_instances (snd (Test_check.make_cctx ~instances:false ())) [ emit_registration ];
  refused "a Throw effect with the Emit shape (its answer is result-only)"
    { throw_registration with shape = Instance_contract.Emit };
  refused "an Emit effect with the Throw shape (no answer parameter)"
    { emit_registration with shape = Instance_contract.Throw };
  refused "a Throw registration with State's operations"
    { throw_registration with operations = state.operations };
  (* the answer is fresh at every reference (A3.2), and fail passes determinacy (A1.6) *)
  check_ok "fail"
    "(defterm ((binding fail () (lam ((pvar c)) (app (var throw.throw-at) (var c) (lit \"x\"))))))";
  check_ok "fail at two result types"
    (defterm "twice"
       (Printf.sprintf "(lam () %s)"
          (throw_scoped
             "(let nonrec (pvar n) (app (var add) (app (var fail) (var c)) (lit 1)) (match (app \
              (var fail) (var c)) (clause (pcon true) (var n)) (clause (pcon false) (lit 0))))")));
  check_ok "an annotated thrower"
    "(defterm ((binding fail-int ((tarrow ((tapp (tref throw-ref) (tref text))) (row (eref \
     throw-instance)) (tref int))) (lam ((pvar c)) (app (var throw.throw-at) (var c) (lit \
     \"x\"))))))";
  (* E0832 through the transformed result and through payloads (A3.3) *)
  code "a Throw scope returning its capability" "E0832" (throw_scoped "(var c)");
  code "an Emit scope returning its capability" "E0832" (emit_scoped "(var c)");
  code "a thrown capability of an enclosing scope" "E0832"
    (scoped ~var:"s" "(lit 0)" (throw_scoped ~var:"t" "(app (var throw.throw-at) (var t) (var s))"));
  code "an emitted capability of an enclosing scope" "E0832"
    (scoped ~var:"s" "(lit 0)" (emit_scoped ~var:"e" "(app (var emit.emit-at) (var e) (var s))"));
  code "an emitted thunk over an inner capability" "E0832"
    (emit_scoped ~var:"e"
       (scoped ~var:"s" "(lit 0)"
          "(app (var emit.emit-at) (var e) (lam () (app (var state.get-at) (var s))))"));
  (* E0833, E0834, E0835, E0831 *)
  code "a spawned Throw" "E0833"
    (Printf.sprintf "(lam () %s)"
       (throw_scoped "(app (var async.spawn) (lam () (app (var throw.throw-at) (var c) (lit 1))))"));
  code "a spawned Emit" "E0833"
    (Printf.sprintf "(lam () %s)"
       (emit_scoped "(app (var async.spawn) (lam () (app (var emit.emit-at) (var c) (lit 1))))"));
  code "a user clause on throw.throw-at" "E0834"
    "(lam ((pvar c)) (handle (app (var throw.throw-at) (var c) (lit 1)) (ret (pvar x) (var x)) \
     (opclause throw.throw-at ((pvar r) (pvar e)) k (lit 0))))";
  code "forging a ThrowRef" "E0835" (Printf.sprintf "(ref #%s con)" (Hash.to_hex throw.carrier));
  code "forging an EmitRef" "E0835" (Printf.sprintf "(ref #%s con)" (Hash.to_hex emit.carrier));
  code "a user clause on emit.emit-at" "E0834"
    "(lam ((pvar c)) (handle (app (var emit.emit-at) (var c) (lit 1)) (ret (pvar x) (var x)) \
     (opclause emit.emit-at ((pvar r) (pvar w)) k (app (var k) (tuple)))))";
  code "a forwarding Throw wrapper" "E0831"
    (defterm "wrap" "(lam ((pvar f)) (app (var throw.scoped) (var f)))");
  code "an initializer given to Emit" "E0831"
    "(app (var emit.scoped) (lit 0) (lam ((pvar c)) (lit 1)))"

(* separate artifact loading (TS.2 acceptance): a capability-taking function installed in an
   on-disk store keeps its instance-polymorphic scheme when the store is reopened by a fresh
   checker, and its label stays hidden in the displayed signature *)
let test_separate_loading () =
  let dir = Eval_support.fresh_dir () in
  let open_checked () =
    let store =
      match Store.open_store dir with Ok s -> s | Error ds -> Eval_support.fail_diags "open" ds
    in
    (match Prelude.load ~dir:"../prelude" store with
    | Ok _ -> ()
    | Error ds -> Eval_support.fail_diags "prelude" ds);
    let ctx =
      match Check.make_ctx store with Ok c -> c | Error ds -> Eval_support.fail_diags "ctx" ds
    in
    (match Prelude.builtin_signatures store with
    | Ok sigs -> Check.register_builtin_signatures ctx sigs
    | Error ds -> Eval_support.fail_diags "sigs" ds);
    (store, ctx)
  in
  let first = open_checked () in
  ignore
    (scheme_of first
       "(defterm ((binding bump () (lam ((pvar c)) (app (var state.put-at) (var c) (app (var add) \
        (app (var state.get-at) (var c)) (lit 1)))))))");
  (* a second store handle over the same directory, with a fresh checker *)
  let second = open_checked () in
  Alcotest.(check string)
    "the reloaded signature hides its label" "(StateRef Int) ->{StateInstance} ()"
    (match Store.lookup_kind (fst second) "bump" Resolve.KTerm with
    | Some { Resolve.hash; _ } -> (
        match Check.force_term (snd second) hash with
        | Ok scheme -> Check.show_scheme (snd second) scheme
        | Error ds -> Eval_support.fail_diags "force bump" ds)
    | None -> Alcotest.fail "bump was not persisted");
  ignore
    (scheme_of second
       (Printf.sprintf "(defterm ((binding two () (lam () %s))))"
          (scoped ~var:"c" "(lit 0)"
             (scoped ~var:"d" "(lit 1)"
                "(let nonrec (pwild) (app (var bump) (var c)) (app (var bump) (var d)))"))));
  Alcotest.(check string)
    "the reloaded payload still binds" "E0801"
    (code_of second (scoped "(lit \"x\")" "(app (var bump) (var c))"))

(* quotation carries no instance typing (A1.2): quoting an instance operation inside a scope is
   inert code; only its unchecked evaluation could misuse a capability, which the trap catches *)
let test_quotation_boundary () =
  let h = fixture () in
  Alcotest.(check string)
    "a quoted instance operation is code" "() ->{} Code"
    (Test_check.sig_of h
       (defterm "quoted"
          (Printf.sprintf "(lam () %s)"
             (scoped "(lit 0)" "(quote (app (var state.get-at) (var c)))"))))

let test_unregistered_controls () =
  (* without a registration the fixture is ordinary: no labels, ordinary effects and handlers *)
  let h = Test_check.make_cctx ~instances:false () in
  ignore
    (scheme_of h "(defterm ((binding read () (lam ((pvar c)) (app (var state.get-at) (var c))))))");
  match
    Test_check.check_src h
      "(lam ((pvar c)) (handle (app (var state.get-at) (var c)) (ret (pvar x) (var x)) (opclause \
       state.get-at ((pvar r)) k (app (var k) (lit 1)))))"
  with
  | Ok _ -> ()
  | Error diagnostics ->
      Alcotest.(check bool)
        "no instance refusal without a registration" false
        (List.exists (fun d -> Diag.code_or_uncoded d = "E0834") diagnostics)

let suite =
  [
    Alcotest.test_case "registration is test-only and validated" `Quick test_registration;
    Alcotest.test_case "instance operations type through their capability" `Quick
      test_operation_schemes;
    Alcotest.test_case "capabilities are opaque, unstorable, and not user-handled" `Quick
      test_opacity_storage_and_handlers;
    Alcotest.test_case "annotations elaborate instance rows from capability parameters" `Quick
      test_annotations;
    Alcotest.test_case "the scoped checker form and non-escape" `Quick test_scoped_form;
    Alcotest.test_case "fresh-continuation callbacks refuse instance entries" `Quick
      test_fresh_continuations;
    Alcotest.test_case "determinacy, display and row consumers" `Quick
      test_determinacy_and_consumers;
    Alcotest.test_case "the trusted scheme of state.scoped" `Quick test_trusted_scheme;
    Alcotest.test_case "Throw and Emit scoped instances" `Quick test_throw_emit;
    Alcotest.test_case "instance schemes survive separate loading" `Quick test_separate_loading;
    Alcotest.test_case "quotation carries no instance typing" `Quick test_quotation_boundary;
    Alcotest.test_case "without a registration the fixture is ordinary" `Quick
      test_unregistered_controls;
  ]
