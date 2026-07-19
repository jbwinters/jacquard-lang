open Jacquard

let store, _ctx = Eval_support.make_prelude_ctx ()
let form head values = Form.form head (List.map (fun value -> Form.F value) values)
let hash seed = Hash.of_string ("gm14-test:" ^ seed)
let hash_form value = Form.form "hash" [ Form.Hash value ]
let lit value = Form.form "lit" [ Form.Text value ]
let int value = Form.form "lit" [ Form.Int value ]
let real value = Form.form "lit" [ Form.Real value ]
let version = form "governance-v0" []
let none = form "none-v0" []
let some_hash value = form "some-v0" [ hash_form value ]
let code_hash value = Hash.of_string (Printer.print_compact value)

let authority seed =
  form "governance-authority-list-v0"
    [ form "governance-effect-v0" [ hash_form (hash (seed ^ ":effect")) ] ]

let workspace_write_id =
  match Store.lookup_kind store "workspace.write-file" Resolve.KOp with
  | Some { Resolve.hash; _ } -> hash
  | None -> Alcotest.fail "prelude has no resolved workspace.write-file operation"

type call = { id : Hash.t; artifact : Form.t; authority : Form.t }
type policy = { id : Hash.t; artifact : Form.t }
type assessment = { id : Hash.t; artifact : Form.t }
type proposal = { id : Hash.t; artifact : Form.t }

let make_call ?parent ?(authority = authority "workspace") seed : call =
  let operation_id = workspace_write_id in
  let arguments = form "arguments-v1" [ lit seed ] in
  let preconditions = form "preconditions-v1" [ lit (seed ^ ":expected") ] in
  let parent = match parent with None -> none | Some id -> some_hash id in
  let subject =
    form "governance-call-v0"
      [ version; hash_form operation_id; arguments; authority; preconditions; parent ]
  in
  let id = code_hash subject in
  let artifact =
    form "governance-call-artifact-v1"
      [
        version;
        hash_form id;
        hash_form operation_id;
        lit "workspace.write-file";
        arguments;
        authority;
        lit ("write " ^ seed);
        preconditions;
        parent;
      ]
  in
  { id; artifact; authority }

let make_policy () : policy =
  let value = form "live-policy-v0" [ version; form "low" []; form "high" []; real 0.8 ] in
  let id = code_hash value in
  { id; artifact = form "bound-policy-artifact-v1" [ version; hash_form id; value ] }

let make_assessment () : assessment =
  let artifact =
    form "governance-assessment-v0"
      [
        version;
        form "medium" [];
        real 0.95;
        form "text-list-v1" [ lit "policy match" ];
        form "assessment-evidence-v1" [ lit "rules-v1" ];
      ]
  in
  { id = code_hash artifact; artifact }

let make_proposal ?authority (call : call) (policy : policy) (assessment : assessment) seed :
    proposal =
  let authority = Option.value ~default:call.authority authority in
  let rendering = form "review-v1" [ lit seed ] in
  let summary = "approve " ^ seed in
  let preview = none in
  let subject =
    form "governance-proposal-v0"
      [
        version;
        hash_form call.id;
        hash_form policy.id;
        hash_form assessment.id;
        authority;
        preview;
        rendering;
        lit summary;
      ]
  in
  let id = code_hash subject in
  let artifact =
    form "governance-proposal-artifact-v1"
      [
        version;
        hash_form id;
        hash_form call.id;
        hash_form policy.id;
        hash_form assessment.id;
        rendering;
        lit summary;
        authority;
        preview;
      ]
  in
  { id; artifact }

let evaluated sequence (call : call) (policy : policy) (assessment : assessment) verdict =
  form "audit-entry-v2"
    [
      form "evaluated-v2"
        [
          version;
          int sequence;
          hash_form call.id;
          hash_form policy.id;
          assessment.artifact;
          form verdict [];
        ];
    ]

let consented sequence (call : call) (proposal : proposal) =
  let decision =
    form "approved-v1"
      [ hash_form proposal.id; lit "principal:reviewer-1"; form "approval-proof-v1" [] ]
  in
  form "audit-entry-v2"
    [
      form "consented-v2"
        [ version; int sequence; hash_form call.id; hash_form proposal.id; decision ];
    ]

let completed sequence (call : call) =
  let outcome =
    form "governance-outcome-summary-v0"
      [ version; lit "ok"; hash_form (hash "receipt"); lit "receipt stored by test driver" ]
  in
  form "audit-entry-v2"
    [ form "completed-v2" [ version; int sequence; hash_form call.id; lit "live"; outcome ] ]

