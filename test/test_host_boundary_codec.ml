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

let json = Alcotest.testable Yojson.Safe.pretty_print Yojson.Safe.equal
let hash seed = Hash.of_string seed
let canonical seed = hash seed |> Hash.to_hex
let budget ?(limits = Host.hard_limits) () = Host.create_boundary_budget limits
let constructor_info _ = Ok ("decoded-constructor", 0)

let decode_type ?limits value =
  expect_ok "decode type" (Host.decode_boundary_type ~budget:(budget ?limits ()) value)

let encode_type ?limits value =
  expect_ok "encode type" (Host.encode_boundary_type ~budget:(budget ?limits ()) value)

let decode_value ?limits ?(resolve = constructor_info) value =
  expect_ok "decode value"
    (Host.decode_boundary_value ~budget:(budget ?limits ()) ~constructor_info:resolve value)

let encode_value ?limits value =
  expect_ok "encode value" (Host.encode_boundary_value ~budget:(budget ?limits ()) value)

let test_type_variants_are_exact () =
  let identity = canonical "boundary-nominal" in
  let descriptor =
    `Assoc
      [
        ("arguments", `List [ `Assoc [ ("items", `List []); ("kind", `String "tuple") ] ]);
        ("identity", `String identity);
        ("kind", `String "nominal");
      ]
  in
  let decoded = decode_type descriptor in
  (match Types.repr decoded with
  | Types.TCon (actual, [ Types.TTuple [] ]) ->
      Alcotest.(check string) "nominal identity" identity (Hash.to_hex actual)
  | _ -> Alcotest.fail "nominal descriptor decoded to the wrong Core type");
  Alcotest.check json "deterministic type encoding" descriptor (encode_type decoded);
  let tuple = Types.TTuple [ Types.TCon (hash "left", []); Types.TTuple [] ] in
  let encoded = encode_type tuple in
  let reencoded = encoded |> decode_type |> encode_type in
  Alcotest.check json "nested tuple round-trip" encoded reencoded

let test_type_shape_and_identity_fail_closed () =
  let identity = canonical "type-shape" in
  let cases =
    [
      ("type is not an object", `List [], "E1601");
      ("kind is missing", `Assoc [ ("items", `List []) ], "E1601");
      ("kind is not text", `Assoc [ ("items", `List []); ("kind", `Int 1) ], "E1601");
      ("unknown type kind", `Assoc [ ("kind", `String "arrow") ], "E1604");
      ( "missing nominal arguments",
        `Assoc [ ("identity", `String identity); ("kind", `String "nominal") ],
        "E1601" );
      ( "extra tuple field",
        `Assoc [ ("extra", `Null); ("items", `List []); ("kind", `String "tuple") ],
        "E1601" );
      ( "uppercase type identity",
        `Assoc
          [
            ("arguments", `List []);
            ("identity", `String (String.uppercase_ascii identity));
            ("kind", `String "nominal");
          ],
        "E1601" );
      ( "type arguments are not an array",
        `Assoc [ ("arguments", `Null); ("identity", `String identity); ("kind", `String "nominal") ],
        "E1601" );
    ]
  in
  List.iter
    (fun (label, descriptor, code) ->
      expect_code label code (Host.decode_boundary_type ~budget:(budget ()) descriptor))
    cases

let test_non_boundary_core_types_fail_e1604 () =
  let unit = Types.TTuple [] in
  let unsupported =
    [
      ("arrow", Types.TArrow ([], Types.empty_row, unit));
      ("resume", Types.TResume (unit, Types.empty_row, unit));
      ("variadic arrow", Types.TVariadicArrow (unit, Types.empty_row, unit));
      ("exact thunk", Types.TExactThunk unit);
      ("unresolved variable", Types.new_tvar 0);
      ("skolem", Types.TSkolem (42, "a"));
    ]
  in
  List.iter
    (fun (label, ty) ->
      expect_code label "E1604" (Host.encode_boundary_type ~budget:(budget ()) ty))
    unsupported

