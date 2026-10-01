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

let suite =
  [ Alcotest.test_case "registration is test-only and validated" `Quick test_registration ]
