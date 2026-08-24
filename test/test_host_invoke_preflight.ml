open Jacquard
module Host = Host_protocol_v0

let fail_diagnostics diagnostics = String.concat "\n" (List.map Diag.to_string diagnostics)

let expect_ok label = function
  | Ok value -> value
  | Error diagnostics -> Alcotest.failf "%s failed:\n%s" label (fail_diagnostics diagnostics)

let expect_code label expected = function
  | Error (diagnostic :: _) ->
      Alcotest.(check string) label expected (Diag.code_or_uncoded diagnostic)
  | Error [] -> Alcotest.failf "%s returned an empty diagnostic list" label
  | Ok _ -> Alcotest.failf "%s unexpectedly succeeded" label

let fresh_dir =
  let serial = ref 0 in
  fun label ->
    incr serial;
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "jacquard-host-preflight-%s-%d-%d" label (Unix.getpid ()) !serial)

let put_src store source =
  let form =
    expect_ok "parse fixture declaration" (Reader.parse_one ~file:"host-preflight.jqd" source)
  in
  let declaration = expect_ok "validate fixture declaration" (Kernel.decl_of_form form) in
  let declaration =
    expect_ok "resolve fixture declaration"
      (Resolve.resolve_decl (Store.names_view store) declaration)
  in
  expect_ok "store fixture declaration" (Store.put_decl store declaration)

let named name hashes = List.assoc name hashes.Canon.named

let seed_primitives store =
  List.iter
    (fun name ->
      ignore (put_src store (Printf.sprintf "(deftype %s () (con host-%s-value))" name name)))
    [ "int"; "real"; "text"; "code"; "hash"; "secret" ]

let required_hash store name kind =
  match Store.lookup_kind store name kind with
  | Some { Resolve.hash; _ } -> hash
  | None -> Alcotest.failf "fixture prelude is missing %s" name

type fixture = {
  store : Store.t;
  checker : Check.ctx;
  int_type : Hash.t;
  text_type : Hash.t;
  hash_type : Hash.t;
  packet_type : Hash.t;
  packet_constructor : Hash.t;
  world_effect : Hash.t;
  send_operation : Hash.t;
  log_operation : Hash.t;
  callback_operation : Hash.t;
  peek_operation : Hash.t;
  generic_effect : Hash.t;
  generic_operation : Hash.t;
  pure_target : Hash.t;
  effectful_target : Hash.t;
  generic_target : Hash.t;
  constant_target : Hash.t;
  polymorphic_target : Hash.t;
  open_row_target : Hash.t;
  higher_order_target : Hash.t;
}