let type_json_gen =
  let open QCheck.Gen in
  let identity = canonical "property-type" in
  let rec go depth =
    let nominal arguments =
      `Assoc
        [
          ("arguments", `List arguments); ("identity", `String identity); ("kind", `String "nominal");
        ]
    in
    let tuple items = `Assoc [ ("items", `List items); ("kind", `String "tuple") ] in
    if depth = 0 then oneof [ return (nominal []); return (tuple []) ]
    else
      oneof_weighted
        [
          (2, return (nominal []));
          (2, return (tuple []));
          (1, map nominal (list_size (int_bound 3) (go (depth - 1))));
          (1, map tuple (list_size (int_bound 3) (go (depth - 1))));
        ]
  in
  go 4

let prop_type_codec_round_trip =
  QCheck.Test.make ~count:300 ~name:"boundary type codec round-trips canonical descriptors"
    QCheck.(make type_json_gen)
    (fun descriptor ->
      match Host.decode_boundary_type ~budget:(budget ()) descriptor with
      | Error _ -> false
      | Ok ty -> (
          match Host.encode_boundary_type ~budget:(budget ()) ty with
          | Ok encoded -> Yojson.Safe.equal descriptor encoded
          | Error _ -> false))

let test_scalar_value_variants_are_lossless () =
  let value_hash = hash "opaque-boundary-hash" in
  let cases =
    [
      (Value.VInt (-12), `Assoc [ ("kind", `String "int"); ("value", `String "-12") ]);
      ( Value.VReal (Int64.float_of_bits 0x8000_0000_0000_0000L),
        `Assoc [ ("bits", `String "8000000000000000"); ("kind", `String "real") ] );
      (Value.VText "hello 😀", `Assoc [ ("kind", `String "text"); ("value", `String "hello 😀") ]);
      ( Value.VHash value_hash,
        `Assoc [ ("kind", `String "hash"); ("value", `String (Hash.to_hex value_hash)) ] );
    ]
  in
  List.iter
    (fun (value, expected) ->
      let encoded = encode_value value in
      Alcotest.check json "exact scalar encoding" expected encoded;
      Alcotest.check json "scalar decode/encode" expected (encoded |> decode_value |> encode_value))
    cases

let test_int_canonical_range () =
  let min_text = "-4611686018427387904" and max_text = "4611686018427387903" in
  List.iter
    (fun spelling ->
      let value = `Assoc [ ("kind", `String "int"); ("value", `String spelling) ] in
      let decoded = decode_value value in
      Alcotest.check json ("canonical " ^ spelling) value (encode_value decoded))
    [ min_text; "-1"; "0"; "1"; max_text ];
  List.iter
    (fun spelling ->
      expect_code ("noncanonical " ^ spelling) "E1601"
        (Host.decode_boundary_value ~budget:(budget ()) ~constructor_info
           (`Assoc [ ("kind", `String "int"); ("value", `String spelling) ])))
    [ "+1"; "00"; "01"; "-0"; " 1"; "4611686018427387904"; "-4611686018427387905" ]

let test_real_bits_preserve_special_values () =
  let bit_patterns =
    [
      "0000000000000000";
      "8000000000000000";
      "7ff0000000000000";
      "fff0000000000000";
      "7ff8000000000042";
      "ffffffffffffffff";
    ]
  in
  List.iter
    (fun bits ->
      let descriptor = `Assoc [ ("bits", `String bits); ("kind", `String "real") ] in
      Alcotest.check json bits descriptor (descriptor |> decode_value |> encode_value))
    bit_patterns;
  List.iter
    (fun bits ->
      expect_code ("invalid real bits " ^ bits) "E1601"
        (Host.decode_boundary_value ~budget:(budget ()) ~constructor_info
           (`Assoc [ ("bits", `String bits); ("kind", `String "real") ])))
    [ "0"; "7FF8000000000042"; "gggggggggggggggg"; "00000000000000000" ]

let test_tuple_and_constructor_values_are_exact () =
  let con = hash "boundary-constructor" in
  let descriptor =
    `Assoc
      [
        ( "arguments",
          `List
            [
              `Assoc [ ("kind", `String "int"); ("value", `String "7") ];
              `Assoc [ ("items", `List []); ("kind", `String "tuple") ];
            ] );
        ("identity", `String (Hash.to_hex con));
        ("kind", `String "constructor");
      ]
  in
  let resolved = ref None in
  let constructor_info identity =
    resolved := Some identity;
    Ok ("pair", 2)
  in
  let decoded = decode_value ~resolve:constructor_info descriptor in
  (match decoded with
  | Value.VCon { con = actual; name; args = [ Value.VInt 7; Value.VTuple [] ] } ->
      Alcotest.(check bool) "constructor identity" true (Hash.equal con actual);
      Alcotest.(check string) "resolved display name" "pair" name
  | _ -> Alcotest.fail "constructor descriptor decoded to the wrong Core value");
  Alcotest.(check bool)
    "resolver saw exact identity" true
    (Option.fold ~none:false ~some:(Hash.equal con) !resolved);
  Alcotest.check json "display name stays off the wire" descriptor (encode_value decoded);
  expect_code "constructor must be saturated" "E1604"
    (Host.decode_boundary_value ~budget:(budget ())
       ~constructor_info:(fun _ -> Ok ("triple", 3))
       descriptor);
  let unresolved =
    Diag.error ~domain:Process ~code:"E1603" ~summary:"The constructor is unresolved."
      ~cause:"The exact constructor identity is absent from the selected store."
      ~next_step:"Install the complete checked store closure." ~contrast:None ()
  in
  expect_code "constructor resolver diagnostic is preserved" "E1603"
    (Host.decode_boundary_value ~budget:(budget ())
       ~constructor_info:(fun _ -> Error [ unresolved ])
       descriptor);
  let tuple = Value.VTuple [ Value.VInt 1; decoded ] in
  let encoded = encode_value tuple in
  Alcotest.check json "nested value round-trip" encoded
    (encoded |> decode_value ~resolve:constructor_info |> encode_value)

let test_value_shape_and_unknown_kinds_fail_closed () =
  let identity = canonical "value-shape" in
  let cases =
    [
      ("value is not an object", `String "1", "E1601");
      ("kind is missing", `Assoc [ ("value", `String "1") ], "E1601");
      ("kind is not text", `Assoc [ ("kind", `Int 1); ("value", `String "1") ], "E1601");
      ( "unsupported secret kind",
        `Assoc [ ("kind", `String "secret"); ("value", `String "must-not-cross") ],
        "E1604" );
      ( "extra int field",
        `Assoc [ ("extra", `Null); ("kind", `String "int"); ("value", `String "1") ],
        "E1601" );
      ("int scalar is not text", `Assoc [ ("kind", `String "int"); ("value", `Int 1) ], "E1601");
      ( "uppercase hash value",
        `Assoc [ ("kind", `String "hash"); ("value", `String (String.uppercase_ascii identity)) ],
        "E1601" );
      ( "missing constructor arguments",
        `Assoc [ ("identity", `String identity); ("kind", `String "constructor") ],
        "E1601" );
    ]
  in
  List.iter
    (fun (label, descriptor, code) ->
      expect_code label code
        (Host.decode_boundary_value ~budget:(budget ()) ~constructor_info descriptor))
    cases

let test_non_boundary_runtime_values_fail_e1604 () =
  let unsupported =
    [
      ("secret", Value.VSecret (Secret.of_string "private"));
      ( "unapplied constructor",
        Value.VConstructor { con = hash "constructor"; name = "constructor"; arity = 1 } );
      ("operation", Value.VOp { op = hash "operation"; name = "operation"; effect_ = "effect" });
      ("untrusted builtin", Value.VBuiltin ("callback", fun _ -> Ok Value.unit_v));
      ("code", Value.VCode (Form.form "lit" [ Form.Int 1 ]));
      ("resumption", Value.VResume []);
    ]
  in
  List.iter
    (fun (label, value) ->
      expect_code label "E1604" (Host.encode_boundary_value ~budget:(budget ()) value))
    unsupported

let test_text_utf8_normalization_and_limit () =
  let composed = "é" and decomposed = "e\204\129" in
  let composed_json = encode_value (Value.VText composed) in
  let decomposed_json = encode_value (Value.VText decomposed) in
  Alcotest.(check bool)
    "normalization is not performed" false
    (Yojson.Safe.equal composed_json decomposed_json);
  Alcotest.(check string)
    "decomposed bytes survive" decomposed
    (match decode_value decomposed_json with Value.VText text -> text | _ -> "");
  let two_bytes = { Host.hard_limits with max_text_bytes = 2 } in
  ignore
    (decode_value ~limits:two_bytes (`Assoc [ ("kind", `String "text"); ("value", `String "é") ]));
  expect_code "text bytes exceed selected limit" "E1602"
    (Host.decode_boundary_value
       ~budget:(budget ~limits:{ Host.hard_limits with max_text_bytes = 1 } ())
       ~constructor_info
       (`Assoc [ ("kind", `String "text"); ("value", `String "é") ]));
  expect_code "encoded text bytes exceed selected limit" "E1602"
    (Host.encode_boundary_value
       ~budget:(budget ~limits:{ Host.hard_limits with max_text_bytes = 1 } ())
       (Value.VText "é"));
  let invalid = String.make 1 (Char.chr 0x80) in
  expect_code "decoded text is invalid UTF-8" "E1601"
    (Host.decode_boundary_value ~budget:(budget ()) ~constructor_info
       (`Assoc [ ("kind", `String "text"); ("value", `String invalid) ]));
  expect_code "encoded text is invalid UTF-8" "E1601"
    (Host.encode_boundary_value ~budget:(budget ()) (Value.VText invalid))

let test_shared_node_budget_is_aggregate () =
  let limits = { Host.hard_limits with max_value_nodes = 2 } in
  let shared = budget ~limits () in
  ignore
    (expect_ok "first shared node"
       (Host.decode_boundary_type ~budget:shared
          (`Assoc [ ("items", `List []); ("kind", `String "tuple") ])));
  ignore
    (expect_ok "second shared node"
       (Host.decode_boundary_value ~budget:shared ~constructor_info
          (`Assoc [ ("kind", `String "int"); ("value", `String "1") ])));
  expect_code "third shared node" "E1602" (Host.encode_boundary_value ~budget:shared (Value.VInt 2));
  let shape_first = budget ~limits:{ limits with max_value_nodes = 1 } () in
  ignore
    (expect_ok "shape-order first node"
       (Host.encode_boundary_value ~budget:shape_first (Value.VInt 1)));
  expect_code "exact shape precedes exhausted node budget" "E1601"
    (Host.decode_boundary_value ~budget:shape_first ~constructor_info
       (`Assoc [ ("extra", `Null); ("kind", `String "int"); ("value", `String "2") ]));
  let nested = budget ~limits () in
  expect_code "nested value exhausts one frame budget" "E1602"
    (Host.encode_boundary_value ~budget:nested (Value.VTuple [ Value.VTuple [ Value.VInt 1 ] ]))

