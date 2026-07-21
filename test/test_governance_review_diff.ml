open Jacquard
module D = Governance_review_diff
module W = Governance_why_effect

let hash value = Hash.of_string value
let identity name = { W.name; hash = hash name }
let form name = Form.form name []
let operation ?(name = "workspace.write-file") () = { W.name; hash = hash (name ^ ".identity") }
let authority name = identity name

let operation_fact ?(operation = operation ()) ?(raw_authority = [ authority "Fs" ])
    ?(normalizer = identity "normalizer") ?(summarizer = identity "summarizer")
    ?(simulator = identity "simulator") ?(driver = identity "driver") ?(row = [ authority "Fs" ]) ()
    : W.operation_fact =
  {
    operation;
    raw_authority;
    normalizer;
    summarizer;
    simulator;
    driver;
    driver_introduced_raw_row = row;
  }

let static_report ?(requested_effect = identity "Fs") ?(topology = "direct-live")
    ?(facade = identity "Workspace") ?(facade_operations = [ operation () ])
    ?(reached_operations = [ operation_fact () ]) () : W.report =
  {
    requested_effect;
    source_root = identity "source-root";
    topology;
    facade;
    facade_operations;
    reached_operations;
    chains = [];
  }

let dynamic_report ?(proposal_id = hash "proposal") ?(rendering = form "rendering")
    ?(summary = "summary") ?(call_id = hash "call") ?(operation = operation ())
    ?(call = form "call") ?(authority = form "authority") ?(policy_id = hash "policy")
    ?(policy = form "policy") ?(assessment_id = hash "assessment") ?(assessment = form "assessment")
    ?(preview = form "preview") ?(policy_rule = "live.at-or-below-ask") ?(recorded_verdict = "ask")
    ?(decision_kind = "approved") ?decision ?(attempt = Governance_explain.Not_attempted) () :
    Governance_explain.report =
  let decision =
    Option.value decision
      ~default:(Form.form "approved-v1" [ Form.Hash proposal_id; Form.Text "reviewer" ])
  in
  {
    proposal_id;
    proposal = form "proposal";
    proposal_rendering = rendering;
    proposal_summary = summary;
    proposal_preview = preview;
    call_id;
    operation_name = operation.name;
    operation_id = operation.hash;
    call;
    raw_authority = authority;
    policy_id;
    bound_policy = policy;
    assessment_id;
    assessment;
    policy_rule;
    recorded_verdict;
    decision_kind;
    decision;
    audit = [];
    attempt;
  }

let fail diagnostics = String.concat "\n" (List.map Diag.to_string diagnostics)

let expect_ok label = function
  | Ok value -> value
  | Error diagnostics -> Alcotest.failf "%s failed:\n%s" label (fail diagnostics)

let expect_code label code = function
  | Error diagnostics ->
      Alcotest.(check bool)
        label true
        (List.exists
           (fun diagnostic -> String.equal code (Diag.code_or_uncoded diagnostic))
           diagnostics)
  | Ok _ -> Alcotest.failf "%s unexpectedly succeeded" label

let kinds (classification : D.classification) =
  List.map (fun (change : D.change) -> change.kind) classification.changes

let check_kinds label expected classification =
  Alcotest.(check (list string))
    label
    (List.map D.change_kind_to_string expected)
    (List.map D.change_kind_to_string (kinds classification))

let classify_static old_ new_ =
  D.classify_static
    ~old_:(D.static_facts_of_why_effect old_)
    ~new_:(D.static_facts_of_why_effect new_)
  |> expect_ok "static classification"

let classify_dynamic old_ new_ =
  D.classify_dynamic ~old_:(D.dynamic_facts_of_explain old_) ~new_:(D.dynamic_facts_of_explain new_)
  |> expect_ok "dynamic classification"

let test_facade_and_row_categories () =
  let base = static_report () in
  let added = operation ~name:"workspace.fetch" () in
  let added_report =
    static_report
      ~facade_operations:[ added; operation () ]
      ~reached_operations:[ operation_fact () ]
      ()
  in
  check_kinds "facade addition" [ D.Facade_added ] (classify_static base added_report);
  check_kinds "facade removal" [ D.Facade_removed ] (classify_static added_report base);
  let net = authority "Net" in
  let widened =
    static_report ~reached_operations:[ operation_fact ~row:[ net; authority "Fs" ] () ] ()
  in
  check_kinds "strict row superset" [ D.Driver_row_widened ] (classify_static base widened);
  check_kinds "strict row subset" [ D.Driver_row_narrowed ] (classify_static widened base);
  let secret = authority "Secret" in
  let changed = static_report ~reached_operations:[ operation_fact ~row:[ secret ] () ] () in
  check_kinds "incomparable row" [ D.Driver_row_changed ] (classify_static widened changed)

