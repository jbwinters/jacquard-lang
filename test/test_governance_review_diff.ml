open Jacquard
module D = Governance_review_diff
module W = Governance_why_effect

let hash value = Hash.of_string value
let identity name = { W.name; hash = hash name }
let form name = Form.form name []
let code_form head children = Form.form head (List.map (fun child -> Form.F child) children)
let hash_code value = Form.form "hash" [ Form.Hash value ]
let lit value = Form.form "lit" [ Form.Text value ]

let approved ?(evidence = code_form "approval-proof-v1" []) proposal_id =
  code_form "approved-v1" [ hash_code proposal_id; lit "reviewer"; evidence ]

let denied proposal_id =
  code_form "denied-v1" [ hash_code proposal_id; lit "reviewer"; lit "policy denied" ]

let escalated proposal_id = code_form "escalate-v1" [ hash_code proposal_id; lit "needs owner" ]
let operation ?(name = "workspace.write-file") () = { W.name; hash = hash (name ^ ".identity") }
let authority name = identity name

let chain ?(source_path = [ identity "source-root" ]) ?(member = identity "source-member")
    ?(ordinal = 0) ?(operation = operation ()) ?(forwarding_layers = [ identity "forward" ])
    ?(live_leaf = identity "live-leaf") ?(driver = identity "driver") ?(raw_effect = identity "Fs")
    () : W.chain =
  {
    source_path;
    application_site = { member; ordinal };
    operation;
    forwarding_layers;
    live_leaf;
    driver;
    raw_effect;
  }

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

let static_report ?(requested_effect = identity "Fs") ?(source_root = identity "source-root")
    ?(topology = "direct-live") ?(facade = identity "Workspace")
    ?(facade_operations = [ operation () ]) ?(reached_operations = [ operation_fact () ])
    ?(chains = []) () : W.report =
  { requested_effect; source_root; topology; facade; facade_operations; reached_operations; chains }

let dynamic_report ?(proposal_id = hash "proposal") ?(rendering = form "rendering")
    ?(summary = "summary") ?(call_id = hash "call") ?(operation = operation ())
    ?(call = form "call") ?(authority = form "authority") ?(policy_id = hash "policy")
    ?(policy = form "policy") ?(assessment_id = hash "assessment") ?(assessment = form "assessment")
    ?(preview = form "preview") ?(policy_rule = "live.at-or-below-ask") ?(recorded_verdict = "ask")
    ?(decision_kind = "approved") ?decision ?(attempt = Governance_explain.Not_attempted) () :
    Governance_explain.report =
  let decision = Option.value decision ~default:(approved proposal_id) in
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
      ~decision:(approved proposal_id) ()
  in
  check_kinds "proposal rendering only" [ D.Proposal_rendering_only ]
    (classify_dynamic old_dynamic new_dynamic);
  let check_non_action_rendering_only label decision_kind make_decision =
    let old_id = hash (label ^ "-old") in
    let new_id = hash (label ^ "-new") in
    let old_ =
      dynamic_report ~proposal_id:old_id ~decision_kind ~decision:(make_decision old_id) ()
    in
    let new_ =
      dynamic_report ~proposal_id:new_id ~decision_kind ~decision:(make_decision new_id)
        ~rendering:(form (decision_kind ^ "-rendering"))
        ()
    in
    check_kinds label [ D.Proposal_rendering_only ] (classify_dynamic old_ new_)
  in
  check_non_action_rendering_only "denied released carrier" "denied" denied;
  check_non_action_rendering_only "escalated released carrier" "escalated" escalated;
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
      ~decision:(approved proposal_id) ()
  in
  check_kinds "attempt evidence blocks rendering-only" [ D.Proposal_rendering_changed ]
    (classify_dynamic attempted_old attempted_new);
  let old_with_proposal_like_evidence =
    dynamic_report
      ~decision:
        (approved
           ~evidence:(code_form "approval-proof-v1" [ hash_code (hash "proposal") ])
           (hash "proposal"))
      ()
  in
  let new_with_proposal_like_evidence =
    dynamic_report ~proposal_id ~rendering:(form "new-rendering") ~summary:"new summary"
      ~decision:
        (approved ~evidence:(code_form "approval-proof-v1" [ hash_code proposal_id ]) proposal_id)
      ()
  in
  check_kinds "proposal-like evidence is semantic"
    [ D.Decision_changed; D.Proposal_rendering_changed ]
    (classify_dynamic old_with_proposal_like_evidence new_with_proposal_like_evidence)

