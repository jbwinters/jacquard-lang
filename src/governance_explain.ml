type audit_entry = { index : int; digest : Hash.t; entry : Form.t }

type attempted = {
  state : string;
  attempt_id : Hash.t;
  driver_name : string;
  driver_id : Hash.t;
  receipt_id : Hash.t option;
  external_receipt_digest : Hash.t option;
}

type attempt_state = Not_attempted | Attempted of attempted

type report = {
  proposal_id : Hash.t;
  proposal : Form.t;
  proposal_rendering : Form.t;
  proposal_summary : string;
  proposal_preview : Form.t;
  call_id : Hash.t;
  operation_name : string;
  operation_id : Hash.t;
  call : Form.t;
  raw_authority : Form.t;
  policy_id : Hash.t;
  bound_policy : Form.t;
  assessment_id : Hash.t;
  assessment : Form.t;
  policy_rule : string;
  recorded_verdict : string;
  decision_kind : string;
  decision : Form.t;
  audit : audit_entry list;
  attempt : attempt_state;
}

let schema = "jacquard-governance-explain-report-v1"
let review_facts_schema = "jacquard-governance-review-facts-v1"
let version = "governance-explain-v1"
let ( let* ) = Result.bind

let diagnostic_spec = function
  | "E1530" ->
      ( "The proposal identifier is not canonical HASH_V0 text.",
        "Pass exactly 64 lowercase hexadecimal HASH_V0 digits." )
  | "E1531" ->
      ( "The verified reconciliation package cannot select one linked Proposal.",
        "Use the exact Proposal ID from one fully linked Proposal artifact in this package." )
  | "E1532" ->
      ( "The recorded governance verdict disagrees with the recomputed live policy rule.",
        "Restore the original policy, assessment, and matching Evaluated verdict." )
  | "E1533" ->
      ( "The Workspace action evidence cannot support this explanation.",
        "Use an exact Workspace v0 operation and its canonical committed leaf driver, or reconcile \
         the missing attempt." )
  | code -> raise (Diag.Bug_invalid_diagnostic ("unknown governance explanation code " ^ code))

let error ~code fmt =
  Printf.ksprintf
    (fun cause ->
      let summary, next_step = diagnostic_spec code in
      Error [ Diag.error ~domain:Governance ~code ~summary ~cause ~next_step ~contrast:None () ])
    fmt

let proposal_id_of_string spelling =
  match Hash.of_canonical_hex spelling with
  | Some value -> Ok value
  | None -> error ~code:"E1530" "Proposal ID must be exactly 64 lowercase hexadecimal digits"

let form head values = Form.form head (List.map (fun value -> Form.F value) values)
let hash_form value = Form.form "hash" [ Form.Hash value ]
let compact value = Printer.print_compact value
let semantic_hash value = Hash.of_string (compact value)

let hash_value = function
  | { Form.head = "hash"; args = [ Form.Hash value ]; _ } -> Some value
  | _ -> None

let text_value = function
  | { Form.head = "lit"; args = [ Form.Text value ]; _ } -> Some value
  | _ -> None

let real_value = function
  | { Form.head = "lit"; args = [ Form.Real value ]; _ } -> Some value
  | _ -> None

let child_forms args =
  let rec loop reversed = function
    | [] -> Some (List.rev reversed)
    | Form.F value :: rest -> loop (value :: reversed) rest
    | _ -> None
  in
  loop [] args

let exactly_one ~kind ~identity values =
  match List.filter identity values with
  | [ value ] -> Ok value
  | [] -> error ~code:"E1531" "Proposal selection has no linked %s" kind
  | values ->
      error ~code:"E1531" "Proposal selection has %d linked %s values" (List.length values) kind

type call_fact = {
  call_id : Hash.t;
  operation_id : Hash.t;
  operation_name : string;
  call : Form.t;
  authority : Form.t;
}

type policy_fact = { policy_id : Hash.t; bound_policy : Form.t; value : Form.t }
type assessment_fact = { assessment_id : Hash.t; assessment : Form.t }