let test_semantic_and_rendering_categories () =
  let base = static_report () in
  let simulator =
    static_report ~reached_operations:[ operation_fact ~simulator:(identity "new-simulator") () ] ()
  in
  check_kinds "simulator" [ D.Simulator_changed ] (classify_static base simulator);
  let driver =
    static_report ~reached_operations:[ operation_fact ~driver:(identity "new-driver") () ] ()
  in
  check_kinds "driver" [ D.Driver_changed ] (classify_static base driver);
  let normalizer =
    static_report
      ~reached_operations:[ operation_fact ~normalizer:(identity "new-normalizer") () ]
      ()
  in
  check_kinds "normalizer" [ D.Normalizer_changed ] (classify_static base normalizer);
  let rendered =
    static_report
      ~reached_operations:[ operation_fact ~summarizer:(identity "new-summarizer") () ]
      ()
  in
  check_kinds "operation rendering only" [ D.Operation_rendering_only ]
    (classify_static base rendered);
  let rendered_and_semantic =
    static_report
      ~reached_operations:
        [
          operation_fact ~summarizer:(identity "new-summarizer")
            ~normalizer:(identity "new-normalizer") ();
        ]
      ()
  in
  check_kinds "rendering exclusion"
    [ D.Normalizer_changed; D.Summarizer_changed ]
    (classify_static base rendered_and_semantic);
  let old_dynamic = dynamic_report () in
  let proposal_id = hash "rendered-proposal" in
  let new_dynamic =
    dynamic_report ~proposal_id ~rendering:(form "new-rendering") ~summary:"new summary"
      ~decision:(Form.form "approved-v1" [ Form.Hash proposal_id; Form.Text "reviewer" ])
      ()
  in
  check_kinds "proposal rendering only" [ D.Proposal_rendering_only ]
    (classify_dynamic old_dynamic new_dynamic);
  let policy = dynamic_report ~policy_id:(hash "new-policy") ~policy:(form "new-policy") () in
  check_kinds "policy" [ D.Policy_changed ] (classify_dynamic old_dynamic policy);
  let attempted =
    Governance_explain.Attempted
      {
        state = "reconciled-completed";
        attempt_id = hash "attempt";
        driver_name = "driver";
        driver_id = (identity "driver").hash;
        receipt_id = Some (hash "receipt");
        external_receipt_digest = Some (hash "external");
      }
  in
  let attempted_old = dynamic_report ~attempt:attempted () in
  let attempted_new =
    dynamic_report ~attempt:attempted ~proposal_id ~rendering:(form "new-rendering")
      ~decision:(Form.form "approved-v1" [ Form.Hash proposal_id; Form.Text "reviewer" ])
      ()
  in
  check_kinds "attempt evidence blocks rendering-only" [ D.Proposal_rendering_changed ]
    (classify_dynamic attempted_old attempted_new)

let test_labels_partial_and_no_change () =
  let renamed_operation = { W.name = "write-label-only"; hash = (operation ()).hash } in
  let renamed =
    static_report ~facade_operations:[ renamed_operation ]
      ~reached_operations:[ operation_fact ~operation:renamed_operation () ]
      ()
  in
  check_kinds "name is label, not add/remove" [ D.Label_changed ]
    (classify_static (static_report ()) renamed);
  let absent = static_report ~reached_operations:[] () in
  let unavailable = classify_static (static_report ()) absent in
  Alcotest.(check int) "one unavailable operation" 1 (List.length unavailable.unavailable);
  let item = List.hd unavailable.unavailable in
  Alcotest.(check string) "stable unavailable reason" "operation-not-reached" item.reason;
  Alcotest.(check bool) "new side missing" true (item.side = D.New);
  let old_snapshot =
    D.make_snapshot ~dynamic:None ~static:(Some (D.static_facts_of_why_effect (static_report ())))
    |> expect_ok "old static snapshot"
  in
  let new_snapshot =
    D.make_snapshot ~dynamic:None ~static:(Some (D.static_facts_of_why_effect absent))
    |> expect_ok "new static snapshot"
  in
  let partial = D.compare ~old_:old_snapshot ~new_:new_snapshot |> expect_ok "partial report" in
  Alcotest.(check string)
    "partial completeness" "partial"
    (D.completeness_to_string partial.completeness);
  let no_change = D.compare ~old_:old_snapshot ~new_:old_snapshot |> expect_ok "no-change report" in
  Alcotest.(check string)
    "fully available equality" "no-change"
    (D.completeness_to_string no_change.completeness)

