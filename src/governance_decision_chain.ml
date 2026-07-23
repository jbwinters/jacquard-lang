type authority =
  | Effect of { effect_id : Hash.t }
  | Resource of { effect_id : Hash.t; configuration_id : Hash.t; opaque_subject : string }

type stage = Request | Assessment | Verdict | Consent | Activity | Outcome
type source = Verified | Fixture
type verdict = Allow | Ask | Block | Simulate
type consent = Not_required | Approved | Denied | Escalated | Stale | Missing

type fixture_scenario =
  | Allow_fixture
  | Block_fixture
  | Stale_approval_fixture
  | Transformed_call_fixture
  | Missing_completion_fixture
  | Dry_simulation_fixture

type audit = { kind : string; digest : Hash.t }

type t = {
  source : source;
  proposal_id : Hash.t;
  call_id : Hash.t;
  operation_name : string;
  operation_id : Hash.t;
  parent_call_id : Hash.t option;
  authority : authority list;
  policy_id : Hash.t;
  assessment_id : Hash.t;
  policy_rule : string;
  verdict : verdict;
  consent : consent;
  audit : audit list;
  completion_id : Hash.t option;
  attempt : Governance_explain.attempt_state;
  simulation_not_consent : bool;
}

let schema = "jacquard-governance-decision-chain-v1"
let profile = "workspace-v0"

let evidence_limits =
  [
    "committed-driver-not-execution-proof";
    "external-receipt-digest-not-receipt-truth";
    "resource-scope-not-type-proof";
    "missing-completion-not-rollback";
  ]

let ( let* ) = Result.bind

let error fmt =
  Printf.ksprintf
    (fun cause ->
      Error
        [
          Diag.error ~domain:Governance ~code:"E1542"
            ~summary:"A governance decision-chain presentation cannot be derived safely." ~cause
            ~next_step:
              "Regenerate the projection from one unchanged typed, verified governance explanation."
            ~contrast:None ();
        ])
    fmt

let compact value = Printer.print_compact value
let semantic_hash value = Hash.of_string (compact value)
let hash_equal left right = Hash.equal left right

let hash_value = function
  | { Form.head = "hash"; args = [ Form.Hash value ]; _ } -> Some value
  | _ -> None

let text_value = function
  | { Form.head = "lit"; args = [ Form.Text value ]; _ } -> Some value
  | _ -> None

let forms args =
  let rec loop reversed = function
    | [] -> Some (List.rev reversed)
    | Form.F value :: rest -> loop (value :: reversed) rest
    | _ -> None
  in
  loop [] args

let opaque kind hash = kind ^ ":" ^ Hash.to_hex hash

let authority_subject effect_id configuration_id =
  opaque "resource"
    (Hash.of_string
       ("governance-resource-v0:" ^ Hash.to_hex effect_id ^ ":" ^ Hash.to_hex configuration_id))

let parse_authority value =
  match value with
  | { Form.head = "governance-authority-list-v0"; args; _ } -> (
      match forms args with
      | None -> error "authority evidence contains a scalar member"
      | Some entries ->
          let parse = function
            | { Form.head = "governance-effect-v0"; args = [ Form.F effect_value ]; _ } -> (
                match hash_value effect_value with
                | Some effect_id -> Ok (Effect { effect_id })
                | None -> error "effect authority has no exact HASH_V0 identity")
            | {
                Form.head = "governance-resource-v0";
                args = [ Form.F effect_value; Form.F scope; Form.F configuration ];
                _;
              } -> (
                match (hash_value effect_value, text_value scope, hash_value configuration) with
                | Some effect_id, Some scope, Some configuration_id when String.length scope > 0 ->
                    Ok
                      (Resource
                         {
                           effect_id;
                           configuration_id;
                           opaque_subject = authority_subject effect_id configuration_id;
                         })
                | Some _, Some "", Some _ -> error "resource authority has an empty scope"
                | _ -> error "resource authority has malformed typed evidence")
            | _ -> error "authority contains an unsupported evidence kind"
          in
          let rec collect reversed = function
            | [] -> Ok (List.rev reversed)
            | entry :: rest ->
                let* parsed = parse entry in
                collect (parsed :: reversed) rest
          in
          collect [] entries)
  | _ -> error "report raw authority is not a governance-authority-list-v0 carrier"

