open Jacquard
module S = Governance_source_check

let fail diagnostics = String.concat "\n" (List.map Diag.to_string diagnostics)

let checker store =
  match (Check.make_ctx store, Prelude.builtin_signatures store) with
  | Ok checker, Ok signatures ->
      Check.register_builtin_signatures checker signatures;
      checker
  | Error diagnostics, _ | _, Error diagnostics -> Alcotest.fail (fail diagnostics)

let load path =
  let root = Filename.temp_dir ~perms:0o700 "jacquard-governance-check-test-" ".store" in
  let store =
    match Store.open_store root with
    | Ok store -> store
    | Error diagnostics -> Alcotest.fail (fail diagnostics)
  in
  (match Prelude.load ~dir:"../prelude" store with
  | Ok _ -> ()
  | Error diagnostics -> Alcotest.fail (fail diagnostics));
  let checker = checker store in
  let source = Corpus_support.read_file ("../corpus/governance/" ^ path) in
  let forms =
    match Reader.parse_string ~file:path source with
    | Ok forms -> forms
    | Error diagnostics -> Alcotest.fail (fail diagnostics)
  in
  let declarations =
    List.map
      (fun form ->
        match Kernel.of_form form with
        | Error diagnostics -> Alcotest.fail (fail diagnostics)
        | Ok (Kernel.Expr _) ->
            Alcotest.fail "governance source-check fixture must be declaration-only"
        | Ok (Kernel.Decl declaration) -> (
            match Resolve.resolve_decl (Store.names_view store) declaration with
            | Error diagnostics -> Alcotest.fail (fail diagnostics)
            | Ok declaration -> (
                match Store.put_decl store declaration with
                | Error diagnostics -> Alcotest.fail (fail diagnostics)
                | Ok _ -> (
                    match Check.check_top checker (Kernel.Decl declaration) with
                    | Error diagnostics -> Alcotest.fail (fail diagnostics)
                    | Ok _ -> declaration))))
      forms
  in
  (store, checker, declarations)

let verify path =
  let store, checker, declarations = load path in
  S.verify store checker declarations

let expect_ok path =
  match verify path with
  | Ok report -> report
  | Error diagnostics -> Alcotest.failf "%s unexpectedly failed:\n%s" path (fail diagnostics)

let expect_code path code =
  match verify path with
  | Ok _ -> Alcotest.failf "%s unexpectedly passed" path
  | Error diagnostics ->
      Alcotest.(check bool)
        (path ^ " contains " ^ code)
        true
        (List.exists (fun diagnostic -> Diag.code_or_uncoded diagnostic = code) diagnostics)

let test_exact_layer_counts () =
  Alcotest.(check int)
    "direct dry has no forwarding layers" 0
    (List.length (expect_ok "workspace-check-dry.jqd").layers);
  Alcotest.(check int)
    "zero forward layers" 0
    (List.length (expect_ok "workspace-check-zero-layer.jqd").layers);
  Alcotest.(check int)
    "one forward plus live leaf" 2
    (List.length (expect_ok "workspace-check-v1.jqd").layers);
  Alcotest.(check int)
    "two forwards plus live leaf" 3
    (List.length (expect_ok "workspace-check-two-layer.jqd").layers)

let test_failure_boundaries () =
  expect_code "workspace-check-open-tail.jqd" "E1413";
  expect_code "workspace-check-ambiguous.jqd" "E1413";
  expect_code "workspace-check-inert-reference.jqd" "E1413";
  expect_code "workspace-check-wrong-binder.jqd" "E1413";
  expect_code "workspace-check-extra-boundary.jqd" "E1413";
  expect_code "workspace-check-shadow-live.jqd" "E1400";
  expect_code "workspace-check-eval.jqd" "E1412";
  expect_code "workspace-check-groupref-eval.jqd" "E1412";
  expect_code "workspace-check-raw-fs.jqd" "E1407";
  expect_code "workspace-check-raw-net.jqd" "E1407";
  expect_code "workspace-check-raw-secret.jqd" "E1407";
  expect_code "workspace-check-residual-console.jqd" "E1413";
  expect_code "workspace-check-residual-custom.jqd" "E1413";
  expect_code "workspace-check-control-state.jqd" "E1408";
  expect_code "workspace-check-control-audit.jqd" "E1408";
  expect_code "workspace-check-debug-inspect.jqd" "E1409";
  expect_code "workspace-check-unquote.jqd" "E1412"