let make_fixture () =
  let store = expect_ok "open fixture store" (Store.open_store (fresh_dir "main")) in
  seed_primitives store;
  let packet =
    put_src store
      "(deftype boundary-packet ((tvar a)) (con make-boundary-packet (field (tvar a)) (field (tref \
       text))))"
  in
  let world =
    put_src store
      "(defeffect boundary-world () (op boundary.send once ((tref int) (tref text)) (tref text)) \
       (op boundary.log once ((tref text)) (ttuple)) (op boundary.callback once ((tarrow ((tref \
       int)) (row) (tref int))) (tref int)) (op boundary.peek () (tref int)))"
  in
  let generic =
    put_src store
      "(defeffect boundary-generic ((tvar a)) (op boundary.generic once ((tvar a)) (tvar a)))"
  in
  let pure =
    put_src store
      "(defterm ((binding boundary.pure ((tarrow ((tapp (tref boundary-packet) (tref int)) (ttuple \
       (tref text) (tref hash))) (row) (tref text))) (lam ((pvar packet) (pvar metadata)) (lit \
       \"accepted\")))))"
  in
  let effectful =
    put_src store
      "(defterm ((binding boundary.effectful ((tarrow ((tref int) (tref text)) (row (eref \
       boundary-world)) (tref text))) (lam ((pvar count) (pvar body)) (app (var boundary.send) \
       (var count) (var body))))))"
  in
  let generic_target =
    put_src store
      "(defterm ((binding boundary.generic-target ((tarrow ((tref int)) (row (eref \
       boundary-generic)) (tref int))) (lam ((pvar value)) (app (var boundary.generic) (var \
       value))))))"
  in
  let constant = put_src store "(defterm ((binding boundary.constant () (lit 1))))" in
  let polymorphic =
    put_src store
      "(defterm ((binding boundary.identity ((tarrow ((tvar a)) (row) (tvar a))) (lam ((pvar \
       value)) (var value)))))"
  in
  let open_row =
    put_src store
      "(defterm ((binding boundary.forward () (lam ((pvar computation)) (app (var computation))))))"
  in
  let higher_order =
    put_src store
      "(defterm ((binding boundary.higher ((tarrow ((tarrow ((tref int)) (row) (tref int))) (row) \
       (tref int))) (lam ((pvar function)) (app (var function) (lit 1))))))"
  in
  let checker = expect_ok "create fixture checker" (Check.make_ctx store) in
  {
    store;
    checker;
    int_type = required_hash store "int" Resolve.KType;
    text_type = required_hash store "text" Resolve.KType;
    hash_type = required_hash store "hash" Resolve.KType;
    packet_type = named "boundary-packet" packet;
    packet_constructor = named "make-boundary-packet" packet;
    world_effect = named "boundary-world" world;
    send_operation = named "boundary.send" world;
    log_operation = named "boundary.log" world;
    callback_operation = named "boundary.callback" world;
    peek_operation = named "boundary.peek" world;
    generic_effect = named "boundary-generic" generic;
    generic_operation = named "boundary.generic" generic;
    pure_target = named "boundary.pure" pure;
    effectful_target = named "boundary.effectful" effectful;
    generic_target = named "boundary.generic-target" generic_target;
    constant_target = named "boundary.constant" constant;
    polymorphic_target = named "boundary.identity" polymorphic;
    open_row_target = named "boundary.forward" open_row;
    higher_order_target = named "boundary.higher" higher_order;
  }

let fixture = lazy (make_fixture ())
let nominal identity arguments = Types.TCon (identity, arguments)
let int_type fixture = nominal fixture.int_type []
let text_type fixture = nominal fixture.text_type []
let hash_type fixture = nominal fixture.hash_type []
let packet_int fixture = nominal fixture.packet_type [ int_type fixture ]
let metadata_type fixture = Types.TTuple [ text_type fixture; hash_type fixture ]

let encode_type value =
  expect_ok "encode fixture boundary type"
    (Host.encode_boundary_type ~budget:(Host.create_boundary_budget Host.hard_limits) value)

let encode_value value =
  expect_ok "encode fixture boundary value"
    (Host.encode_boundary_value ~budget:(Host.create_boundary_budget Host.hard_limits) value)

let hash_json hash = `String (Hash.to_hex hash)

let operation_json ~effect_identity ~mode ~operation =
  `Assoc
    [
      ("effect", hash_json effect_identity);
      ("mode", `String mode);
      ("operation", hash_json operation);
    ]

let invoke_json ~target ~parameters ~effects ~result ~arguments ~operations =
  `Assoc
    [
      ("arguments", `List (List.map encode_value arguments));
      ( "capabilities",
        `Assoc [ ("effects", `List (List.map hash_json effects)); ("operations", `List operations) ]
      );
      ( "interface",
        `Assoc
          [
            ("effects", `List (List.map hash_json effects));
            ("parameters", `List (List.map encode_type parameters));
            ("result", encode_type result);
          ] );
      ("invocation_id", `String "0000000000000000");
      ("kind", `String "invoke");
      ("protocol", `String Host.protocol);
      ("target", `Assoc [ ("callable", hash_json target); ("kind", `String "store-term-v0") ]);
    ]