let parse_parent = function
  | { Form.head = "none-v0"; args = []; _ } -> Ok None
  | { Form.head = "some-v0"; args = [ Form.F value ]; _ } -> (
      match hash_value value with
      | Some hash -> Ok (Some hash)
      | None -> error "Call parent has no exact HASH_V0 identity")
  | _ -> error "Call parent is not a canonical option carrier"

let parse_call report =
  match report.Governance_explain.call with
  | {
   Form.head = "governance-call-v0";
   args =
     [
       Form.F _version;
       Form.F operation;
       Form.F _arguments;
       Form.F authority;
       Form.F _preconditions;
       Form.F parent;
     ];
   _;
  } -> (
      match hash_value operation with
      | None -> error "Call has no exact operation HASH_V0 identity"
      | Some operation_id when not (hash_equal operation_id report.operation_id) ->
          error "Call operation identity disagrees with the typed report"
      | Some _ when not (hash_equal (semantic_hash report.call) report.call_id) ->
          error "Call identity does not match its canonical typed carrier"
      | Some _ when not (String.equal (compact authority) (compact report.raw_authority)) ->
          error "Call authority disagrees with the typed report"
      | Some _ ->
          let* parent_call_id = parse_parent parent in
          let* authority = parse_authority authority in
          Ok (parent_call_id, authority))
  | _ -> error "report Call is not a canonical governance-call-v0 carrier"

let parse_proposal report =
  match report.Governance_explain.proposal with
  | {
   Form.head = "governance-proposal-v0";
   args =
     [
       Form.F _version;
       Form.F call;
       Form.F policy;
       Form.F assessment;
       Form.F authority;
       Form.F _preview;
       Form.F _rendering;
       Form.F summary;
     ];
   _;
  } -> (
      match (hash_value call, hash_value policy, hash_value assessment, text_value summary) with
      | Some call_id, Some policy_id, Some assessment_id, Some summary
        when hash_equal call_id report.call_id
             && hash_equal policy_id report.policy_id
             && hash_equal assessment_id report.assessment_id
             && String.equal summary report.proposal_summary
             && String.equal (compact authority) (compact report.raw_authority)
             && hash_equal (semantic_hash report.proposal) report.proposal_id ->
          Ok ()
      | _ -> error "Proposal links, identity, summary, or authority disagree with the typed report")
  | _ -> error "report Proposal is not a canonical governance-proposal-v0 carrier"

let parse_policy report =
  match report.Governance_explain.bound_policy with
  | { Form.head = "bound-policy-v0"; args = [ Form.F _version; Form.F carried; Form.F _value ]; _ }
    -> (
      match hash_value carried with
      | Some policy_id when hash_equal policy_id report.policy_id -> Ok ()
      | _ -> error "bound policy identity disagrees with the typed report")
  | _ -> error "report policy is not a canonical bound-policy-v0 carrier"

let parse_assessment report =
  match report.Governance_explain.assessment with
  | { Form.head = "governance-assessment-v0"; _ }
    when hash_equal (semantic_hash report.assessment) report.assessment_id ->
      Ok ()
  | { Form.head = "governance-assessment-v0"; _ } ->
      error "assessment identity does not match its canonical typed carrier"
  | _ -> error "report assessment is not a governance-assessment-v0 carrier"

