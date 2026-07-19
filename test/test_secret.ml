open Jacquard

let store, ctx = Eval_support.make_prelude_ctx ()
let fixture = "ET4-fixture-secret:\000\nnot-a-log-line"

let contains haystack needle =
  let n = String.length needle and m = String.length haystack in
  let rec go index = index + n <= m && (String.sub haystack index n = needle || go (index + 1)) in
  go 0

let fail_diags what diagnostics = Eval_support.fail_diags what diagnostics

let install_provider () =
  match
    Prelude.install_secret ctx ~read:(fun ~name ~version ->
        if name = "fixture" && version = Some "v1" then Ok fixture
        else Error Prelude.Secret_reference_missing)
  with
  | Ok () -> ()
  | Error diagnostics -> fail_diags "install secret provider" diagnostics

let secret_ref = "(app (var secret-ref) (lit \"fixture\") (app (var some) (lit \"v1\")))"
let read_secret = Printf.sprintf "(app (var secret.read) %s)" secret_ref

let eval source =
  match Eval_support.eval_with ctx store source with
  | Ok value -> value
  | Error error -> Alcotest.failf "secret evaluation failed: %s" (Runtime_err.to_string error)

let check source =
  let checker =
    match Check.make_ctx store with
    | Ok checker -> checker
    | Error diagnostics -> fail_diags "make secret checker" diagnostics
  in
  (match Prelude.builtin_signatures store with
  | Ok signatures -> Check.register_builtin_signatures checker signatures
  | Error diagnostics -> fail_diags "register builtins" diagnostics);
  match Reader.parse_one ~file:"secret-check.jqd" source with
  | Error diagnostics -> Error diagnostics
  | Ok form -> (
      match Kernel.expr_of_form form with
      | Error diagnostics -> Error diagnostics
      | Ok expression -> (
          match Resolve.resolve_expr (Store.names_view store) expression with
          | Error diagnostics -> Error diagnostics
          | Ok expression -> Check.check_top checker (Kernel.Expr expression)))

let test_schema_and_sealed_marker () =
  let find name kind =
    match Store.lookup_kind store name kind with
    | Some { Resolve.hash; _ } -> hash
    | None -> Alcotest.failf "missing Secret schema name %s" name
  in
  let secret_type = find "secret" Resolve.KType in
  let secret_effect = find "secret" Resolve.KEffect in
  ignore (find "secret-ref" Resolve.KType);
  ignore (find "secret-ref" Resolve.KCon);
  ignore (find "secret.read" Resolve.KOp);
  ignore (find "secret.expose" Resolve.KOp);
  Alcotest.(check bool)
    "Fs keeps the legacy bare read spelling" true
    (Store.lookup_kind store "read" Resolve.KOp <> None);
  Alcotest.(check bool)
    "opaque constructor has no public name" true
    (Store.lookup_kind store "secret-opaque" Resolve.KCon = None);
  (match Store.locate store secret_type with
  | Ok { Store.decl = { Kernel.it = Kernel.DefType { cons = [ _ ]; _ }; _ }; decl_hash; _ } -> (
      let marker = Canon.con_hash decl_hash 0 in
      match Store.locate store marker with
      | Error [ diagnostic ] when Diag.code diagnostic = Some "E0601" -> ()
      | Error diagnostics -> fail_diags "locate secret marker" diagnostics
      | Ok _ -> Alcotest.fail "opaque Secret constructor remained addressable")
  | Ok _ -> Alcotest.fail "Secret type has the wrong declaration shape"
  | Error diagnostics -> fail_diags "locate Secret type" diagnostics);
  match Store.locate store secret_effect with
  | Ok { Store.decl = { Kernel.it = Kernel.DefEffect { ops; _ }; _ }; _ } ->
      Alcotest.(check (list string))
        "operation names" [ "read"; "expose" ]
        (List.map (fun (operation : Kernel.opspec) -> operation.op_name) ops);
      Alcotest.(check bool)
        "both operations are once" true
        (List.for_all (fun (operation : Kernel.opspec) -> operation.op_mode = Kernel.Once) ops)
  | Ok _ -> Alcotest.fail "Secret identity did not locate to its effect declaration"
  | Error diagnostics -> fail_diags "locate Secret effect" diagnostics

