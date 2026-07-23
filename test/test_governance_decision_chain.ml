open Jacquard
module D = Governance_decision_chain

let fail_diags diagnostics =
  Alcotest.failf "%s" (String.concat "\n" (List.map Diag.to_string diagnostics))

let json scenario = D.fixture scenario |> D.render_json_v1 |> Yojson.Safe.from_string
let member name value = Yojson.Safe.Util.member name value
let stages value = Yojson.Safe.Util.(value |> member "stages" |> to_list)

let stage name value =
  List.find
    (fun item -> Yojson.Safe.Util.(item |> member "stage" |> to_string = name))
    (stages value)

let test_fixture_scenarios_are_typed_deterministic_and_complete () =
  let cases =
    [
      (D.Allow_fixture, "Allow", "Not required");
      (D.Block_fixture, "Block", "Not required");
      (D.Stale_approval_fixture, "Ask", "Stale");
      (D.Transformed_call_fixture, "Ask", "Approved");
      (D.Missing_completion_fixture, "Ask", "Approved");
      (D.Dry_simulation_fixture, "Simulate", "Not required");
    ]
  in
  List.iter
    (fun (scenario, verdict, consent) ->
      let first = D.fixture scenario |> D.render_json_v1 in
      let second = D.fixture scenario |> D.render_json_v1 in
      Alcotest.(check string) "fixture bytes are deterministic" first second;
      let value = Yojson.Safe.from_string first in
      let open Yojson.Safe.Util in
      Alcotest.(check string) "schema" D.schema (value |> member "schema" |> to_string);
      Alcotest.(check string) "profile" D.profile (value |> member "profile" |> to_string);
      Alcotest.(check string) "fixture source" "fixture" (value |> member "source" |> to_string);
      Alcotest.(check bool) "illustrative" true (value |> member "illustrative" |> to_bool);
      Alcotest.(check (list string))
        "fixed stage order"
        [ "request"; "assessment"; "verdict"; "consent"; "activity"; "outcome" ]
        (stages value |> List.map (fun item -> item |> member "stage" |> to_string));
      Alcotest.(check string)
        "closed verdict" verdict
        (stage "verdict" value |> member "kind" |> to_string);
      Alcotest.(check string)
        "closed consent" consent
        (stage "consent" value |> member "kind" |> to_string))
    cases