let pure_arguments fixture =
  [
    Value.VCon
      {
        con = fixture.packet_constructor;
        name = "display-name-does-not-cross";
        args = [ Value.VInt 7; Value.VText "payload" ];
      };
    Value.VTuple [ Value.VText "metadata"; Value.VHash (Hash.of_string "metadata") ];
  ]

let pure_invoke fixture =
  invoke_json ~target:fixture.pure_target
    ~parameters:[ packet_int fixture; metadata_type fixture ]
    ~effects:[] ~result:(text_type fixture) ~arguments:(pure_arguments fixture) ~operations:[]

let effectful_invoke ?(operations = []) fixture =
  invoke_json ~target:fixture.effectful_target
    ~parameters:[ int_type fixture; text_type fixture ]
    ~effects:[ fixture.world_effect ] ~result:(text_type fixture)
    ~arguments:[ Value.VInt 2; Value.VText "body" ]
    ~operations

let replace_field name replacement = function
  | `Assoc fields ->
      `Assoc
        (List.map
           (fun (candidate, value) ->
             if String.equal candidate name then (candidate, replacement) else (candidate, value))
           fields)
  | _ -> Alcotest.failf "cannot replace %s on a non-object test fixture" name

let update_field name update = function
  | `Assoc fields ->
      `Assoc
        (List.map
           (fun (candidate, value) ->
             if String.equal candidate name then (candidate, update value) else (candidate, value))
           fields)
  | _ -> Alcotest.failf "cannot update %s on a non-object test fixture" name

let append_field name value = function
  | `Assoc fields -> `Assoc ((name, value) :: fields)
  | _ -> Alcotest.failf "cannot append %s to a non-object test fixture" name

let parse ?(limits = Host.hard_limits) fixture json =
  Host.parse_invoke ~limits ~checker:fixture.checker json

let test_pure_target_and_typed_composites_succeed () =
  let fixture = Lazy.force fixture in
  let invocation = expect_ok "pure invoke preflight" (parse fixture (pure_invoke fixture)) in
  Alcotest.(check string)
    "exact target" (Hash.to_hex fixture.pure_target)
    (Hash.to_hex invocation.Host.callable);
  Alcotest.(check int) "two decoded arguments" 2 (List.length invocation.Host.arguments);
  Alcotest.(check int) "pure effect set" 0 (List.length invocation.Host.effects);
  Alcotest.(check int) "empty operation registry" 0 (List.length invocation.Host.operations)

let test_effectful_target_accepts_partial_or_exact_registry_without_running () =
  let fixture = Lazy.force fixture in
  let partial = expect_ok "partial registry" (parse fixture (effectful_invoke fixture)) in
  Alcotest.(check int) "partial registry remains empty" 0 (List.length partial.Host.operations);
  let entry =
    operation_json ~effect_identity:fixture.world_effect ~mode:"once"
      ~operation:fixture.send_operation
  in
  let exact =
    expect_ok "exact operation registry"
      (parse fixture (effectful_invoke ~operations:[ entry ] fixture))
  in
  match exact.Host.operations with
  | [ operation ] ->
      Alcotest.(check string)
        "operation identity"
        (Hash.to_hex fixture.send_operation)
        (Hash.to_hex operation.Host.operation);
      Alcotest.(check int) "operation parameter count" 2 (List.length operation.Host.parameters)
  | operations -> Alcotest.failf "expected one operation, got %d" (List.length operations)

