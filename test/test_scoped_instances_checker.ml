(* TS.2 slice 1: the checker side of scoped effect instances (design
   docs/designs/scoped-effect-instances.md §9). Instance effects are registered on test contexts
   only, through [Instances_fixture]. *)

open Jacquard

let fresh () = Test_check.make_cctx ()

let expect_ok label = function
  | Ok value -> value
  | Error diagnostics ->
      Alcotest.failf "%s: %s" label (String.concat "\n" (List.map Diag.to_string diagnostics))

let test_registration () =
  let store, ctx = fresh () in
  Alcotest.(check int)
    "a production-built context registers no instance effect" 0
    (List.length (Check.instance_registrations ctx));
  expect_ok "fixture" (Instances_fixture.install_and_register store ctx);
  Alcotest.(check int)
    "the fixture registers one" 1
    (List.length (Check.instance_registrations ctx));
  (* registrations are validated against the store *)
  let valid = Instances_fixture.registration store in
  let refused label registration =
    match Check.register_instances ctx [ registration ] with
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
  Alcotest.(check int)
    "refused registrations add nothing" 1
    (List.length (Check.instance_registrations ctx))

let fixture () =
  let store, ctx = fresh () in
  expect_ok "fixture" (Instances_fixture.install_and_register store ctx);
  (store, ctx)

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
    scheme_of h "(defterm ((binding read () (lam ((pvar c)) (app (var get-at) (var c))))))"
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
            (Hash.equal entry.effect registration.instance_effect);
          Alcotest.(check bool) "with the capability's label" true (Types.same_label label entry.label);
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
      "(defterm ((binding two () (lam ((pvar c) (pvar d)) (let nonrec (pvar r) (var get-at) (let \
       nonrec (pwild) (app (var r) (var c)) (app (var r) (var d))))))))"
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
      "(defterm ((binding same () (lam ((pvar c)) (let nonrec (pwild) (app (var get-at) (var c)) \
       (app (var put-at) (var c) (app (var get-at) (var c))))))))"
  in
  match Types.repr (Types.instantiate ~level:1 same) with
  | Types.TArrow (_, row, _) ->
      Alcotest.(check int) "one capability, one entry" 1 (List.length (Types.repr_row row).instances)
  | _ -> Alcotest.fail "unexpected shape"

let test_opacity_storage_and_handlers () =
  let h = fixture () in
  Alcotest.(check string)
    "constructing a capability is refused" "E0835"
    (code_of h "(var state-ref-opaque)");
  Alcotest.(check string)
    "matching on a capability is refused" "E0835"
    (code_of h "(lam ((pvar c)) (match (var c) (clause (pcon state-ref-opaque) (lit 1))))");
  Alcotest.(check string)
    "a capability in a nominal field is refused" "E0836"
    (code_of h "(deftype box () (con box (field held (tapp (tref state-ref) (tref int)))))");
  Alcotest.(check string)
    "a capability in a user operation signature is refused" "E0836"
    (code_of h "(defeffect leak () (op leak once ((tapp (tref state-ref) (tref int))) (ttuple)))");
  ignore
    (scheme_of h
       "(defterm ((binding hold () (lam ((pvar c)) (app (var some) (lam () (app (var get-at) \
        (var c))))))))");
  Alcotest.(check string)
    "a user handler clause for an instance operation is refused" "E0834"
    (code_of h
       "(lam ((pvar c)) (handle (app (var get-at) (var c)) (ret (pvar x) (var x)) (opclause \
        get-at ((pvar r)) k (app (var k) (lit 1)))))")

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
         "(defterm ((binding bump ((tarrow (%s) (row (eref state-instance)) (ttuple))) (lam ((pvar c)) \
          (app (var put-at) (var c) (app (var get-at) (var c)))))))"
         cap)
  in
  Alcotest.(check int) "the annotated bump has its capability's entry" 1 (entries_of bump);
  (* annotating an existing capability gets a flexible label *)
  ignore
    (scheme_of h
       (Printf.sprintf
          "(defterm ((binding peek () (lam ((pvar c)) (app (var get-at) (ann (var c) %s))))))" cap));
  (* a thunk whose row names the instance effect sees the enclosing arrow's capability *)
  ignore
    (scheme_of h
       (Printf.sprintf
          "(defterm ((binding use ((tarrow ((tarrow () (row (eref state-instance)) (ttuple)) %s) (row \
           (eref state-instance)) (ttuple))) (lam ((pvar k) (pvar c)) (app (var k))))))"
          cap));
  ignore
    (scheme_of h
       (Printf.sprintf
          "(defterm ((binding use-first ((tarrow (%s (tarrow () (row (eref state-instance)) (ttuple))) \
           (row (eref state-instance)) (ttuple))) (lam ((pvar c) (pvar k)) (app (var k))))))"
          cap));
  ignore
    (scheme_of h
       "(defterm ((binding first ((tarrow ((tarrow () (row) (ttuple))) (row) (ttuple))) (lam \
        ((pvar k)) (app (var k))))))");
  (* capability first is accepted (limit L1) *)
  ignore
    (scheme_of h
       "(defterm ((binding ok () (lam ((pvar c)) (app (var use-first) (var c) (lam () (app (var \
        put-at) (var c) (lit 1))))))))");
  (* limit L1: the thunk's row meets the closed parameter row before the capability *)
  Alcotest.(check string)
    "L1: thunk before its capability is refused" "E0801"
    (code_of h
       "(defterm ((binding late () (lam ((pvar c)) (app (var use) (lam () (app (var put-at) (var \
        c) (lit 2))) (var c))))))");
  Alcotest.(check string)
    "L1: no capability unification relates c and d" "E0801"
    (code_of h
       "(defterm ((binding crossed () (lam ((pvar c) (pvar d)) (app (var use-first) (var c) (lam \
        () (app (var put-at) (var d) (lit 1))))))))");
  (* E0830: nothing determines the instance *)
  Alcotest.(check string)
    "a thunk-only annotation names no capability" "E0830"
    (code_of h
       "(lam ((pvar c)) (ann (lam () (app (var get-at) (var c))) (tarrow () (row (eref state-instance)) \
        (tref int))))");
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
              ((pvar c) (pvar d)) (app (var put-at) (var d) (app (var get-at) (var c)))))))"
             cap cap)))

let test_unregistered_controls () =
  (* without a registration the fixture is ordinary: no labels, ordinary effects and handlers *)
  let store, ctx = fresh () in
  expect_ok "install" (Instances_fixture.install store ctx);
  let h = (store, ctx) in
  ignore (scheme_of h "(defterm ((binding read () (lam ((pvar c)) (app (var get-at) (var c))))))");
  match
    Test_check.check_src h
      "(lam ((pvar c)) (handle (app (var get-at) (var c)) (ret (pvar x) (var x)) (opclause get-at \
       ((pvar r)) k (app (var k) (lit 1)))))"
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
    Alcotest.test_case "without a registration the fixture is ordinary" `Quick
      test_unregistered_controls;
  ]
