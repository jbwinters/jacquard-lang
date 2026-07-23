open Jacquard
module R = Test_governance_reconcile

let store = R.store

let fail_diags label diagnostics =
  Alcotest.failf "%s: %s" label (String.concat "; " (List.map Diag.to_string diagnostics))

let expect_error label code result =
  match result with
  | Error (diagnostic :: _) -> Alcotest.(check string) label code (Diag.code_or_uncoded diagnostic)
  | Error [] -> Alcotest.failf "%s returned no diagnostics" label
  | Ok _ -> Alcotest.failf "%s unexpectedly verified" label

let canonical_driver () =
  match Governance_source_check.canonical_workspace_driver ~operation:(R.workspace_write_id ()) with
  | Some ("workspace.write-file", "workspace.driver-write", driver) -> driver
  | Some (operation, driver, _) ->
      Alcotest.failf "unexpected Workspace mapping %s -> %s" operation driver
  | None -> Alcotest.fail "workspace.write-file has no canonical driver"

let canonical_package () =
  let fixture = R.fixture () in
  let authorization = R.record_digest (List.nth fixture.records 2) in
  let attempted, attempt_id =
    R.attempt 0 ~call:fixture.child.id ~authorization ~branch:"live" ~driver:(canonical_driver ())
      ~key:(R.hash "idempotency-key")
  in
  let outcome = R.outcome_of_entry (R.completed 3 fixture.child) in
  let received = R.receipt 1 ~attempt_id ~outcome ~external_digest:(R.hash "external-receipt") in
  let records, head = R.journal [ attempted; received ] in
  (fixture, R.package fixture.bundle head records)

let non_action_package decision_head =
  let fixture = R.fixture () in
  let decision =
    match decision_head with
    | "denied-v1" ->
        R.form decision_head
          [
            R.hash_form fixture.proposal.id;
            R.lit "principal:reviewer-1";
            R.lit "policy owner denied";
          ]
    | "escalate-v1" ->
        R.form decision_head [ R.hash_form fixture.proposal.id; R.lit "security review required" ]
    | _ -> Alcotest.fail "unsupported test Decision"
  in
  let consent =
    R.form "audit-entry-v2"
      [
        R.form "consented-v2"
          [
            R.version;
            R.int 2;
            R.hash_form fixture.child.id;
            R.hash_form fixture.proposal.id;
            decision;
          ];
      ]
  in
  let entries =
    [
      R.evaluated 0 fixture.root fixture.policy fixture.assessment "block";
      R.evaluated 1 fixture.child fixture.policy fixture.assessment "ask";
      consent;
    ]
  in
  let records, head = R.chain entries in
  let run =
    R.run_bundle ~head ~records
      ~calls:[ fixture.root.artifact; fixture.child.artifact ]
      ~policies:[ fixture.policy.artifact ] ~assessments:[ fixture.assessment.artifact ]
      ~proposals:[ fixture.proposal.artifact ]
  in
  (fixture, R.package run Governance_reconcile.journal_genesis [])

let explain proposal_id package =
  Governance_explain.verify_form ~store ~file:"gm17a-test.jqd" ~proposal_id package