let record_form record =
  match Reader.parse_one ~file:"rendered-audit-record" (Audit_chain.render record) with
  | Ok value -> value
  | Error diagnostics ->
      Alcotest.failf "cannot parse rendered Audit record: %s"
        (String.concat "; " (List.map Diag.to_string diagnostics))

let chain entries =
  let rec loop previous reversed = function
    | [] -> (List.rev reversed, previous)
    | entry :: rest -> (
        match Audit_chain.append ~previous entry with
        | Ok record -> loop (Audit_chain.head record) (record_form record :: reversed) rest
        | Error diagnostics ->
            Alcotest.failf "cannot build Audit chain: %s"
              (String.concat "; " (List.map Diag.to_string diagnostics)))
  in
  loop Audit_chain.genesis [] entries

let bundle ~head ~records ~calls ~policies ~assessments ~proposals =
  form "governance-run-bundle-v1"
    [
      Form.form "published-head-v1" [ Form.Hash head ];
      form "audit-records-v1" records;
      form "governance-call-artifacts-v1" calls;
      form "bound-policy-artifacts-v1" policies;
      form "governance-assessment-artifacts-v1" assessments;
      form "governance-proposal-artifacts-v1" proposals;
    ]

type fixture = {
  root : call;
  child : call;
  policy : policy;
  assessment : assessment;
  proposal : proposal;
  records : Form.t list;
  head : Hash.t;
  bundle : Form.t;
}

let fixture () =
  let root = make_call "root" in
  let child = make_call ~parent:root.id "child" in
  let policy = make_policy () in
  let assessment = make_assessment () in
  let proposal = make_proposal child policy assessment "child" in
  let entries =
    [
      evaluated 0 root policy assessment "block";
      evaluated 1 child policy assessment "ask";
      consented 2 child proposal;
      completed 3 child;
    ]
  in
  let records, head = chain entries in
  let bundle =
    bundle ~head ~records ~calls:[ root.artifact; child.artifact ] ~policies:[ policy.artifact ]
      ~assessments:[ assessment.artifact ] ~proposals:[ proposal.artifact ]
  in
  { root; child; policy; assessment; proposal; records; head; bundle }

let verify value = Governance_run_bundle.verify_form ~store ~file:"test.bundle" value

let fail_diags label diagnostics =
  Alcotest.failf "%s: %s" label (String.concat "; " (List.map Diag.to_string diagnostics))

let expect_error ?(indexed = true) label code result =
  match result with
  | Error ({ Diag.code = actual; message; _ } :: _) ->
      Alcotest.(check string) (label ^ " code") code actual;
      if indexed then
        Alcotest.(check bool)
          (label ^ " has indexed detail") true
          (String.contains message '0' || String.contains message '1')
  | Error [] -> Alcotest.failf "%s returned no diagnostics" label
  | Ok _ -> Alcotest.failf "%s unexpectedly verified" label

let test_valid_bundle_and_canonical_file () =
  let fixture = fixture () in
  (match verify fixture.bundle with
  | Error diagnostics -> fail_diags "valid governance run bundle" diagnostics
  | Ok report ->
      Alcotest.(check string) "head" (Hash.to_hex fixture.head) (Hash.to_hex report.head);
      Alcotest.(check int) "entries" 4 report.entries;
      Alcotest.(check int) "calls" 2 report.calls;
      Alcotest.(check int) "policies" 1 report.policies;
      Alcotest.(check int) "assessments" 1 report.assessments;
      Alcotest.(check int) "proposals" 1 report.proposals;
      Alcotest.(check int) "consents" 1 report.consents;
      Alcotest.(check int) "transformed Calls" 1 report.transformed_calls);
  let bytes = Printer.print_compact fixture.bundle ^ "\n" in
  (match Governance_run_bundle.verify_string ~store ~file:"canonical.bundle" bytes with
  | Ok _ -> ()
  | Error diagnostics -> fail_diags "canonical bundle bytes" diagnostics);
  expect_error ~indexed:false "missing final LF" "E1500"
    (Governance_run_bundle.verify_string ~store ~file:"no-lf.bundle"
       (Printer.print_compact fixture.bundle))

let replace_carried replacement = function
  | { Form.head = "governance-call-artifact-v1"; args = first :: _ :: rest; meta } ->
      {
        Form.head = "governance-call-artifact-v1";
        args = first :: Form.F (hash_form replacement) :: rest;
        meta;
      }
  | value -> value

let replace_operation replacement = function
  | {
      Form.head = "governance-call-artifact-v1";
      args = version :: carried :: _operation :: rest;
      meta;
    } ->
      {
        Form.head = "governance-call-artifact-v1";
        args = version :: carried :: Form.F (hash_form replacement) :: rest;
        meta;
      }
  | value -> value

