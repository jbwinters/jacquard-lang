open Jacquard
module W = Governance_why_effect

let fail diagnostics = String.concat "\n" (List.map Diag.to_string diagnostics)

let analyze path effect_name =
  let store, checker, declarations = Test_governance_source_check.load path in
  match Governance_source_check.verify_detailed store checker declarations with
  | Error diagnostics -> Alcotest.fail (fail diagnostics)
  | Ok source -> W.analyze ~effect_name source

let expect_ok path effect_name =
  match analyze path effect_name with
  | Ok report -> report
  | Error diagnostics -> Alcotest.failf "%s unexpectedly failed:\n%s" path (fail diagnostics)

let expect_code path effect_name code =
  match analyze path effect_name with
  | Ok _ -> Alcotest.failf "%s unexpectedly passed" path
  | Error diagnostics ->
      Alcotest.(check bool)
        (path ^ " contains " ^ code)
        true
        (List.exists
           (fun diagnostic -> String.equal (Diag.code_or_uncoded diagnostic) code)
           diagnostics)

let expect_source_code path code =
  let store, checker, declarations = Test_governance_source_check.load path in
  match Governance_source_check.verify_detailed store checker declarations with
  | Ok _ -> Alcotest.failf "%s unexpectedly passed source verification" path
  | Error diagnostics ->
      Alcotest.(check bool)
        (path ^ " contains " ^ code)
        true
        (List.exists
           (fun diagnostic -> String.equal (Diag.code_or_uncoded diagnostic) code)
           diagnostics)

let test_direct_authority () =
  Alcotest.(check (list string))
    "Fs reaches both file operations"
    [ "workspace.read-file"; "workspace.read-file"; "workspace.write-file" ]
    (List.map
       (fun (chain : W.chain) -> chain.operation.name)
       (expect_ok "workspace-why-effect-direct.jqd" "Fs").chains);
  let direct = expect_ok "workspace-why-effect-direct.jqd" "Fs" in
  Alcotest.(check (list int))
    "identical applications retain distinct stable sites" [ 0; 2; 4 ]
    (List.map (fun (chain : W.chain) -> chain.application_site.ordinal) direct.chains);
  Alcotest.(check (list string))
    "application sites identify their source member"
    [ "workspace-why-effect-direct"; "workspace-why-effect-direct"; "workspace-why-effect-direct" ]
    (List.map (fun (chain : W.chain) -> chain.application_site.member.name) direct.chains);
  Alcotest.(check (list string))
    "Net reaches fetch" [ "workspace.fetch" ]
    (List.map
       (fun (chain : W.chain) -> chain.operation.name)
       (expect_ok "workspace-why-effect-direct.jqd" "Net").chains);
  Alcotest.(check (list string))
    "Secret reaches fetch" [ "workspace.fetch" ]
    (List.map
       (fun (chain : W.chain) -> chain.operation.name)
       (expect_ok "workspace-why-effect-direct.jqd" "Secret").chains)

let test_identity_and_zero () =
  let by_name = expect_ok "workspace-why-effect-direct.jqd" "Fs" in
  let by_hash =
    expect_ok "workspace-why-effect-direct.jqd"
      "8ec13169c7181851364e55353232af8e3c7f5ee4a010fa3067fcf2058dd5ed84"
  in
  Alcotest.(check string)
    "display and identity select the same report" (W.render_json_v1 by_name)
    (W.render_json_v1 by_hash);
  Alcotest.(check int)
    "fully verified source may have zero attributable chains" 0
    (List.length (expect_ok "workspace-check-zero-layer.jqd" "Fs").chains);
  Alcotest.(check int)
    "dry roots are always zero-chain" 0
    (List.length (expect_ok "workspace-check-dry.jqd" "Secret").chains);
  Alcotest.(check int)
    "dry roots stay zero despite an ambiguous payload call" 0
    (List.length (expect_ok "workspace-why-effect-dry-ambiguous.jqd" "Fs").chains);
  expect_code "workspace-check-zero-layer.jqd" "fs" "E1534";
  expect_code "workspace-check-zero-layer.jqd"
    "49648e594a9e79b0bf6e0b73f860c43fc5d816393022eca5f263c2eb6c00dec2" "E1534";
  expect_source_code "workspace-why-effect-same-name.jqd" "E1400";
  expect_source_code "workspace-why-effect-shadow-driver.jqd" "E1400"