let test_explicit_exposure_and_generic_redaction () =
  install_provider ();
  Alcotest.(check string) "opaque value show" "<secret redacted>" (Value.show (eval read_secret));
  Alcotest.(check string)
    "debug inspection is fixed redaction" "\"<secret redacted>\""
    (Value.show (eval (Printf.sprintf "(app (var debug.inspect) %s)" read_secret)));
  Alcotest.(check string)
    "only explicit expose returns payload"
    (Value.show (Value.VText fixture))
    (Value.show (eval (Printf.sprintf "(app (var secret.expose) %s)" read_secret)))

let test_diagnostics_never_render_payload () =
  install_provider ();
  let source = Printf.sprintf "(app (var text.concat) %s (lit \"x\"))" read_secret in
  (match Eval_support.eval_with ctx store source with
  | Error error ->
      let rendered = Runtime_err.to_string error in
      Alcotest.(check bool)
        "fixture absent from runtime diagnostic" false (contains rendered fixture);
      Alcotest.(check bool) "redaction marker present" true (contains rendered "<secret redacted>")
  | Ok value -> Alcotest.failf "text serializer accepted %s" (Value.show value));
  (match check source with
  | Error [ diagnostic ] when Diag.code diagnostic = Some "E0819" ->
      Alcotest.(check bool)
        "checker message contains no fixture" false
        (contains (Diag.cause diagnostic) fixture)
  | Error diagnostics -> fail_diags "Secret checker diagnostic" diagnostics
  | Ok _ -> Alcotest.fail "checker allowed Secret at a Text serialization boundary");
  (match check (Printf.sprintf "(app (var debug.inspect) %s)" read_secret) with
  | Error [ diagnostic ] when Diag.code diagnostic = Some "E0819" -> ()
  | Error diagnostics -> fail_diags "Secret inspect diagnostic" diagnostics
  | Ok _ -> Alcotest.fail "checker allowed generic Secret inspection");
  let audit_source = Printf.sprintf "(app (var audit.entry-code) %s)" read_secret in
  (match Eval_support.eval_with ctx store audit_source with
  | Error error ->
      let rendered = Runtime_err.to_string error in
      Alcotest.(check bool) "Audit failure contains no fixture" false (contains rendered fixture);
      Alcotest.(check bool)
        "Audit failure uses redaction" true
        (contains rendered "<secret redacted>")
  | Ok value -> Alcotest.failf "Audit encoder accepted %s" (Value.show value));
  match check audit_source with
  | Error [ diagnostic ] when Diag.code diagnostic = Some "E0801" ->
      Alcotest.(check bool)
        "Audit checker diagnostic contains no fixture" false
        (contains (Diag.cause diagnostic) fixture)
  | Error diagnostics -> fail_diags "Secret Audit diagnostic" diagnostics
  | Ok _ -> Alcotest.fail "checker allowed Secret into Audit encoding"

let prop_show_never_leaks =
  QCheck.Test.make ~count:300 ~name:"arbitrary secret bytes never enter generic rendering"
    QCheck.string (fun payload ->
      let secret = Value.VSecret (Secret.of_string payload) in
      String.equal (Value.show secret) "<secret redacted>"
      && String.equal
           (Value.show (Value.VTuple [ secret; Value.VText "witness" ]))
           "(<secret redacted>, \"witness\")")

let ref_for name version =
  let version =
    match version with
    | None -> "(var none)"
    | Some version -> Printf.sprintf "(app (var some) (lit %S))" version
  in
  Printf.sprintf "(app (var secret-ref) (lit %S) %s)" name version

let read_ref name version = Printf.sprintf "(app (var secret.read) %s)" (ref_for name version)
let expose_ref name version = Printf.sprintf "(app (var secret.expose) %s)" (read_ref name version)