let validate_operation (report : Governance_explain.report) =
  match Governance_source_check.canonical_workspace_driver ~operation:report.operation_id with
  | None -> error "report operation is outside the released Workspace v0 profile"
  | Some (operation_name, _, _) when not (String.equal operation_name report.operation_name) ->
      error "report operation name disagrees with its canonical Workspace identity"
  | Some (_, canonical_driver_name, canonical_driver_id) -> (
      match report.Governance_explain.attempt with
      | Governance_explain.Not_attempted -> Ok ()
      | Governance_explain.Attempted value
        when String.equal value.driver_name canonical_driver_name
             && hash_equal value.driver_id canonical_driver_id ->
          Ok ()
      | Governance_explain.Attempted _ ->
          error "attempted action driver disagrees with the canonical Workspace operation")

let decision_head = function
  | "approved" -> "approved-v1"
  | "denied" -> "denied-v1"
  | "escalated" -> "escalate-v1"
  | value -> value

let parse_decision report =
  match report.Governance_explain.decision with
  | { Form.head; args = Form.F proposal :: _; _ }
    when String.equal head (decision_head report.decision_kind) -> (
      match hash_value proposal with
      | Some proposal_id when hash_equal proposal_id report.proposal_id -> Ok ()
      | _ -> error "Decision is not bound to the report Proposal identity")
  | _ -> error "report has an unsupported Decision kind or carrier"

let audit_kind = function
  | { Form.head = "audit-entry-v2"; args = [ Form.F { Form.head = "evaluated-v2"; _ } ]; _ } ->
      Some "evaluated-v2"
  | { Form.head = "audit-entry-v2"; args = [ Form.F { Form.head = "consented-v2"; _ } ]; _ } ->
      Some "consented-v2"
  | { Form.head = "audit-entry-v2"; args = [ Form.F { Form.head = "completed-v2"; _ } ]; _ } ->
      Some "completed-v2"
  | _ -> None

let parse_audit (report : Governance_explain.report) =
  match report.Governance_explain.audit with
  | evaluation :: consent :: rest -> (
      match (audit_kind evaluation.entry, audit_kind consent.entry) with
      | Some "evaluated-v2", Some "consented-v2" ->
          let rec completions reversed (values : Governance_explain.audit_entry list) =
            match values with
            | [] -> Ok (List.rev reversed)
            | value :: values -> (
                match audit_kind value.entry with
                | Some "completed-v2" ->
                    completions
                      ({ kind = "completed-v2"; digest = value.digest } :: reversed)
                      values
                | _ -> error "Audit records after consent are not completion evidence")
          in
          let* completions = completions [] rest in
          let* completion_id =
            match completions with
            | [] -> Ok None
            | [ value ] -> Ok (Some value.digest)
            | values ->
                error "report has %d completion Audit records for one selected action"
                  (List.length values)
          in
          Ok
            ( [
                { kind = "evaluated-v2"; digest = evaluation.digest };
                { kind = "consented-v2"; digest = consent.digest };
              ],
              completion_id )
      | _ -> error "Audit evidence must begin with evaluated-v2 then consented-v2")
  | _ -> error "report has no complete evaluation and consent Audit evidence"

let validate_attempt report =
  match (report.Governance_explain.decision_kind, report.attempt) with
  | ("denied" | "escalated"), Governance_explain.Not_attempted -> Ok ()
  | "approved", Governance_explain.Not_attempted -> Ok ()
  | "approved", Governance_explain.Attempted value -> (
      match (value.state, value.receipt_id, value.external_receipt_digest) with
      | ("attempt-outcome-unknown" | "completed-without-receipt"), None, None -> Ok ()
      | ("receipt-pending-completion" | "reconciled-completed"), Some _, Some _ -> Ok ()
      | ( ( "attempt-outcome-unknown" | "completed-without-receipt" | "receipt-pending-completion"
          | "reconciled-completed" ),
          _,
          _ ) ->
          error "attempt state %S disagrees with its receipt evidence" value.state
      | _ -> error "approved Decision has unsupported attempted-action state %S" value.state)
  | ("denied" | "escalated"), Governance_explain.Attempted _ ->
      error "non-action Decision has attempted action evidence"
  | kind, _ -> error "report has unsupported Decision kind %S" kind