type proposal_fact = {
  proposal_id : Hash.t;
  proposal : Form.t;
  rendering : Form.t;
  summary : string;
  authority : Form.t;
  preview : Form.t;
  call_id : Hash.t;
  policy_id : Hash.t;
  assessment_id : Hash.t;
}

type evaluated_fact = { record : audit_entry; verdict : string }
type consented_fact = { record : audit_entry; decision_kind : string; decision : Form.t }
type completed_fact = { record : audit_entry; branch : string }

type attempt_fact = {
  attempt_id : Hash.t;
  call_id : Hash.t;
  authorization : Hash.t;
  branch : string;
  driver_id : Hash.t;
}

type receipt_fact = { receipt_id : Hash.t; attempt_id : Hash.t; external_receipt_digest : Hash.t }

let extract_sections = function
  | {
      Form.head = "governance-reconciliation-bundle-v1";
      args =
        [
          Form.F
            {
              Form.head = "governance-run-bundle-v1";
              args =
                [
                  Form.F _published;
                  Form.F { Form.head = "audit-records-v1"; args = records; _ };
                  Form.F { Form.head = "governance-call-artifacts-v1"; args = calls; _ };
                  Form.F { Form.head = "bound-policy-artifacts-v1"; args = policies; _ };
                  Form.F { Form.head = "governance-assessment-artifacts-v1"; args = assessments; _ };
                  Form.F { Form.head = "governance-proposal-artifacts-v1"; args = proposals; _ };
                ];
              _;
            };
          Form.F _published_journal;
          Form.F { Form.head = "governance-action-journal-v1"; args = journal; _ };
        ];
      _;
    } -> (
      match
        ( child_forms records,
          child_forms calls,
          child_forms policies,
          child_forms assessments,
          child_forms proposals,
          child_forms journal )
      with
      | Some records, Some calls, Some policies, Some assessments, Some proposals, Some journal ->
          Ok (records, calls, policies, assessments, proposals, journal)
      | _ -> error ~code:"E1531" "verified package contains a scalar fixed-section member")
  | _ -> error ~code:"E1531" "verified package has no projectable reconciliation carrier"

let parse_proposal = function
  | {
      Form.head = "governance-proposal-artifact-v1";
      args =
        [
          Form.F version;
          Form.F proposal;
          Form.F call;
          Form.F policy;
          Form.F assessment;
          Form.F rendering;
          Form.F summary;
          Form.F authority;
          Form.F preview;
        ];
      _;
    } -> (
      match
        ( hash_value proposal,
          hash_value call,
          hash_value policy,
          hash_value assessment,
          text_value summary )
      with
      | Some proposal_id, Some call_id, Some policy_id, Some assessment_id, Some summary ->
          Some
            {
              proposal_id;
              proposal =
                form "governance-proposal-v0"
                  [
                    version;
                    hash_form call_id;
                    hash_form policy_id;
                    hash_form assessment_id;
                    authority;
                    preview;
                    rendering;
                    Form.form "lit" [ Form.Text summary ];
                  ];
              rendering;
              summary;
              authority;
              preview;
              call_id;
              policy_id;
              assessment_id;
            }
      | _ -> None)
  | _ -> None

let parse_call = function
  | {
      Form.head = "governance-call-artifact-v1";
      args =
        [
          Form.F version;
          Form.F carried;
          Form.F operation;
          Form.F operation_name;
          Form.F arguments;
          Form.F authority;
          Form.F _summary;
          Form.F preconditions;
          Form.F parent;
        ];
      _;
    } -> (
      match (hash_value carried, hash_value operation, text_value operation_name) with
      | Some call_id, Some operation_id, Some operation_name ->
          Some
            {
              call_id;
              operation_id;
              operation_name;
              call =
                form "governance-call-v0"
                  [ version; hash_form operation_id; arguments; authority; preconditions; parent ];
              authority;
            }
      | _ -> None)
  | _ -> None

let parse_policy = function
  | {
      Form.head = "bound-policy-artifact-v1";
      args = [ Form.F version; Form.F carried; Form.F value ];
      _;
    } -> (
      match hash_value carried with
      | Some policy_id ->
          Some
            {
              policy_id;
              bound_policy = form "bound-policy-v0" [ version; hash_form policy_id; value ];
              value;
            }
      | None -> None)
  | _ -> None