let test_fixed_handler_is_deterministic () =
  let latest = "ET5-fixed-latest-not-for-output" in
  let pinned = "ET5-fixed-v1-not-for-output" in
  let fixtures : Prelude.secret_fixture list =
    [
      { secret_name = "service"; secret_version = None; secret_bytes = latest };
      { secret_name = "service"; secret_version = Some "v1"; secret_bytes = pinned };
    ]
  in
  (match Prelude.install_secret_fixed ctx fixtures with
  | Ok () -> ()
  | Error diagnostics -> fail_diags "install fixed Secret handler" diagnostics);
  let twice =
    Value.show
      (eval (Printf.sprintf "(tuple %s %s)" (read_ref "service" None) (read_ref "service" None)))
  in
  Alcotest.(check string)
    "repeated exact lookup is stable" "(<secret redacted>, <secret redacted>)" twice;
  Alcotest.(check string)
    "version selects exact fixture" (Value.show (Value.VText pinned))
    (Value.show (eval (expose_ref "service" (Some "v1"))));
  let missing source expected =
    match Eval_support.eval_with ctx store source with
    | Error error ->
        let rendered = Runtime_err.to_string error in
        Alcotest.(check string) "sanitized missing lookup" expected rendered;
        Alcotest.(check bool) "latest bytes absent" false (contains rendered latest);
        Alcotest.(check bool) "versioned bytes absent" false (contains rendered pinned)
    | Ok value -> Alcotest.failf "missing fixed Secret returned %s" (Value.show value)
  in
  missing (read_ref "absent" None) "io error: secret reference not found: absent";
  missing (read_ref "service" (Some "v2")) "io error: secret version not found: service@v2"

let test_environment_and_vault_boundaries () =
  let payload = "ET5-adapter-payload-not-for-output" in
  let requested_keys = ref [] in
  let getenv key =
    requested_keys := key :: !requested_keys;
    if String.equal key "JACQUARD_SECRET_V0_617069_VERSION_7632" then Some payload else None
  in
  (match Prelude.install_secret_environment ~getenv ctx with
  | Ok () -> ()
  | Error diagnostics -> fail_diags "install environment Secret handler" diagnostics);
  Alcotest.(check string)
    "environment key is collision-free and versioned" "JACQUARD_SECRET_V0_617069_VERSION_7632"
    (Prelude.secret_environment_key ~name:"api" ~version:(Some "v2"));
  Alcotest.(check string)
    "environment result stays opaque" "<secret redacted>"
    (Value.show (eval (read_ref "api" (Some "v2"))));
  Alcotest.(check (list string))
    "environment lookup records only the safe key"
    [ "JACQUARD_SECRET_V0_617069_VERSION_7632" ]
    (List.rev !requested_keys);
  let calls = ref [] in
  let scripted = ref [ Ok payload; Error Prelude.Secret_backend_failure ] in
  let read ~name ~version =
    calls := (name, version) :: !calls;
    match !scripted with
    | answer :: rest ->
        scripted := rest;
        answer
    | [] -> Error Prelude.Secret_backend_failure
  in
  (match Prelude.install_secret_vault ~read ctx with
  | Ok () -> ()
  | Error diagnostics -> fail_diags "install scripted vault adapter" diagnostics);
  Alcotest.(check string)
    "scripted replay result remains opaque" "<secret redacted>"
    (Value.show (eval (read_ref "vault" (Some "42"))));
  (match Eval_support.eval_with ctx store (read_ref "vault" (Some "42")) with
  | Error error ->
      let rendered = Runtime_err.to_string error in
      Alcotest.(check string)
        "fault is sanitized" "io error: secret backend failure for reference: vault" rendered;
      Alcotest.(check bool) "adapter bytes absent from failure" false (contains rendered payload)
  | Ok value -> Alcotest.failf "faulting vault returned %s" (Value.show value));
  Alcotest.(check int) "recorded two safe calls" 2 (List.length !calls);
  Alcotest.(check bool)
    "record contains only references" true
    (List.for_all (fun (name, version) -> name = "vault" && version = Some "42") !calls)

let suite =
  [
    Alcotest.test_case "schema, once modes, and sealed marker" `Quick test_schema_and_sealed_marker;
    Alcotest.test_case "explicit exposure and generic redaction" `Quick
      test_explicit_exposure_and_generic_redaction;
    Alcotest.test_case "checker and runtime diagnostics redact" `Quick
      test_diagnostics_never_render_payload;
    Alcotest.test_case "fixed handler is deterministic" `Quick test_fixed_handler_is_deterministic;
    Alcotest.test_case "environment and vault adapter boundaries" `Quick
      test_environment_and_vault_boundaries;
    QCheck_alcotest.to_alcotest prop_show_never_leaks;
  ]