let validate_completion attempt completion_id =
  match (attempt, completion_id) with
  | Governance_explain.Not_attempted, None -> Ok ()
  | Governance_explain.Attempted { state = "attempt-outcome-unknown"; _ }, None -> Ok ()
  | Governance_explain.Attempted { state = "receipt-pending-completion"; _ }, None -> Ok ()
  | Governance_explain.Attempted { state = "completed-without-receipt"; _ }, Some _ -> Ok ()
  | Governance_explain.Attempted { state = "reconciled-completed"; _ }, Some _ -> Ok ()
  | Governance_explain.Not_attempted, Some _ ->
      error "non-attempted action has committed completion evidence"
  | Governance_explain.Attempted { state; _ }, None ->
      error "attempt state %S requires committed completion evidence" state
  | Governance_explain.Attempted { state; _ }, Some _ ->
      error "attempt state %S cannot carry committed completion evidence" state

let verdict_of_explain = function
  | "allow" -> Ok Allow
  | "ask" -> Ok Ask
  | "block" -> Ok Block
  | value -> error "report has unsupported recorded verdict %S" value

let consent_of_explain = function
  | "approved" -> Ok Approved
  | "denied" -> Ok Denied
  | "escalated" -> Ok Escalated
  | value -> error "report has unsupported Decision kind %S" value

let validate_verdict_consent verdict consent =
  match (verdict, consent) with
  | Ask, (Approved | Denied | Escalated) -> Ok ()
  | (Allow | Block | Simulate), Not_required -> Ok ()
  | Ask, _ -> error "Ask verdict has no supported committed consent state"
  | (Allow | Block | Simulate), _ ->
      error "only an Ask verdict may carry committed consent evidence"

let of_explain report =
  let* () = parse_proposal report in
  let* parent_call_id, authority = parse_call report in
  let* () = validate_operation report in
  let* () = parse_policy report in
  let* () = parse_assessment report in
  let* () = parse_decision report in
  let* audit, completion_id = parse_audit report in
  let* () = validate_attempt report in
  let* () = validate_completion report.attempt completion_id in
  let* verdict = verdict_of_explain report.recorded_verdict in
  let* consent = consent_of_explain report.decision_kind in
  let* () = validate_verdict_consent verdict consent in
  Ok
    {
      source = Verified;
      proposal_id = report.proposal_id;
      call_id = report.call_id;
      operation_name = report.operation_name;
      operation_id = report.operation_id;
      parent_call_id;
      authority;
      policy_id = report.policy_id;
      assessment_id = report.assessment_id;
      policy_rule = report.policy_rule;
      verdict;
      consent;
      audit;
      completion_id;
      attempt = report.attempt;
      simulation_not_consent = false;
    }

let stage_name = function
  | Request -> "request"
  | Assessment -> "assessment"
  | Verdict -> "verdict"
  | Consent -> "consent"
  | Activity -> "activity"
  | Outcome -> "outcome"

let identity_json kind hash =
  `Assoc
    [
      ("kind", `String kind);
      ("hash", `String (Hash.to_hex hash));
      ("subject", `String (opaque kind hash));
    ]