let test_source_graph_and_refusals () =
  let report = expect_ok "workspace-why-effect-wrapper.jqd" "Fs" in
  Alcotest.(check (list string))
    "GroupRef path is root then helper"
    [ "workspace-why-effect-wrapper"; "workspace-why-effect-helper" ]
    (List.map (fun (identity : W.identity) -> identity.name) (List.hd report.chains).source_path);
  Alcotest.(check (list string))
    "inter-group refs form a two-wrapper chain"
    [
      "workspace-why-effect-ref-root";
      "workspace-why-effect-ref-middle";
      "workspace-why-effect-ref-leaf";
    ]
    (List.map
       (fun (identity : W.identity) -> identity.name)
       (List.hd (expect_ok "workspace-why-effect-ref-chain.jqd" "Fs").chains).source_path);
  Alcotest.(check (list string))
    "SCC GroupRefs terminate after reaching the operation"
    [ "workspace-why-effect-scc-root"; "workspace-why-effect-scc-a"; "workspace-why-effect-scc-b" ]
    (List.map
       (fun (identity : W.identity) -> identity.name)
       (List.hd (expect_ok "workspace-why-effect-scc.jqd" "Fs").chains).source_path);
  Alcotest.(check int)
    "level-zero unquote is live" 1
    (List.length (expect_ok "workspace-why-effect-unquote.jqd" "Fs").chains);
  Alcotest.(check int)
    "refs, lambda values, and quote data stay inert" 0
    (List.length (expect_ok "workspace-why-effect-inert.jqd" "Fs").chains);
  Alcotest.(check int)
    "a directly invoked lambda body is reachable" 1
    (List.length (expect_ok "workspace-why-effect-direct-lambda.jqd" "Fs").chains);
  let forwarded =
    expect_ok "workspace-why-effect-forwarded.jqd" "Fs" |> fun report -> List.hd report.chains
  in
  Alcotest.(check (list string))
    "forward layers precede the live leaf"
    [ "workspace.forward-layer"; "workspace.forward-layer"; "workspace.live-layer" ]
    (List.map
       (fun (identity : W.identity) -> identity.name)
       (forwarded.forwarding_layers @ [ forwarded.live_leaf ]));
  expect_code "workspace-why-effect-variable.jqd" "Fs" "E1535";
  expect_code "workspace-why-effect-selected-callable.jqd" "Fs" "E1535";
  expect_code "workspace-why-effect-polymorphic-transport.jqd" "Fs" "E1535";
  expect_code "workspace-why-effect-local-handler.jqd" "Fs" "E1536"

let test_report_contract () =
  let report = expect_ok "workspace-why-effect-direct.jqd" "Fs" in
  let json = Yojson.Safe.from_string (W.render_json_v1 report) in
  let open Yojson.Safe.Util in
  Alcotest.(check string)
    "outer schema" "jacquard-why-effect-report-v1"
    (json |> member "schema" |> to_string);
  Alcotest.(check string)
    "nested facts schema" "jacquard-governance-review-facts-v1"
    (json |> member "review_facts" |> member "schema" |> to_string);
  Alcotest.(check int)
    "nested facts retain every distinct application site" 3
    (json |> member "review_facts" |> member "attribution_chains" |> to_list |> List.length);
  Alcotest.(check bool)
    "not execution provenance" false
    (json |> member "evidence_limits" |> member "execution_provenance" |> to_bool)

let suite =
  [
    Alcotest.test_case "direct read/write/fetch authority" `Quick test_direct_authority;
    Alcotest.test_case "exact effect identity and deterministic zero" `Quick test_identity_and_zero;
    Alcotest.test_case "source graph and fail-closed calls" `Quick test_source_graph_and_refusals;
    Alcotest.test_case "versioned static facts report" `Quick test_report_contract;
  ]