let test_approved_projection_and_render_agreement () =
  let fixture, package = canonical_package () in
  let report =
    match explain fixture.proposal.id package with
    | Ok report -> report
    | Error diagnostics -> fail_diags "canonical approved explanation" diagnostics
  in
  Alcotest.(check string)
    "proposal" (Hash.to_hex fixture.proposal.id) (Hash.to_hex report.proposal_id);
  Alcotest.(check string) "operation" "workspace.write-file" report.operation_name;
  Alcotest.(check string) "policy rule" "live.at-or-below-ask" report.policy_rule;
  Alcotest.(check string) "recorded verdict" "ask" report.recorded_verdict;
  Alcotest.(check string) "decision" "approved" report.decision_kind;
  Alcotest.(check int) "relevant Audit entries" 3 (List.length report.audit);
  (match report.attempt with
  | Governance_explain.Attempted attempted ->
      Alcotest.(check string) "attempt state" "reconciled-completed" attempted.state;
      Alcotest.(check string) "driver name" "workspace.driver-write" attempted.driver_name;
      Alcotest.(check string)
        "driver identity"
        (Hash.to_hex (canonical_driver ()))
        (Hash.to_hex attempted.driver_id);
      Alcotest.(check bool) "receipt present" true (Option.is_some attempted.receipt_id)
  | Governance_explain.Not_attempted -> Alcotest.fail "approved fixture lost its attempt");
  let text_first = Governance_explain.render_text report in
  let text_second = Governance_explain.render_text report in
  Alcotest.(check string) "repeated text bytes" text_first text_second;
  let json_first = Governance_explain.render_json_v1 report in
  let json_second = Governance_explain.render_json_v1 report in
  Alcotest.(check string) "repeated JSON bytes" json_first json_second;
  let json = Yojson.Safe.from_string json_first in
  let member name = Yojson.Safe.Util.member name json in
  Alcotest.(check string)
    "JSON schema" Governance_explain.schema
    (Yojson.Safe.Util.to_string (member "schema"));
  Alcotest.(check string)
    "JSON Proposal" (Hash.to_hex report.proposal_id)
    (Yojson.Safe.Util.to_string (member "proposal_id"));
  Alcotest.(check string)
    "JSON policy rule" report.policy_rule
    (Yojson.Safe.Util.to_string (member "policy_rule"));
  Alcotest.(check string)
    "JSON Proposal summary" "approve child"
    (Yojson.Safe.Util.to_string (member "proposal_summary"));
  let review_facts = member "review_facts" in
  Alcotest.(check string)
    "review facts schema" Governance_explain.review_facts_schema
    Yojson.Safe.Util.(review_facts |> member "schema" |> to_string);
  Alcotest.(check string)
    "review facts Proposal rendering" "(review-v1 (lit \"child\"))"
    Yojson.Safe.Util.(review_facts |> member "proposal" |> member "rendering" |> to_string);
  Alcotest.(check string)
    "review facts action" "reconciled-completed"
    Yojson.Safe.Util.(review_facts |> member "action" |> member "state" |> to_string);
  Alcotest.(check int)
    "JSON Audit count" (List.length report.audit)
    (List.length (Yojson.Safe.Util.to_list (member "audit")));
  List.iter
    (fun required ->
      Alcotest.(check bool)
        ("text carries " ^ required) true
        (String.contains text_first required.[0]
        && Option.is_some
             (let regexp = Str.regexp_string required in
              try Some (Str.search_forward regexp text_first 0) with Not_found -> None)))
    [
      report.policy_rule;
      Hash.to_hex report.proposal_id;
      "workspace.driver-write";
      "reconciled-completed";
    ]