let test_envelope_version_state_and_id_fail_closed () =
  let fixture = Lazy.force fixture in
  let valid = pure_invoke fixture in
  let target_with callable = update_field "target" (replace_field "callable" callable) valid in
  let cases =
    [
      ("unknown outer field", append_field "extra" `Null valid, "E1601");
      ("unsupported protocol", replace_field "protocol" (`String "future") valid, "E1600");
      ("wrong state kind", replace_field "kind" (`String "shutdown") valid, "E1608");
      ( "wrong invocation id",
        replace_field "invocation_id" (`String "0000000000000001") valid,
        "E1608" );
      ( "malformed target identity",
        target_with (`String (String.uppercase_ascii (Hash.to_hex fixture.pure_target))),
        "E1601" );
    ]
  in
  List.iter (fun (label, json, code) -> expect_code label code (parse fixture json)) cases

let test_target_role_callable_and_boundary_shape_fail_closed () =
  let fixture = Lazy.force fixture in
  let valid = pure_invoke fixture in
  let with_target target =
    update_field "target" (replace_field "callable" (hash_json target)) valid
  in
  let cases =
    [
      ("missing target", with_target (Hash.of_string "missing-target"), "E1603");
      ("constructor target", with_target fixture.packet_constructor, "E1603");
      ("non-callable term", with_target fixture.constant_target, "E1603");
      ("polymorphic term", with_target fixture.polymorphic_target, "E1603");
      ("open-row term", with_target fixture.open_row_target, "E1603");
      ("nested-arrow boundary", with_target fixture.higher_order_target, "E1604");
    ]
  in
  List.iter (fun (label, json, code) -> expect_code label code (parse fixture json)) cases

let missing_closure_case () =
  let store = expect_ok "open incomplete store" (Store.open_store (fresh_dir "closure")) in
  seed_primitives store;
  let dependency =
    put_src store
      "(defterm ((binding boundary.dependency ((tarrow () (row) (tref text))) (lam () (lit \
       \"dependency\")))))"
  in
  let target =
    put_src store
      "(defterm ((binding boundary.dependent ((tarrow () (row) (tref text))) (lam () (app (var \
       boundary.dependency))))))"
  in
  let checker = expect_ok "create incomplete-store checker" (Check.make_ctx store) in
  Sys.remove (Store.object_path store dependency.Canon.decl_hash);
  (checker, named "boundary.dependent" target, required_hash store "text" Resolve.KType)

let test_complete_reachable_store_closure_is_required () =
  let checker, target, text = missing_closure_case () in
  let json =
    invoke_json ~target ~parameters:[] ~effects:[] ~result:(nominal text []) ~arguments:[]
      ~operations:[]
  in
  expect_code "missing reachable object" "E1603"
    (Host.parse_invoke ~limits:Host.hard_limits ~checker json)

let test_interface_and_argument_count_must_equal_checked_arrow () =
  let fixture = Lazy.force fixture in
  let valid = pure_invoke fixture in
  let cases =
    [
      ( "parameter order",
        update_field "interface"
          (replace_field "parameters"
             (`List [ encode_type (metadata_type fixture); encode_type (packet_int fixture) ]))
          valid );
      ( "result type",
        update_field "interface" (replace_field "result" (encode_type (int_type fixture))) valid );
      ( "interface effects",
        update_field "interface"
          (replace_field "effects" (`List [ hash_json fixture.world_effect ]))
          valid );
      ( "argument count",
        replace_field "arguments" (`List [ encode_value (List.hd (pure_arguments fixture)) ]) valid
      );
    ]
  in
  List.iter (fun (label, json) -> expect_code label "E1603" (parse fixture json)) cases