let test_collection_argument_and_depth_limits () =
  let one_collection = { Host.hard_limits with max_collection_items = 1 } in
  ignore (encode_value ~limits:one_collection (Value.VTuple [ Value.VInt 1 ]));
  expect_code "tuple collection limit" "E1602"
    (Host.encode_boundary_value
       ~budget:(budget ~limits:one_collection ())
       (Value.VTuple [ Value.VInt 1; Value.VInt 2 ]));
  expect_code "decoded tuple collection limit" "E1602"
    (Host.decode_boundary_value
       ~budget:(budget ~limits:one_collection ())
       ~constructor_info
       (`Assoc
          [
            ( "items",
              `List
                [
                  `Assoc [ ("kind", `String "int"); ("value", `String "1") ];
                  `Assoc [ ("kind", `String "int"); ("value", `String "2") ];
                ] );
            ("kind", `String "tuple");
          ]));
  expect_code "type collection limit" "E1602"
    (Host.encode_boundary_type
       ~budget:(budget ~limits:one_collection ())
       (Types.TTuple [ Types.TTuple []; Types.TTuple [] ]));
  let one_argument = { Host.hard_limits with max_arguments = 1 } in
  let constructor =
    Value.VCon
      { con = hash "arity-two"; name = "display-only"; args = [ Value.VInt 1; Value.VInt 2 ] }
  in
  expect_code "constructor argument limit" "E1602"
    (Host.encode_boundary_value ~budget:(budget ~limits:one_argument ()) constructor);
  expect_code "decoded constructor argument limit" "E1602"
    (Host.decode_boundary_value ~budget:(budget ~limits:one_argument ())
       ~constructor_info:(fun _ -> Ok ("arity-two", 2))
       (encode_value constructor));
  let nested = Value.VTuple [ Value.VTuple [] ] in
  ignore (encode_value ~limits:{ Host.hard_limits with max_json_depth = 4 } nested);
  expect_code "boundary JSON depth" "E1602"
    (Host.encode_boundary_value
       ~budget:(budget ~limits:{ Host.hard_limits with max_json_depth = 3 } ())
       nested);
  expect_code "decoded boundary JSON depth" "E1602"
    (Host.decode_boundary_value
       ~budget:(budget ~limits:{ Host.hard_limits with max_json_depth = 3 } ())
       ~constructor_info (encode_value nested))

let value_json_gen =
  let open QCheck.Gen in
  let value_hash = canonical "property-value" in
  let rec go depth =
    let leaf =
      oneof
        [
          map
            (fun value ->
              `Assoc [ ("kind", `String "int"); ("value", `String (string_of_int value)) ])
            (int_range (-1_000_000) 1_000_000);
          map
            (fun value -> `Assoc [ ("kind", `String "text"); ("value", `String value) ])
            (string_size ~gen:printable (int_bound 24));
          return (`Assoc [ ("kind", `String "hash"); ("value", `String value_hash) ]);
        ]
    in
    if depth = 0 then leaf
    else
      oneof_weighted
        [
          (5, leaf);
          ( 1,
            map
              (fun items -> `Assoc [ ("items", `List items); ("kind", `String "tuple") ])
              (list_size (int_bound 3) (go (depth - 1))) );
        ]
  in
  go 4

let prop_value_codec_round_trip =
  QCheck.Test.make ~count:300 ~name:"boundary value codec round-trips canonical descriptors"
    QCheck.(make value_json_gen)
    (fun descriptor ->
      match Host.decode_boundary_value ~budget:(budget ()) ~constructor_info descriptor with
      | Error _ -> false
      | Ok value -> (
          match Host.encode_boundary_value ~budget:(budget ()) value with
          | Ok encoded -> Yojson.Safe.equal descriptor encoded
          | Error _ -> false))

let suite =
  [
    Alcotest.test_case "nominal and tuple types are exact" `Quick test_type_variants_are_exact;
    Alcotest.test_case "type shape and identity fail closed" `Quick
      test_type_shape_and_identity_fail_closed;
    Alcotest.test_case "non-boundary Core types fail E1604" `Quick
      test_non_boundary_core_types_fail_e1604;
    QCheck_alcotest.to_alcotest prop_type_codec_round_trip;
    Alcotest.test_case "scalar values are lossless" `Quick test_scalar_value_variants_are_lossless;
    Alcotest.test_case "integer text is canonical and bounded" `Quick test_int_canonical_range;
    Alcotest.test_case "real bits preserve special values" `Quick
      test_real_bits_preserve_special_values;
    Alcotest.test_case "tuple and constructor values are exact" `Quick
      test_tuple_and_constructor_values_are_exact;
    Alcotest.test_case "value shapes and unknown kinds fail closed" `Quick
      test_value_shape_and_unknown_kinds_fail_closed;
    Alcotest.test_case "opaque and callable values fail E1604" `Quick
      test_non_boundary_runtime_values_fail_e1604;
    Alcotest.test_case "Text preserves UTF-8 bytes within limits" `Quick
      test_text_utf8_normalization_and_limit;
    Alcotest.test_case "node budget is aggregate across one frame" `Quick
      test_shared_node_budget_is_aggregate;
    Alcotest.test_case "collection, argument, and depth limits" `Quick
      test_collection_argument_and_depth_limits;
    QCheck_alcotest.to_alcotest prop_value_codec_round_trip;
  ]