let parse_assessment value =
  match value.Form.head with
  | "governance-assessment-v0" -> Some { assessment_id = semantic_hash value; assessment = value }
  | _ -> None

let risk_rank = function
  | { Form.head = "low"; args = []; _ } -> Some 0
  | { Form.head = "medium"; args = []; _ } -> Some 1
  | { Form.head = "high"; args = []; _ } -> Some 2
  | { Form.head = "forbidden"; args = []; _ } -> Some 3
  | _ -> None

let recompute_rule policy assessment =
  match (policy, assessment) with
  | ( {
        Form.head = "live-policy-v0";
        args = [ Form.F _; Form.F auto; Form.F ask; Form.F minimum ];
        _;
      },
      {
        Form.head = "governance-assessment-v0";
        args = [ Form.F _; Form.F risk; Form.F confidence; Form.F _; Form.F _ ];
        _;
      } ) -> (
      match
        (risk_rank auto, risk_rank ask, risk_rank risk, real_value minimum, real_value confidence)
      with
      | Some auto, Some ask, Some risk, Some minimum, Some confidence ->
          if risk = 3 then Ok ("live.forbidden", "block")
          else if confidence < minimum then
            if risk <= ask then Ok ("live.below-confidence-ask", "ask")
            else Ok ("live.below-confidence-block", "block")
          else if risk <= auto then Ok ("live.at-or-below-auto", "allow")
          else if risk <= ask then Ok ("live.at-or-below-ask", "ask")
          else Ok ("live.above-ask", "block")
      | _ -> error ~code:"E1532" "verified live policy or assessment cannot be recomputed")
  | _ -> error ~code:"E1532" "selected Proposal is not linked to a live policy and assessment"

let parse_audit_record index = function
  | {
      Form.head = "audit-chain-v2";
      args = [ Form.Hash _previous; Form.Hash digest; Form.F entry ];
      _;
    } ->
      Some { index; digest; entry }
  | _ -> None

let decision_kind proposal_id = function
  | { Form.head = "approved-v1"; args = Form.F carried :: _; _ } as decision -> (
      match hash_value carried with
      | Some id when Hash.equal id proposal_id -> Some ("approved", decision)
      | _ -> None)
  | { Form.head = "denied-v1"; args = Form.F carried :: _; _ } as decision -> (
      match hash_value carried with
      | Some id when Hash.equal id proposal_id -> Some ("denied", decision)
      | _ -> None)
  | { Form.head = "escalate-v1"; args = Form.F carried :: _; _ } as decision -> (
      match hash_value carried with
      | Some id when Hash.equal id proposal_id -> Some ("escalated", decision)
      | _ -> None)
  | _ -> None