let test_labels_partial_and_no_change () =
  let renamed_operation = { W.name = "write-label-only"; hash = (operation ()).hash } in
  let renamed =
    static_report ~facade_operations:[ renamed_operation ]
      ~reached_operations:[ operation_fact ~operation:renamed_operation () ]
      ()
  in
  check_kinds "name is label, not add/remove" [ D.Label_changed ]
    (classify_static (static_report ()) renamed);
  let first_chain = chain () in
  let second_site = chain ~ordinal:1 () in
  let with_first = static_report ~chains:[ first_chain ] () in
  check_kinds "attribution added" [ D.Attribution_changed ]
    (classify_static (static_report ()) with_first);
  check_kinds "attribution removed" [ D.Attribution_changed ]
    (classify_static with_first (static_report ()));
  check_kinds "application ordinal is semantic" [ D.Attribution_changed ]
    (classify_static with_first (static_report ~chains:[ second_site ] ()));
  check_kinds "one and two application sites differ" [ D.Attribution_changed ]
    (classify_static with_first (static_report ~chains:[ second_site; first_chain ] ()));
  check_kinds "application member is semantic" [ D.Attribution_changed ]
    (classify_static with_first
       (static_report ~chains:[ chain ~member:(identity "other-member") () ] ()));
  check_kinds "source path is semantic" [ D.Attribution_changed ]
    (classify_static with_first
       (static_report ~chains:[ chain ~source_path:[ identity "other-path" ] () ] ()));
  check_kinds "forwarding path is semantic" [ D.Attribution_changed ]
    (classify_static with_first
       (static_report ~chains:[ chain ~forwarding_layers:[ identity "other-forward" ] () ] ()));
  check_kinds "source root identity" [ D.Source_root_changed ]
    (classify_static (static_report ())
       (static_report ~source_root:(identity "other-source-root") ()));
  let renamed_root = { W.name = "source-root-label"; hash = (identity "source-root").hash } in
  check_kinds "source root name is non-semantic" [ D.Label_changed ]
    (classify_static (static_report ()) (static_report ~source_root:renamed_root ()));
  let renamed_member = { W.name = "source-member-label"; hash = (identity "source-member").hash } in
  check_kinds "attribution names are non-semantic" [ D.Label_changed ]
    (classify_static with_first (static_report ~chains:[ chain ~member:renamed_member () ] ()));
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
  let conflicting_root_in_chain =
    { W.name = "conflicting-root-label"; hash = (identity "source-root").hash }
  in
  let duplicate_chain_label =
    static_report ~chains:[ chain ~source_path:[ conflicting_root_in_chain ] () ] ()
    |> D.static_facts_of_why_effect
  in
  expect_code "chain cross-field identity labels" "E1540"
    (D.make_snapshot ~dynamic:None ~static:(Some duplicate_chain_label));
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
  let listed = operation ~name:"workspace.list-directory" () in
  let first_chain = chain ~ordinal:0 () in
  let second_chain = chain ~ordinal:1 () in
  check_kinds "chain collection order is non-semantic" []
    (classify_static
       (static_report ~chains:[ first_chain; second_chain ] ())
       (static_report ~chains:[ second_chain; first_chain ] ()));
  let old_report =
    static_report ~facade_operations:[ listed; read; write ]
      ~reached_operations:
        [
          operation_fact ~operation:read ~row:[ authority "Net"; authority "Fs" ] ();
          operation_fact ~operation:write ();
        ]
      ~chains:[ second_chain; first_chain ] ()
  in
  let new_report =
    static_report ~facade_operations:[ write; listed; read ]
      ~reached_operations:
        [
          operation_fact ~operation:write ~driver:(identity "new-driver") ();
          operation_fact ~operation:read ~row:[ authority "Secret"; authority "Fs" ] ();
        ]
      ~chains:[ first_chain; second_chain ] ()
  in
  let old_dynamic = D.dynamic_facts_of_explain (dynamic_report ()) in
  let new_dynamic =
    D.dynamic_facts_of_explain
      (dynamic_report ~policy_id:(hash "new-policy") ~policy:(form "new-policy") ())
  in
  let snapshot dynamic report =
    D.make_snapshot ~dynamic:(Some dynamic) ~static:(Some (D.static_facts_of_why_effect report))
    |> expect_ok "determinism snapshot"
  in
  let first =
    D.compare ~old_:(snapshot old_dynamic old_report) ~new_:(snapshot new_dynamic new_report)
    |> expect_ok "first"
  in
  let shuffled_old =
    {
      old_report with
      facade_operations = List.rev old_report.facade_operations;
      reached_operations = List.rev old_report.reached_operations;
      chains = List.rev old_report.chains;
    }
  in
  let shuffled_new =
    {
      new_report with
      facade_operations = List.rev new_report.facade_operations;
      reached_operations = List.rev new_report.reached_operations;
      chains = List.rev new_report.chains;
    }
  in
  let second =
    D.compare ~old_:(snapshot old_dynamic shuffled_old) ~new_:(snapshot new_dynamic shuffled_new)
    |> expect_ok "second"
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
  let text_lines = String.split_on_char '\n' text in
  let shown_identity = function
    | None -> "none"
    | Some value -> Printf.sprintf "%s #%s" value.D.name (Hash.to_hex value.hash)
  in
  List.iter
    (fun (change : D.change) ->
      let expected =
        Printf.sprintf "change kind=%s subject=%s #%s old=%s new=%s"
          (D.change_kind_to_string change.kind)
          change.subject.name (Hash.to_hex change.subject.hash)
          (shown_identity change.old_identity)
          (shown_identity change.new_identity)
      in
      Alcotest.(check bool) "text change field parity" true (List.mem expected text_lines))
    first.changes;
  List.iter
    (fun (value : D.unavailable) ->
      let side = match value.side with D.Old -> "old" | D.New -> "new" | D.Both -> "both" in
      let expected =
        Printf.sprintf "unavailable subject=%s #%s side=%s reason=%s" value.subject.name
          (Hash.to_hex value.subject.hash) side value.reason
      in
      Alcotest.(check bool) "text unavailable field parity" true (List.mem expected text_lines))
    first.unavailable;
  let check_json_identity label expected value =
    Alcotest.(check string) (label ^ " name") expected.D.name (value |> member "name" |> to_string);
    Alcotest.(check string)
      (label ^ " identity") (Hash.to_hex expected.hash)
      (value |> member "identity" |> to_string)
  in
  let check_optional_identity label expected value =
    match expected with
    | None -> Alcotest.(check bool) (label ^ " null") true (value = `Null)
    | Some expected -> check_json_identity label expected value
  in
  List.iter2
    (fun (change : D.change) value ->
      Alcotest.(check string)
        "JSON change kind"
        (D.change_kind_to_string change.kind)
        (value |> member "kind" |> to_string);
      check_json_identity "JSON change subject" change.subject (value |> member "subject");
      check_optional_identity "JSON change old" change.old_identity (value |> member "old");
      check_optional_identity "JSON change new" change.new_identity (value |> member "new"))
    first.changes
    (parsed |> member "changes" |> to_list);
  List.iter2
    (fun (unavailable : D.unavailable) value ->
      let side = match unavailable.side with D.Old -> "old" | D.New -> "new" | D.Both -> "both" in
      check_json_identity "JSON unavailable subject" unavailable.subject (value |> member "subject");
      Alcotest.(check string) "JSON unavailable side" side (value |> member "side" |> to_string);
      Alcotest.(check string)
        "JSON unavailable reason" unavailable.reason
        (value |> member "reason" |> to_string))
    first.unavailable
    (parsed |> member "unavailable" |> to_list);
  Alcotest.(check (list string))
    "JSON evidence fields" first.evidence_limits
    (parsed |> member "evidence_limits" |> to_list |> List.map to_string);
  List.iter
    (fun limit ->
      Alcotest.(check bool)
        "text evidence field parity" true
        (List.mem ("evidence-limit " ^ limit) text_lines))
    first.evidence_limits;
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