let test_stale_dry_and_lineage_fixture_boundaries () =
  let allowed = json D.Allow_fixture in
  let blocked = json D.Block_fixture in
  let stale = json D.Stale_approval_fixture in
  let dry = json D.Dry_simulation_fixture in
  let transformed = json D.Transformed_call_fixture in
  let open Yojson.Safe.Util in
  List.iter
    (fun value ->
      Alcotest.(check bool)
        "non-Ask verdict has no consent proposal" true
        (stage "consent" value |> member "proposal" = `Null);
      Alcotest.(check int)
        "non-Ask verdict has no consented audit" 1
        (stage "consent" value |> member "audit" |> to_list |> List.length))
    [ allowed; blocked ];
  Alcotest.(check bool)
    "stale has no committed consent artifact" true
    (stage "consent" stale |> member "proposal" = `Null);
  Alcotest.(check (list string))
    "stale retains evaluation but has no consented evidence" [ "evaluated-v2" ]
    (stage "consent" stale |> member "audit" |> to_list
    |> List.map (fun entry -> entry |> member "kind" |> to_string));
  Alcotest.(check bool)
    "stale has no action" true
    (stage "activity" stale |> member "activity" |> member "attempt" = `Null);
  Alcotest.(check bool)
    "simulation is not consent" true
    (stage "outcome" dry |> member "outcome" |> member "simulation_not_consent" |> to_bool);
  Alcotest.(check bool)
    "dry has no action" true
    (stage "activity" dry |> member "activity" |> member "attempt" = `Null);
  Alcotest.(check bool)
    "transformed call carries typed parent identity" true
    (stage "request" transformed |> member "parent_call_id" <> `Null)

let verified_report () =
  let module R = Test_governance_reconcile in
  let fixture = R.fixture () in
  let authorization = R.record_digest (List.nth fixture.records 2) in
  let driver =
    match
      Governance_source_check.canonical_workspace_driver ~operation:(R.workspace_write_id ())
    with
    | Some (_, _, driver) -> driver
    | None -> Alcotest.fail "Workspace driver is unavailable"
  in
  let attempted, attempt_id =
    R.attempt 0 ~call:fixture.child.id ~authorization ~branch:"live" ~driver
      ~key:(R.hash "decision-chain-key")
  in
  let receipt =
    R.receipt 1 ~attempt_id
      ~outcome:(R.outcome_of_entry (R.completed 3 fixture.child))
      ~external_digest:(R.hash "decision-chain-receipt")
  in
  let journal, head = R.journal [ attempted; receipt ] in
  Governance_explain.verify_form ~store:R.store ~file:"decision-chain.jqd"
    ~proposal_id:fixture.proposal.id
    (R.package fixture.bundle head journal)

let test_verified_adapter_is_opaque_and_rejects_bad_invariants () =
  let report =
    match verified_report () with
    | Ok report -> report
    | Error diagnostics -> fail_diags diagnostics
  in
  let bytes =
    match D.project_json_v1 report with
    | Ok bytes -> bytes
    | Error diagnostics -> fail_diags diagnostics
  in
  let value = Yojson.Safe.from_string bytes in
  let open Yojson.Safe.Util in
  Alcotest.(check string) "verified source" "verified" (value |> member "source" |> to_string);
  Alcotest.(check bool)
    "verified is not illustrative" false
    (value |> member "illustrative" |> to_bool);
  Alcotest.(check string)
    "verified verdict is closed" "Ask"
    (stage "verdict" value |> member "kind" |> to_string);
  Alcotest.(check (list string))
    "completion evidence is not presented as consent evidence"
    [ "evaluated-v2"; "consented-v2" ]
    (stage "consent" value |> member "audit" |> to_list
    |> List.map (fun entry -> entry |> member "kind" |> to_string));
  Alcotest.(check string)
    "verified reconciliation state" "reconciled-completed"
    (stage "outcome" value |> member "outcome" |> member "kind" |> to_string);
  Alcotest.(check string)
    "completion identity is backend supplied" "completed-v2"
    (stage "outcome" value |> member "outcome" |> member "completion" |> member "kind" |> to_string);
  Alcotest.(check bool)
    "call content is absent" false
    (try
       ignore (Str.search_forward (Str.regexp_string "approve child") bytes 0);
       true
     with Not_found -> false);
  let malformed_reports =
    [
      { report with decision_kind = "client-decides" };
      { report with operation_name = "workspace.client-forged" };
      {
        report with
        attempt =
          (match report.attempt with
          | Governance_explain.Attempted attempt ->
              Governance_explain.Attempted { attempt with receipt_id = None }
          | Governance_explain.Not_attempted ->
              Alcotest.fail "verified fixture unexpectedly has no attempt");
      };
    ]
  in
  List.iter
    (fun malformed ->
      match D.of_explain malformed with
      | Error (diagnostic :: _) ->
          Alcotest.(check string) "malformed report" "E1542" (Diag.code_or_uncoded diagnostic)
      | Error [] -> Alcotest.fail "malformed report returned no diagnostic"
      | Ok _ -> Alcotest.fail "malformed report was projected")
    malformed_reports

let test_checked_in_fixtures_match_backend_bytes () =
  [
    ("allowed.json", D.Allow_fixture);
    ("blocked.json", D.Block_fixture);
    ("stale-approval.json", D.Stale_approval_fixture);
    ("transformed.json", D.Transformed_call_fixture);
    ("attempt-missing-completion.json", D.Missing_completion_fixture);
    ("dry-simulation.json", D.Dry_simulation_fixture);
  ]
  |> List.iter (fun (name, scenario) ->
      let expected = D.fixture scenario |> D.render_json_v1 |> fun bytes -> bytes ^ "\n" in
      let path = Filename.concat "../playground/governance/fixtures/generated" name in
      Alcotest.(check string)
        (name ^ " is generated by the typed backend")
        expected (Corpus_support.read_file path))

let run () =
  test_fixture_scenarios_are_typed_deterministic_and_complete ();
  test_stale_dry_and_lineage_fixture_boundaries ();
  test_verified_adapter_is_opaque_and_rejects_bad_invariants ();
  test_checked_in_fixtures_match_backend_bytes ()