let audit_facts ~(proposal : proposal_fact) records =
  let evaluations = ref [] and consents = ref [] and completions = ref [] in
  List.iteri
    (fun index value ->
      match parse_audit_record index value with
      | None -> ()
      | Some record -> (
          match record.entry with
          | {
           Form.head = "audit-entry-v2";
           args =
             [
               Form.F
                 {
                   Form.head = "evaluated-v2";
                   args =
                     [
                       Form.F _;
                       Form.F _;
                       Form.F call;
                       Form.F policy;
                       Form.F assessment;
                       Form.F verdict;
                     ];
                   _;
                 };
             ];
           _;
          } -> (
              match (hash_value call, hash_value policy) with
              | Some call_id, Some policy_id
                when Hash.equal call_id proposal.call_id
                     && Hash.equal policy_id proposal.policy_id
                     && Hash.equal (semantic_hash assessment) proposal.assessment_id ->
                  evaluations := { record; verdict = verdict.Form.head } :: !evaluations
              | _ -> ())
          | {
           Form.head = "audit-entry-v2";
           args =
             [
               Form.F
                 {
                   Form.head = "consented-v2";
                   args = [ Form.F _; Form.F _; Form.F call; Form.F selected; Form.F decision ];
                   _;
                 };
             ];
           _;
          } -> (
              match
                (hash_value call, hash_value selected, decision_kind proposal.proposal_id decision)
              with
              | Some call_id, Some selected, Some (decision_kind, decision)
                when Hash.equal call_id proposal.call_id && Hash.equal selected proposal.proposal_id
                ->
                  consents := { record; decision_kind; decision } :: !consents
              | _ -> ())
          | {
           Form.head = "audit-entry-v2";
           args =
             [
               Form.F
                 {
                   Form.head = "completed-v2";
                   args = Form.F _ :: Form.F _ :: Form.F call :: Form.F branch :: _;
                   _;
                 };
             ];
           _;
          } -> (
              match (hash_value call, text_value branch) with
              | Some call_id, Some branch when Hash.equal call_id proposal.call_id ->
                  completions := { record; branch } :: !completions
              | _ -> ())
          | _ -> ()))
    records;
  let* evaluation = exactly_one ~kind:"Evaluated record" ~identity:(fun _ -> true) !evaluations in
  let* consent = exactly_one ~kind:"Consented record" ~identity:(fun _ -> true) !consents in
  let relevant =
    evaluation.record :: consent.record :: List.map (fun value -> value.record) !completions
    |> List.sort (fun left right -> Int.compare left.index right.index)
  in
  Ok (evaluation, consent, List.rev !completions, relevant)

let parse_attempt = function
  | {
      Form.head = "governance-action-chain-v1";
      args =
        [
          Form.Hash _;
          Form.Hash _;
          Form.F
            {
              Form.head = "action-attempted-v1";
              args =
                [
                  Form.F _;
                  Form.F carried;
                  Form.F call;
                  Form.F authorization;
                  Form.F branch;
                  Form.F driver;
                  Form.F _key;
                ];
              _;
            };
        ];
      _;
    } -> (
      match
        ( hash_value carried,
          hash_value call,
          hash_value authorization,
          text_value branch,
          hash_value driver )
      with
      | Some attempt_id, Some call_id, Some authorization, Some branch, Some driver_id ->
          Some { attempt_id; call_id; authorization; branch; driver_id }
      | _ -> None)
  | _ -> None

let parse_receipt = function
  | {
      Form.head = "governance-action-chain-v1";
      args =
        [
          Form.Hash _;
          Form.Hash _;
          Form.F
            {
              Form.head = "action-receipt-v1";
              args =
                [
                  Form.F _; Form.F carried; Form.F attempt; Form.F _outcome; Form.F external_receipt;
                ];
              _;
            };
        ];
      _;
    } -> (
      match (hash_value carried, hash_value attempt, hash_value external_receipt) with
      | Some receipt_id, Some attempt_id, Some external_receipt_digest ->
          Some { receipt_id; attempt_id; external_receipt_digest }
      | _ -> None)
  | _ -> None