let authority_json = function
  | Effect { effect_id } ->
      `Assoc [ ("kind", `String "effect"); ("effect", identity_json "effect" effect_id) ]
  | Resource { effect_id; configuration_id; opaque_subject } ->
      `Assoc
        [
          ("kind", `String "resource");
          ("subject", `String opaque_subject);
          ("effect", identity_json "effect" effect_id);
          ("configuration", identity_json "configuration" configuration_id);
        ]

let audit_json value =
  `Assoc
    [
      ("kind", `String value.kind);
      ("hash", `String (Hash.to_hex value.digest));
      ("subject", `String (opaque "audit" value.digest));
    ]

let activity_json ~simulation_not_consent = function
  | Governance_explain.Not_attempted when simulation_not_consent ->
      `Assoc [ ("kind", `String "simulation"); ("attempt", `Null); ("driver", `Null) ]
  | Governance_explain.Not_attempted ->
      `Assoc [ ("kind", `String "not-attempted"); ("attempt", `Null); ("driver", `Null) ]
  | Governance_explain.Attempted value ->
      `Assoc
        [
          ("kind", `String "attempted");
          ("attempt", identity_json "action-attempted-v1" value.attempt_id);
          ("driver", identity_json "driver" value.driver_id);
        ]

let outcome_json ~completion_id ~simulation_not_consent = function
  | Governance_explain.Not_attempted ->
      `Assoc
        [
          ("kind", `String "not-attempted");
          ("receipt", `Null);
          ("external_receipt_digest", `Null);
          ("completion", `Null);
          ("simulation_not_consent", `Bool simulation_not_consent);
        ]
  | Governance_explain.Attempted value ->
      `Assoc
        [
          ("kind", `String value.state);
          ( "receipt",
            match value.receipt_id with
            | None -> `Null
            | Some hash -> identity_json "action-receipt-v1" hash );
          ( "external_receipt_digest",
            match value.external_receipt_digest with
            | None -> `Null
            | Some hash -> identity_json "external-receipt-digest" hash );
          ( "completion",
            match completion_id with
            | None -> `Null
            | Some hash -> identity_json "completed-v2" hash );
          ("simulation_not_consent", `Bool simulation_not_consent);
        ]

let stage_json stage fields = `Assoc (("stage", `String (stage_name stage)) :: fields)
let source_to_string = function Verified -> "verified" | Fixture -> "fixture"

let verdict_to_string = function
  | Allow -> "Allow"
  | Ask -> "Ask"
  | Block -> "Block"
  | Simulate -> "Simulate"

let consent_to_string = function
  | Not_required -> "Not required"
  | Approved -> "Approved"
  | Denied -> "Denied"
  | Escalated -> "Escalated"
  | Stale -> "Stale"
  | Missing -> "Missing"

let render_json_v1 value =
  let request =
    stage_json Request
      [
        ("kind", `String "governance-call-v0");
        ("subject", `String (opaque "call" value.call_id));
        ("call", identity_json "governance-call-v0" value.call_id);
        ( "operation",
          `Assoc
            [
              ("kind", `String "operation");
              ("name", `String value.operation_name);
              ("hash", `String (Hash.to_hex value.operation_id));
              ("subject", `String (opaque "operation" value.operation_id));
            ] );
        ( "parent_call_id",
          match value.parent_call_id with
          | None -> `Null
          | Some hash -> identity_json "governance-call-v0" hash );
        ("authority", `List (List.map authority_json value.authority));
      ]
  in
  let assessment =
    stage_json Assessment
      [
        ("kind", `String "governance-assessment-v0");
        ("subject", `String (opaque "assessment" value.assessment_id));
        ("assessment", identity_json "governance-assessment-v0" value.assessment_id);
      ]
  in
  let verdict =
    stage_json Verdict
      [
        ("kind", `String (verdict_to_string value.verdict));
        ("subject", `String (opaque "verdict" value.proposal_id));
        ("policy", identity_json "bound-policy-v0" value.policy_id);
        ("policy_rule", `String value.policy_rule);
      ]
  in
  let consent =
    stage_json Consent
      [
        ("kind", `String (consent_to_string value.consent));
        ("subject", `String (opaque "consent" value.proposal_id));
        ( "proposal",
          match value.consent with
          | Stale | Missing | Not_required -> `Null
          | Approved | Denied | Escalated ->
              identity_json "governance-proposal-v0" value.proposal_id );
        ("audit", `List (List.map audit_json value.audit));
      ]
  in
  let activity =
    stage_json Activity
      [
        ("subject", `String (opaque "activity" value.call_id));
        ( "activity",
          activity_json ~simulation_not_consent:value.simulation_not_consent value.attempt );
      ]
  in
  let outcome =
    stage_json Outcome
      [
        ("subject", `String (opaque "outcome" value.call_id));
        ( "outcome",
          outcome_json ~completion_id:value.completion_id
            ~simulation_not_consent:value.simulation_not_consent value.attempt );
      ]
  in
  Yojson.Safe.to_string
    (`Assoc
       [
         ("schema", `String schema);
         ("profile", `String profile);
         ("source", `String (source_to_string value.source));
         ("illustrative", `Bool (value.source = Fixture));
         ("evidence_limits", `List (List.map (fun limit -> `String limit) evidence_limits));
         ("stages", `List [ request; assessment; verdict; consent; activity; outcome ]);
       ])

let fixture scenario =
  let seed =
    match scenario with
    | Allow_fixture -> "allow"
    | Block_fixture -> "block"
    | Stale_approval_fixture -> "stale-approval"
    | Transformed_call_fixture -> "transformed-call"
    | Missing_completion_fixture -> "missing-completion"
    | Dry_simulation_fixture -> "dry-simulation"
  in
  let hash kind = Hash.of_string ("governance-decision-chain-fixture-v1:" ^ seed ^ ":" ^ kind) in
  let proposal_id = hash "proposal" in
  let call_id = hash "call" in
  let audit =
    match scenario with
    | Allow_fixture | Block_fixture | Stale_approval_fixture ->
        [ { kind = "evaluated-v2"; digest = hash "evaluated" } ]
    | Dry_simulation_fixture -> []
    | _ ->
        [
          { kind = "evaluated-v2"; digest = hash "evaluated" };
          { kind = "consented-v2"; digest = hash "consented" };
        ]
  in
  let attempt =
    match scenario with
    | Missing_completion_fixture ->
        Governance_explain.Attempted
          {
            state = "receipt-pending-completion";
            attempt_id = hash "attempt";
            driver_name = "workspace.driver-write";
            driver_id = hash "driver";
            receipt_id = Some (hash "receipt");
            external_receipt_digest = Some (hash "external-receipt");
          }
    | _ -> Governance_explain.Not_attempted
  in
  let verdict, consent, parent_call_id, simulation_not_consent =
    match scenario with
    | Allow_fixture -> (Allow, Not_required, None, false)
    | Block_fixture -> (Block, Not_required, None, false)
    | Stale_approval_fixture -> (Ask, Stale, None, false)
    | Transformed_call_fixture -> (Ask, Approved, Some (hash "parent-call"), false)
    | Missing_completion_fixture -> (Ask, Approved, None, false)
    | Dry_simulation_fixture -> (Simulate, Not_required, None, true)
  in
  {
    source = Fixture;
    proposal_id;
    call_id;
    operation_name = "workspace.write-file";
    operation_id = hash "operation";
    parent_call_id;
    authority =
      Effect { effect_id = hash "effect" }
      ::
      (match scenario with
      | Transformed_call_fixture ->
          [
            Resource
              {
                effect_id = hash "effect";
                configuration_id = hash "configuration";
                opaque_subject = opaque "resource" (hash "resource");
              };
          ]
      | _ -> []);
    policy_id = hash "policy";
    assessment_id = hash "assessment";
    policy_rule =
      (match verdict with
      | Allow -> "fixture.allow"
      | Ask -> "fixture.ask"
      | Block -> "fixture.block"
      | Simulate -> "fixture.simulate");
    verdict;
    consent;
    audit;
    completion_id = None;
    attempt;
    simulation_not_consent;
  }

let project_json_v1 report =
  let* chain = of_explain report in
  Ok (render_json_v1 chain)