let test_non_action_decisions_never_guess_driver () =
  List.iter
    (fun (carrier, expected) ->
      let fixture, package = non_action_package carrier in
      match explain fixture.proposal.id package with
      | Error diagnostics -> fail_diags expected diagnostics
      | Ok report ->
          Alcotest.(check string) "Decision kind" expected report.decision_kind;
          (match report.attempt with
          | Governance_explain.Not_attempted -> ()
          | Governance_explain.Attempted _ -> Alcotest.fail "non-action Decision gained a driver");
          let text = Governance_explain.render_text report in
          Alcotest.(check bool)
            "text says not-attempted" true
            (try
               ignore (Str.search_forward (Str.regexp_string "driver not-attempted") text 0);
               true
             with Not_found -> false);
          let json = Governance_explain.render_json_v1 report |> Yojson.Safe.from_string in
          Alcotest.(check string)
            "JSON action state" "not-attempted"
            Yojson.Safe.Util.(json |> member "attempt" |> member "state" |> to_string);
          Alcotest.(check bool)
            "JSON driver is null" true
            Yojson.Safe.Util.(json |> member "attempt" |> member "driver" = `Null))
    [ ("denied-v1", "denied"); ("escalate-v1", "escalated") ];
  Test_governance_decision_chain.run ()

let inconsistent_rule_package () =
  let root = R.make_call "rule-root" in
  let child = R.make_call ~parent:root.id "rule-child" in
  let policy = R.make_policy () in
  let assessment_artifact =
    R.form "governance-assessment-v0"
      [
        R.version;
        R.form "low" [];
        R.real 0.95;
        R.form "text-list-v1" [ R.lit "rule mismatch" ];
        R.form "assessment-evidence-v1" [ R.lit "rules-v1" ];
      ]
  in
  let assessment : R.assessment =
    { id = R.code_hash assessment_artifact; artifact = assessment_artifact }
  in
  let proposal = R.make_proposal child policy assessment "rule-child" in
  let entries =
    [
      R.evaluated 0 root policy assessment "block";
      R.evaluated 1 child policy assessment "ask";
      R.consented 2 child proposal;
    ]
  in
  let records, head = R.chain entries in
  let run =
    R.run_bundle ~head ~records ~calls:[ root.artifact; child.artifact ]
      ~policies:[ policy.artifact ] ~assessments:[ assessment.artifact ]
      ~proposals:[ proposal.artifact ]
  in
  (proposal, R.package run Governance_reconcile.journal_genesis [])

let test_hostile_rule_driver_selection_and_gap () =
  let proposal, package = inconsistent_rule_package () in
  expect_error "wrong recorded rule" "E1532" (explain proposal.id package);
  let fixture = R.fixture () in
  let wrong_driver, _ = R.fixture_attempt fixture in
  let journal, head = R.journal [ wrong_driver ] in
  expect_error "wrong committed driver" "E1533"
    (explain fixture.proposal.id (R.package fixture.bundle head journal));
  expect_error "missing selected Proposal" "E1531"
    (explain (R.hash "missing-proposal") (snd (canonical_package ())));
  expect_error "malformed Proposal text" "E1530"
    (Governance_explain.proposal_id_of_string (String.make 64 'A'));
  expect_error "approved completion without attempt" "E1533"
    (explain fixture.proposal.id (R.package fixture.bundle Governance_reconcile.journal_genesis []))

let replace_once ~before ~after source =
  let regexp = Str.regexp_string before in
  match Str.search_forward regexp source 0 with
  | index ->
      String.sub source 0 index ^ after
      ^ String.sub source
          (index + String.length before)
          (String.length source - index - String.length before)
  | exception Not_found -> Alcotest.failf "fixture does not contain %s" before

let test_tamper_and_existing_outputs_stay_strict () =
  let fixture, package = canonical_package () in
  let bytes = Printer.print_compact package ^ "\n" in
  let tampered =
    replace_once ~before:(Hash.to_hex (canonical_driver ())) ~after:(String.make 64 '0') bytes
  in
  expect_error "tampered journal" "E1511"
    (Governance_explain.verify_string ~store ~file:"tampered.jqd" ~proposal_id:fixture.proposal.id
       tampered);
  let original = R.package fixture.bundle Governance_reconcile.journal_genesis [] in
  match Governance_reconcile.verify_form ~store ~file:"unchanged-reconcile.jqd" original with
  | Ok report ->
      Alcotest.(check int)
        "existing reconciliation gap unchanged" 1 report.completion_without_receipt
  | Error diagnostics -> fail_diags "unchanged reconciliation API" diagnostics

let suite =
  [
    Alcotest.test_case "approved projection and render agreement" `Quick
      test_approved_projection_and_render_agreement;
    Alcotest.test_case "non-action decisions never guess driver" `Quick
      test_non_action_decisions_never_guess_driver;
    Alcotest.test_case "hostile rule driver selection and gap" `Quick
      test_hostile_rule_driver_selection_and_gap;
    Alcotest.test_case "tamper and existing outputs stay strict" `Quick
      test_tamper_and_existing_outputs_stay_strict;
  ]

let write_fixture variable package =
  match Sys.getenv_opt variable with
  | None -> ()
  | Some path ->
      let channel = open_out_bin path in
      Fun.protect
        ~finally:(fun () -> close_out channel)
        (fun () -> output_string channel (Printer.print_compact package ^ "\n"))

let () =
  write_fixture "GM17A_APPROVED_FIXTURE_OUT" (snd (canonical_package ()));
  write_fixture "GM17A_DENIED_FIXTURE_OUT" (snd (non_action_package "denied-v1"))