let action_state ~(call : call_fact) ~(consent : consented_fact)
    ~(completions : completed_fact list) journal =
  let live_completions =
    List.filter (fun (value : completed_fact) -> String.equal value.branch "live") completions
  in
  let attempts =
    List.filter_map parse_attempt journal
    |> List.filter (fun (value : attempt_fact) ->
        Hash.equal value.call_id call.call_id
        && Hash.equal value.authorization consent.record.digest
        && String.equal value.branch "live")
  in
  let* attempt =
    match attempts with
    | [] -> Ok None
    | [ value ] -> Ok (Some value)
    | values ->
        error ~code:"E1533" "selected authorization has %d matching action attempts"
          (List.length values)
  in
  match (consent.decision_kind, attempt, live_completions) with
  | ("denied" | "escalated"), None, [] -> Ok Not_attempted
  | ("denied" | "escalated"), _, _ ->
      error ~code:"E1533" "%s Decision has incompatible action evidence" consent.decision_kind
  | "approved", None, [] -> Ok Not_attempted
  | "approved", None, _ ->
      error ~code:"E1533" "approved live completion has no unique matching committed action attempt"
  | "approved", Some attempt, completions -> (
      match Governance_source_check.canonical_workspace_driver ~operation:call.operation_id with
      | None ->
          error ~code:"E1533"
            "attempted Call operation #%s is not a canonical Workspace v0 operation"
            (Hash.to_hex call.operation_id)
      | Some (operation_name, _driver_name, _driver_id)
        when not (String.equal operation_name call.operation_name) ->
          error ~code:"E1533" "Call operation name `%s` disagrees with canonical `%s`"
            call.operation_name operation_name
      | Some (_operation_name, driver_name, driver_id)
        when not (Hash.equal driver_id attempt.driver_id) ->
          error ~code:"E1533" "attempt #%s commits driver #%s instead of canonical %s #%s"
            (Hash.to_hex attempt.attempt_id) (Hash.to_hex attempt.driver_id) driver_name
            (Hash.to_hex driver_id)
      | Some (_operation_name, driver_name, driver_id) ->
          let receipts =
            List.filter_map parse_receipt journal
            |> List.filter (fun (value : receipt_fact) ->
                Hash.equal value.attempt_id attempt.attempt_id)
          in
          let* receipt =
            match receipts with
            | [] -> Ok None
            | [ value ] -> Ok (Some value)
            | values ->
                error ~code:"E1533" "attempt #%s has %d matching receipts"
                  (Hash.to_hex attempt.attempt_id) (List.length values)
          in
          let* state =
            match (receipt, completions) with
            | None, [] -> Ok "attempt-outcome-unknown"
            | None, [ _ ] -> Ok "completed-without-receipt"
            | Some _, [] -> Ok "receipt-pending-completion"
            | Some _, [ _ ] -> Ok "reconciled-completed"
            | _, values ->
                error ~code:"E1533" "selected Call has %d live completions" (List.length values)
          in
          Ok
            (Attempted
               {
                 state;
                 attempt_id = attempt.attempt_id;
                 driver_name;
                 driver_id;
                 receipt_id = Option.map (fun value -> value.receipt_id) receipt;
                 external_receipt_digest =
                   Option.map (fun value -> value.external_receipt_digest) receipt;
               }))
  | kind, _, _ -> error ~code:"E1531" "unsupported verified Decision kind `%s`" kind

let of_verified ~proposal_id verified =
  let bundle = Governance_reconcile.verified_bundle verified in
  let* records, calls, policies, assessments, proposals, journal = extract_sections bundle in
  let parsed_proposals = List.filter_map parse_proposal proposals in
  let* proposal =
    exactly_one ~kind:"Proposal artifact"
      ~identity:(fun (value : proposal_fact) -> Hash.equal value.proposal_id proposal_id)
      parsed_proposals
  in
  let parsed_calls = List.filter_map parse_call calls in
  let* call =
    exactly_one ~kind:"Call artifact"
      ~identity:(fun (value : call_fact) -> Hash.equal value.call_id proposal.call_id)
      parsed_calls
  in
  let* () =
    if compact proposal.authority = compact call.authority then Ok ()
    else error ~code:"E1531" "Proposal and Call authority projections disagree"
  in
  let* canonical_operation_name, _driver_name, _driver_id =
    match Governance_source_check.canonical_workspace_driver ~operation:call.operation_id with
    | Some value -> Ok value
    | None ->
        error ~code:"E1533" "Call operation #%s is outside canonical Workspace v0"
          (Hash.to_hex call.operation_id)
  in
  let* () =
    if String.equal call.operation_name canonical_operation_name then Ok ()
    else
      error ~code:"E1533" "Call operation name `%s` disagrees with canonical `%s`"
        call.operation_name canonical_operation_name
  in
  let parsed_policies = List.filter_map parse_policy policies in
  let* policy =
    exactly_one ~kind:"BoundPolicy artifact"
      ~identity:(fun (value : policy_fact) -> Hash.equal value.policy_id proposal.policy_id)
      parsed_policies
  in
  let parsed_assessments = List.filter_map parse_assessment assessments in
  let* assessment =
    exactly_one ~kind:"Assessment artifact"
      ~identity:(fun (value : assessment_fact) ->
        Hash.equal value.assessment_id proposal.assessment_id)
      parsed_assessments
  in
  let* policy_rule, expected_verdict = recompute_rule policy.value assessment.assessment in
  let* evaluation, consent, completions, audit = audit_facts ~proposal records in
  let* () =
    if String.equal evaluation.verdict expected_verdict then Ok ()
    else
      error ~code:"E1532" "policy rule %s recomputes `%s` but Audit records `%s`" policy_rule
        expected_verdict evaluation.verdict
  in
  let* attempt = action_state ~call ~consent ~completions journal in
  Ok
    {
      proposal_id;
      proposal = proposal.proposal;
      proposal_rendering = proposal.rendering;
      proposal_summary = proposal.summary;
      proposal_preview = proposal.preview;
      call_id = call.call_id;
      operation_name = call.operation_name;
      operation_id = call.operation_id;
      call = call.call;
      raw_authority = call.authority;
      policy_id = policy.policy_id;
      bound_policy = policy.bound_policy;
      assessment_id = assessment.assessment_id;
      assessment = assessment.assessment;
      policy_rule;
      recorded_verdict = evaluation.verdict;
      decision_kind = consent.decision_kind;
      decision = consent.decision;
      audit;
      attempt;
    }