let test_scalar_tuple_and_generic_constructor_fields_are_typed () =
  let fixture = Lazy.force fixture in
  let valid = pure_invoke fixture in
  let wrong_packet =
    Value.VCon
      {
        con = fixture.packet_constructor;
        name = "ignored";
        args = [ Value.VText "not-an-int"; Value.VText "payload" ];
      }
  in
  let wrong_tuple = Value.VTuple [ Value.VInt 1; Value.VHash (Hash.of_string "metadata") ] in
  let replace_arguments arguments = replace_field "arguments" (`List arguments) valid in
  expect_code "generic constructor field" "E1603"
    (parse fixture
       (replace_arguments
          [ encode_value wrong_packet; encode_value (List.nth (pure_arguments fixture) 1) ]));
  expect_code "tuple item" "E1603"
    (parse fixture
       (replace_arguments
          [ encode_value (List.hd (pure_arguments fixture)); encode_value wrong_tuple ]));
  expect_code "unsupported value descriptor" "E1604"
    (parse fixture
       (replace_arguments
          [
            `Assoc [ ("kind", `String "secret"); ("value", `String "opaque") ];
            encode_value (List.nth (pure_arguments fixture) 1);
          ]));
  let wrong_constructor =
    `Assoc
      [
        ("arguments", `List []);
        ("identity", hash_json fixture.text_type);
        ("kind", `String "constructor");
      ]
  in
  expect_code "non-constructor identity" "E1603"
    (parse fixture
       (replace_arguments [ wrong_constructor; encode_value (List.nth (pure_arguments fixture) 1) ]))

let test_selected_argument_effect_operation_and_node_limits_are_aggregate () =
  let fixture = Lazy.force fixture in
  expect_code "parameter count limit" "E1602"
    (parse ~limits:{ Host.hard_limits with max_arguments = 1 } fixture (pure_invoke fixture));
  let duplicate_effects =
    `List [ hash_json fixture.world_effect; hash_json fixture.world_effect ]
  in
  let too_many_effects =
    effectful_invoke fixture
    |> update_field "interface" (replace_field "effects" duplicate_effects)
    |> update_field "capabilities" (replace_field "effects" duplicate_effects)
  in
  expect_code "effect count limit" "E1602"
    (parse ~limits:{ Host.hard_limits with max_effects = 1 } fixture too_many_effects);
  let entry =
    operation_json ~effect_identity:fixture.world_effect ~mode:"once"
      ~operation:fixture.send_operation
  in
  expect_code "operation count limit" "E1602"
    (parse
       ~limits:{ Host.hard_limits with max_operations = 1 }
       fixture
       (effectful_invoke ~operations:[ entry; entry ] fixture));
  expect_code "shared type/value node budget" "E1602"
    (parse ~limits:{ Host.hard_limits with max_value_nodes = 4 } fixture (pure_invoke fixture))

let test_capabilities_and_registry_are_exact_closed_and_once () =
  let fixture = Lazy.force fixture in
  let valid = effectful_invoke fixture in
  let capability_effects effects =
    update_field "capabilities" (replace_field "effects" (`List (List.map hash_json effects))) valid
  in
  expect_code "missing capability effect" "E1605" (parse fixture (capability_effects []));
  expect_code "duplicate capability effect" "E1605"
    (parse fixture (capability_effects [ fixture.world_effect; fixture.world_effect ]));
  let with_operations operations =
    update_field "capabilities" (replace_field "operations" (`List operations)) valid
  in
  let send =
    operation_json ~effect_identity:fixture.world_effect ~mode:"once"
      ~operation:fixture.send_operation
  in
  let log =
    operation_json ~effect_identity:fixture.world_effect ~mode:"once"
      ~operation:fixture.log_operation
  in
  let unsorted =
    if Hash.compare fixture.send_operation fixture.log_operation < 0 then [ log; send ]
    else [ send; log ]
  in
  let cases =
    [
      ("duplicate operation", [ send; send ]);
      ("unsorted operation", unsorted);
      ( "wrong operation owner",
        [
          operation_json ~effect_identity:fixture.world_effect ~mode:"once"
            ~operation:fixture.generic_operation;
        ] );
      ( "multi declaration",
        [
          operation_json ~effect_identity:fixture.world_effect ~mode:"multi"
            ~operation:fixture.peek_operation;
        ] );
      ( "declared mode disagreement",
        [
          operation_json ~effect_identity:fixture.world_effect ~mode:"once"
            ~operation:fixture.peek_operation;
        ] );
      ( "payload mode disagreement",
        [
          operation_json ~effect_identity:fixture.world_effect ~mode:"multi"
            ~operation:fixture.send_operation;
        ] );
      ( "unresolved operation",
        [
          operation_json ~effect_identity:fixture.world_effect ~mode:"once"
            ~operation:(Hash.of_string "missing-operation");
        ] );
    ]
  in
  List.iter
    (fun (label, operations) ->
      expect_code label "E1605" (parse fixture (with_operations operations)))
    cases;
  let callback =
    operation_json ~effect_identity:fixture.world_effect ~mode:"once"
      ~operation:fixture.callback_operation
  in
  expect_code "nested callable operation signature" "E1604"
    (parse fixture (with_operations [ callback ]));
  let pure_with_ungranted_operation =
    pure_invoke fixture |> update_field "capabilities" (replace_field "operations" (`List [ send ]))
  in
  expect_code "operation cannot introduce an ungranted effect" "E1605"
    (parse fixture pure_with_ungranted_operation)

let test_generic_operation_signature_is_not_a_boundary_contract () =
  let fixture = Lazy.force fixture in
  let entry =
    operation_json ~effect_identity:fixture.generic_effect ~mode:"once"
      ~operation:fixture.generic_operation
  in
  let json =
    invoke_json ~target:fixture.generic_target
      ~parameters:[ int_type fixture ]
      ~effects:[ fixture.generic_effect ] ~result:(int_type fixture) ~arguments:[ Value.VInt 1 ]
      ~operations:[ entry ]
  in
  expect_code "generic operation signature" "E1604" (parse fixture json)

let test_fail_fast_precedence_does_not_trust_later_material () =
  let fixture = Lazy.force fixture in
  let invalid_target =
    pure_invoke fixture
    |> update_field "target"
         (replace_field "callable" (hash_json (Hash.of_string "missing-target")))
    |> update_field "capabilities"
         (replace_field "effects" (`List [ hash_json fixture.world_effect ]))
  in
  expect_code "protocol precedes target" "E1600"
    (parse fixture (replace_field "protocol" (`String "future") invalid_target));
  expect_code "target precedes capabilities" "E1603" (parse fixture invalid_target);
  let wrong_argument_and_capability =
    effectful_invoke fixture
    |> replace_field "arguments"
         (`List [ encode_value (Value.VText "wrong"); encode_value (Value.VText "body") ])
    |> update_field "capabilities" (replace_field "effects" (`List []))
  in
  expect_code "argument typing precedes capabilities" "E1603"
    (parse fixture wrong_argument_and_capability);
  let malformed_and_future =
    pure_invoke fixture |> replace_field "protocol" (`String "future") |> append_field "extra" `Null
  in
  expect_code "shape precedes protocol" "E1601" (parse fixture malformed_and_future)

let suite =
  [
    Alcotest.test_case "pure target and typed composites succeed" `Quick
      test_pure_target_and_typed_composites_succeed;
    Alcotest.test_case "effectful preflight accepts partial registry without running" `Quick
      test_effectful_target_accepts_partial_or_exact_registry_without_running;
    Alcotest.test_case "invoke envelope, version, state, and ID fail closed" `Quick
      test_envelope_version_state_and_id_fail_closed;
    Alcotest.test_case "target role, callable, and boundary shape fail closed" `Quick
      test_target_role_callable_and_boundary_shape_fail_closed;
    Alcotest.test_case "complete reachable store closure is required" `Quick
      test_complete_reachable_store_closure_is_required;
    Alcotest.test_case "interface and argument count equal the checked arrow" `Quick
      test_interface_and_argument_count_must_equal_checked_arrow;
    Alcotest.test_case "scalar, tuple, and generic constructor fields are typed" `Quick
      test_scalar_tuple_and_generic_constructor_fields_are_typed;
    Alcotest.test_case "selected invoke limits are aggregate" `Quick
      test_selected_argument_effect_operation_and_node_limits_are_aggregate;
    Alcotest.test_case "capabilities and registry are exact, closed, and once" `Quick
      test_capabilities_and_registry_are_exact_closed_and_once;
    Alcotest.test_case "generic operation signatures stay outside v0" `Quick
      test_generic_operation_signature_is_not_a_boundary_contract;
    Alcotest.test_case "fail-fast precedence rejects untrusted later material" `Quick
      test_fail_fast_precedence_does_not_trust_later_material;
  ]