let test_report_contract () =
  let report = expect_ok "workspace-check-v1.jqd" in
  let text = S.render_text report in
  let json = S.render_json_v1 report in
  Alcotest.(check string)
    "text report header" "ok governance-check-v1 profile=workspace-v0"
    (List.hd (String.split_on_char '\n' text));
  Alcotest.(check string) "facade name" "Workspace" report.facade.name;
  Alcotest.(check (list string))
    "facade introduced row" [ "Workspace" ] report.facade.introduced_row;
  Alcotest.(check (list string))
    "live introduced row"
    [ "Audit"; "GovernanceApprovalV1"; "Secret"; "Fs"; "Judge"; "Net" ]
    report.live.introduced_row;
  Alcotest.(check (list string)) "dry introduced row" [ "Audit"; "Judge" ] report.dry.introduced_row;
  Alcotest.(check (list string))
    "one forward and one leaf"
    [ "workspace.forward-layer"; "workspace.live-layer" ]
    (List.map (fun (layer : S.identity) -> layer.name) report.layers);
  Alcotest.(check (list (list string)))
    "layer introduced rows"
    [
      [ "Audit"; "GovernanceApprovalV1"; "State"; "Judge"; "Workspace" ];
      [ "Audit"; "GovernanceApprovalV1"; "State"; "Secret"; "Fs"; "Judge"; "Net" ];
    ]
    (List.map (fun (layer : S.identity) -> layer.introduced_row) report.layers);
  Alcotest.(check (list string))
    "fixed operation order"
    [ "workspace.read-file"; "workspace.write-file"; "workspace.fetch" ]
    (List.map (fun (operation : S.operation) -> operation.name) report.operations);
  Alcotest.(check (list (list string)))
    "fixed operation authority"
    [ [ "Fs" ]; [ "Fs" ]; [ "Net"; "Secret" ] ]
    (List.map (fun (operation : S.operation) -> operation.authority) report.operations);
  let parsed = Yojson.Safe.from_string json in
  match parsed with
  | `Assoc fields ->
      Alcotest.(check (list string))
        "canonical top-level key order"
        [
          "schema";
          "profile";
          "facade";
          "live";
          "dry";
          "policy_binders";
          "layers";
          "operations";
          "runtime_identities";
        ]
        (List.map fst fields);
      let open Yojson.Safe.Util in
      Alcotest.(check string)
        "schema" "jacquard-governance-check-report-v1"
        (parsed |> member "schema" |> to_string);
      Alcotest.(check string) "profile" "workspace-v0" (parsed |> member "profile" |> to_string);
      Alcotest.(check (list string))
        "JSON facade introduced row" [ "Workspace" ]
        (parsed |> member "facade" |> member "introduced_row" |> to_list |> List.map to_string);
      Alcotest.(check (list string))
        "JSON forward-layer introduced row"
        [ "Audit"; "GovernanceApprovalV1"; "State"; "Judge"; "Workspace" ]
        (parsed |> member "layers" |> index 0 |> member "introduced_row" |> to_list
       |> List.map to_string);
      let runtime = parsed |> member "runtime_identities" in
      Alcotest.(check string)
        "runtime identity status" "dynamic"
        (runtime |> member "status" |> to_string);
      Alcotest.(check string)
        "runtime verification handoff" "jac governance verify-run BUNDLE"
        (runtime |> member "verification_command" |> to_string)
  | _ -> Alcotest.fail "governance report is not a JSON object"

let suite =
  [
    Alcotest.test_case "exact 0/1/2 forwarding topology" `Quick test_exact_layer_counts;
    Alcotest.test_case "source traversal fails closed" `Quick test_failure_boundaries;
    Alcotest.test_case "versioned report contract" `Quick test_report_contract;
  ]