let replace_digest replacement = function
  | { Form.head = "audit-chain-v2"; args = previous :: _ :: rest; meta } ->
      { Form.head = "audit-chain-v2"; args = previous :: Form.Hash replacement :: rest; meta }
  | value -> value

let test_identity_duplicate_missing_and_chain_failures () =
  let fixture = fixture () in
  let bad_call = replace_carried (hash "forged-call") fixture.root.artifact in
  expect_error "forged Call identity" "E1501"
    (verify
       (bundle ~head:fixture.head ~records:fixture.records
          ~calls:[ bad_call; fixture.child.artifact ]
          ~policies:[ fixture.policy.artifact ] ~assessments:[ fixture.assessment.artifact ]
          ~proposals:[ fixture.proposal.artifact ]));
  let mismatched_operation = replace_operation (hash "other-operation") fixture.root.artifact in
  expect_error "mismatched operation identity" "E1501"
    (verify
       (bundle ~head:fixture.head ~records:fixture.records
          ~calls:[ mismatched_operation; fixture.child.artifact ]
          ~policies:[ fixture.policy.artifact ] ~assessments:[ fixture.assessment.artifact ]
          ~proposals:[ fixture.proposal.artifact ]));
  expect_error "duplicate Call" "E1502"
    (verify
       (bundle ~head:fixture.head ~records:fixture.records
          ~calls:[ fixture.root.artifact; fixture.child.artifact; fixture.child.artifact ]
          ~policies:[ fixture.policy.artifact ] ~assessments:[ fixture.assessment.artifact ]
          ~proposals:[ fixture.proposal.artifact ]));
  expect_error "missing Proposal" "E1503"
    (verify
       (bundle ~head:fixture.head ~records:fixture.records
          ~calls:[ fixture.root.artifact; fixture.child.artifact ]
          ~policies:[ fixture.policy.artifact ] ~assessments:[ fixture.assessment.artifact ]
          ~proposals:[]));
  let bad_records =
    match fixture.records with
    | first :: rest -> replace_digest (hash "bad-record-digest") first :: rest
    | [] -> Alcotest.fail "fixture unexpectedly has no Audit records"
  in
  expect_error "Audit digest mutation" "E1304"
    (verify
       (bundle ~head:fixture.head ~records:bad_records
          ~calls:[ fixture.root.artifact; fixture.child.artifact ]
          ~policies:[ fixture.policy.artifact ] ~assessments:[ fixture.assessment.artifact ]
          ~proposals:[ fixture.proposal.artifact ]))

let test_proposal_linkage_lineage_and_unused_artifacts () =
  let fixture = fixture () in
  let standalone = make_call "standalone" in
  let conflicting_authority = authority "conflicting" in
  let conflicting_proposal =
    make_proposal ~authority:conflicting_authority standalone fixture.policy fixture.assessment
      "conflicting"
  in
  let entries =
    [
      evaluated 0 standalone fixture.policy fixture.assessment "ask";
      consented 1 standalone conflicting_proposal;
    ]
  in
  let records, head = chain entries in
  expect_error "Proposal authority mismatch" "E1505"
    (verify
       (bundle ~head ~records ~calls:[ standalone.artifact ] ~policies:[ fixture.policy.artifact ]
          ~assessments:[ fixture.assessment.artifact ] ~proposals:[ conflicting_proposal.artifact ]));
  let orphan = make_call ~parent:(hash "missing-parent") "orphan" in
  let records, head = chain [ evaluated 0 orphan fixture.policy fixture.assessment "block" ] in
  expect_error "missing parent lineage" "E1506"
    (verify
       (bundle ~head ~records ~calls:[ orphan.artifact ] ~policies:[ fixture.policy.artifact ]
          ~assessments:[ fixture.assessment.artifact ] ~proposals:[]));
  let extra = make_proposal fixture.child fixture.policy fixture.assessment "unused" in
  expect_error "unused Proposal" "E1507"
    (verify
       (bundle ~head:fixture.head ~records:fixture.records
          ~calls:[ fixture.root.artifact; fixture.child.artifact ]
          ~policies:[ fixture.policy.artifact ] ~assessments:[ fixture.assessment.artifact ]
          ~proposals:[ fixture.proposal.artifact; extra.artifact ]))

let suite =
  [
    Alcotest.test_case "valid bundle and canonical file" `Quick test_valid_bundle_and_canonical_file;
    Alcotest.test_case "identity, duplicate, missing, and chain failures" `Quick
      test_identity_duplicate_missing_and_chain_failures;
    Alcotest.test_case "Proposal linkage, lineage, and unused artifacts" `Quick
      test_proposal_linkage_lineage_and_unused_artifacts;
  ]