let test_linkage_duplicates_and_invariants () =
  let dynamic = D.dynamic_facts_of_explain (dynamic_report ()) in
  let static = D.static_facts_of_why_effect (static_report ()) in
  ignore (D.make_snapshot ~dynamic:(Some dynamic) ~static:(Some static) |> expect_ok "linked A/B");
  let other_operation = operation ~name:"workspace.fetch" () in
  let mismatched_dynamic =
    D.dynamic_facts_of_explain (dynamic_report ~operation:other_operation ())
  in
  expect_code "operation mismatch" "E1539"
    (D.make_snapshot ~dynamic:(Some mismatched_dynamic) ~static:(Some static));
  let attempted =
    Governance_explain.Attempted
      {
        state = "attempt-outcome-unknown";
        attempt_id = hash "attempt";
        driver_name = "wrong-driver";
        driver_id = hash "wrong-driver";
        receipt_id = None;
        external_receipt_digest = None;
      }
  in
  expect_code "driver mismatch" "E1539"
    (D.make_snapshot
       ~dynamic:(Some (D.dynamic_facts_of_explain (dynamic_report ~attempt:attempted ())))
       ~static:(Some static));
  let conflicting_label = { W.name = "conflicting-label"; hash = (operation ()).hash } in
  let duplicate =
    static_report ~facade_operations:[ operation (); conflicting_label ] ()
    |> D.static_facts_of_why_effect
  in
  expect_code "conflicting identity labels" "E1540"
    (D.make_snapshot ~dynamic:None ~static:(Some duplicate));
  let conflicting_detail =
    static_report
      ~reached_operations:
        [ operation_fact (); operation_fact ~driver:(identity "different-driver") () ]
      ()
    |> D.static_facts_of_why_effect
  in
  expect_code "conflicting operation facts" "E1540"
    (D.make_snapshot ~dynamic:None ~static:(Some conflicting_detail));
  let foreign = operation ~name:"foreign" () in
  let malformed =
    static_report ~reached_operations:[ operation_fact ~operation:foreign () ] ()
    |> D.static_facts_of_why_effect
  in
  expect_code "reached outside facade" "E1541"
    (D.make_snapshot ~dynamic:None ~static:(Some malformed));
  expect_code "requested-effect comparison mismatch" "E1539"
    (D.classify_static ~old_:static
       ~new_:(D.static_facts_of_why_effect (static_report ~requested_effect:(identity "Net") ())));
  let static_only =
    D.make_snapshot ~dynamic:None ~static:(Some static) |> expect_ok "static only"
  in
  let dynamic_only =
    D.make_snapshot ~dynamic:(Some dynamic) ~static:None |> expect_ok "dynamic only"
  in
  expect_code "family mismatch" "E1539" (D.compare ~old_:static_only ~new_:dynamic_only)

let test_shuffled_determinism_and_renderers () =
  let read = { W.name = "workspace.read-file"; hash = hash "read-operation" } in
  let write = operation () in
  let old_report =
    static_report ~facade_operations:[ read; write ]
      ~reached_operations:
        [
          operation_fact ~operation:read ~row:[ authority "Net"; authority "Fs" ] ();
          operation_fact ~operation:write ();
        ]
      ()
  in
  let new_report =
    static_report ~facade_operations:[ write; read ]
      ~reached_operations:
        [
          operation_fact ~operation:write ~driver:(identity "new-driver") ();
          operation_fact ~operation:read ~row:[ authority "Secret"; authority "Fs" ] ();
        ]
      ()
  in
  let snapshot report =
    D.make_snapshot ~dynamic:None ~static:(Some (D.static_facts_of_why_effect report))
    |> expect_ok "determinism snapshot"
  in
  let first =
    D.compare ~old_:(snapshot old_report) ~new_:(snapshot new_report) |> expect_ok "first"
  in
  let shuffled_old =
    {
      old_report with
      facade_operations = List.rev old_report.facade_operations;
      reached_operations = List.rev old_report.reached_operations;
    }
  in
  let shuffled_new =
    {
      new_report with
      facade_operations = List.rev new_report.facade_operations;
      reached_operations = List.rev new_report.reached_operations;
    }
  in
  let second =
    D.compare ~old_:(snapshot shuffled_old) ~new_:(snapshot shuffled_new) |> expect_ok "second"
  in
  let text = D.render_text first in
  let json = D.render_json_v1 first in
  Alcotest.(check string) "shuffled text bytes" text (D.render_text second);
  Alcotest.(check string) "shuffled JSON bytes" json (D.render_json_v1 second);
  Alcotest.(check string) "repeated text bytes" text (D.render_text first);
  Alcotest.(check string) "repeated JSON bytes" json (D.render_json_v1 first);
  let parsed = Yojson.Safe.from_string json in
  let open Yojson.Safe.Util in
  Alcotest.(check string) "schema parity" D.schema (parsed |> member "schema" |> to_string);
  Alcotest.(check string)
    "completeness parity"
    (D.completeness_to_string first.completeness)
    (parsed |> member "completeness" |> to_string);
  Alcotest.(check int)
    "change count parity" (List.length first.changes)
    (parsed |> member "changes" |> to_list |> List.length);
  Alcotest.(check int)
    "unavailable count parity" (List.length first.unavailable)
    (parsed |> member "unavailable" |> to_list |> List.length);
  Alcotest.(check bool)
    "report assigns no safety" true
    (List.mem "does-not-assign-safety-verdict" first.evidence_limits)

let suite =
  [
    Alcotest.test_case "facade and driver-row categories" `Quick test_facade_and_row_categories;
    Alcotest.test_case "semantic and rendering-only categories" `Quick
      test_semantic_and_rendering_categories;
    Alcotest.test_case "labels, partial detail, and no-change" `Quick
      test_labels_partial_and_no_change;
    Alcotest.test_case "exact linkage, duplicates, and invariants" `Quick
      test_linkage_duplicates_and_invariants;
    Alcotest.test_case "shuffled determinism and renderer parity" `Quick
      test_shuffled_determinism_and_renderers;
  ]