let verify_form ~store ~file ~proposal_id bundle =
  let* verified = Governance_reconcile.verify_detailed_form ~store ~file bundle in
  of_verified ~proposal_id verified

let verify_string ~store ~file ~proposal_id source =
  let* verified = Governance_reconcile.verify_detailed_string ~store ~file source in
  of_verified ~proposal_id verified

let verify_file ~store ~file ~proposal_id =
  let* verified = Governance_reconcile.verify_detailed_file ~store ~file in
  of_verified ~proposal_id verified

let evidence_limits =
  [
    "committed-driver-not-execution-proof";
    "external-receipt-digest-not-receipt-truth";
    "resource-scope-not-type-proof";
    "missing-completion-not-rollback";
  ]

let render_text (report : report) =
  let buffer = Buffer.create 2048 in
  let line format =
    Printf.ksprintf
      (fun value ->
        Buffer.add_string buffer value;
        Buffer.add_char buffer '\n')
      format
  in
  let hex value = "#" ^ Hash.to_hex value in
  line "ok %s schema=%s" version schema;
  line "review-facts-schema %s" review_facts_schema;
  line "proposal-id %s" (hex report.proposal_id);
  line "proposal %s" (compact report.proposal);
  line "proposal-rendering %s" (compact report.proposal_rendering);
  line "proposal-summary %s" (compact (Form.form "lit" [ Form.Text report.proposal_summary ]));
  line "proposal-preview %s" (compact report.proposal_preview);
  line "call-id %s" (hex report.call_id);
  line "operation %s %s" report.operation_name (hex report.operation_id);
  line "call %s" (compact report.call);
  line "raw-authority %s" (compact report.raw_authority);
  line "bound-policy-id %s" (hex report.policy_id);
  line "bound-policy %s" (compact report.bound_policy);
  line "assessment-id %s" (hex report.assessment_id);
  line "assessment %s" (compact report.assessment);
  line "policy-rule %s" report.policy_rule;
  line "recorded-verdict %s" report.recorded_verdict;
  line "decision-kind %s" report.decision_kind;
  line "decision %s" (compact report.decision);
  line "audit-count %d" (List.length report.audit);
  List.iter
    (fun value ->
      line "audit index=%d digest=%s entry=%s" value.index (hex value.digest) (compact value.entry))
    report.audit;
  (match report.attempt with
  | Not_attempted ->
      line "attempt-state not-attempted";
      line "attempt-id not-attempted";
      line "driver not-attempted";
      line "receipt-id not-attempted";
      line "external-receipt-digest not-attempted"
  | Attempted value ->
      line "attempt-state %s" value.state;
      line "attempt-id %s" (hex value.attempt_id);
      line "driver %s %s" value.driver_name (hex value.driver_id);
      line "receipt-id %s" (Option.fold ~none:"not-recorded" ~some:hex value.receipt_id);
      line "external-receipt-digest %s"
        (Option.fold ~none:"not-recorded" ~some:hex value.external_receipt_digest));
  List.iter (fun limit -> line "evidence-limit %s" limit) evidence_limits;
  Buffer.contents buffer

let render_json_v1 (report : report) =
  let hex value = Hash.to_hex value in
  let optional_hash = function None -> `Null | Some value -> `String (hex value) in
  let audit value =
    `Assoc
      [
        ("index", `Int value.index);
        ("digest", `String (hex value.digest));
        ("entry", `String (compact value.entry));
      ]
  in
  let attempt =
    match report.attempt with
    | Not_attempted ->
        `Assoc
          [
            ("state", `String "not-attempted");
            ("attempt_id", `Null);
            ("driver", `Null);
            ("receipt_id", `Null);
            ("external_receipt_digest", `Null);
          ]
    | Attempted value ->
        `Assoc
          [
            ("state", `String value.state);
            ("attempt_id", `String (hex value.attempt_id));
            ( "driver",
              `Assoc
                [ ("name", `String value.driver_name); ("identity", `String (hex value.driver_id)) ]
            );
            ("receipt_id", optional_hash value.receipt_id);
            ("external_receipt_digest", optional_hash value.external_receipt_digest);
          ]
  in
  let review_facts =
    `Assoc
      [
        ("schema", `String review_facts_schema);
        ( "proposal",
          `Assoc
            [
              ("identity", `String (hex report.proposal_id));
              ("subject", `String (compact report.proposal));
              ("rendering", `String (compact report.proposal_rendering));
              ("summary", `String report.proposal_summary);
              ("preview", `String (compact report.proposal_preview));
            ] );
        ( "call",
          `Assoc
            [
              ("identity", `String (hex report.call_id));
              ( "operation",
                `Assoc
                  [
                    ("name", `String report.operation_name);
                    ("identity", `String (hex report.operation_id));
                  ] );
              ("subject", `String (compact report.call));
            ] );
        ("authority", `String (compact report.raw_authority));
        ( "policy",
          `Assoc
            [
              ("identity", `String (hex report.policy_id));
              ("bound_policy", `String (compact report.bound_policy));
            ] );
        ( "assessment",
          `Assoc
            [
              ("identity", `String (hex report.assessment_id));
              ("subject", `String (compact report.assessment));
            ] );
        ( "evaluation",
          `Assoc
            [
              ("policy_rule", `String report.policy_rule);
              ("recorded_verdict", `String report.recorded_verdict);
            ] );
        ( "decision",
          `Assoc
            [
              ("kind", `String report.decision_kind); ("subject", `String (compact report.decision));
            ] );
        ("action", attempt);
      ]
  in
  Yojson.Safe.to_string
    (`Assoc
       [
         ("schema", `String schema);
         ("proposal_id", `String (hex report.proposal_id));
         ("proposal", `String (compact report.proposal));
         ("proposal_rendering", `String (compact report.proposal_rendering));
         ("proposal_summary", `String report.proposal_summary);
         ("proposal_preview", `String (compact report.proposal_preview));
         ("call_id", `String (hex report.call_id));
         ( "operation",
           `Assoc
             [
               ("name", `String report.operation_name);
               ("identity", `String (hex report.operation_id));
             ] );
         ("call", `String (compact report.call));
         ("raw_authority", `String (compact report.raw_authority));
         ("bound_policy_id", `String (hex report.policy_id));
         ("bound_policy", `String (compact report.bound_policy));
         ("assessment_id", `String (hex report.assessment_id));
         ("assessment", `String (compact report.assessment));
         ("policy_rule", `String report.policy_rule);
         ("recorded_verdict", `String report.recorded_verdict);
         ("decision_kind", `String report.decision_kind);
         ("decision", `String (compact report.decision));
         ("audit", `List (List.map audit report.audit));
         ("attempt", attempt);
         ("review_facts", review_facts);
         ("evidence_limits", `List (List.map (fun value -> `String value) evidence_limits));
       ])
