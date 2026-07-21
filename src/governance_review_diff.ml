(** See {!Governance_review_diff}. *)

type identity = { name : string; hash : Hash.t }

type dynamic_facts = {
  proposal_id : Hash.t;
  proposal_rendering : Form.t;
  proposal_summary : string;
  call_id : Hash.t;
  operation : identity;
  call : Form.t;
  authority : Form.t;
  policy_id : Hash.t;
  policy : Form.t;
  assessment_id : Hash.t;
  assessment : Form.t;
  preview : Form.t;
  policy_rule : string;
  recorded_verdict : string;
  decision_kind : string;
  decision : Form.t;
  attempt : Governance_explain.attempt_state;
}

type static_facts = {
  profile : string;
  requested_effect : identity;
  source_root : identity;
  topology : string;
  facade : identity;
  facade_operations : identity list;
  reached_operations : Governance_why_effect.operation_fact list;
  chains : Governance_why_effect.chain list;
}

type snapshot = { dynamic : dynamic_facts option; static : static_facts option }

type change_kind =
  | Facade_added
  | Facade_removed
  | Facade_changed
  | Source_root_changed
  | Driver_row_widened
  | Driver_row_narrowed
  | Driver_row_changed
  | Policy_changed
  | Simulator_changed
  | Normalizer_changed
  | Driver_changed
  | Authority_changed
  | Attribution_changed
  | Operation_rendering_only
  | Proposal_rendering_only
  | Label_changed
  | Call_changed
  | Assessment_changed
  | Preview_changed
  | Evaluation_changed
  | Decision_changed
  | Attempt_changed
  | Summarizer_changed
  | Proposal_rendering_changed
  | Other_semantic_change

type change = {
  kind : change_kind;
  subject : identity;
  old_identity : identity option;
  new_identity : identity option;
}

type availability_side = Old | New | Both
type unavailable = { subject : identity; side : availability_side; reason : string }
type classification = { changes : change list; unavailable : unavailable list }
type completeness = Complete | Partial | No_change

type report = {
  schema : string;
  completeness : completeness;
  changes : change list;
  unavailable : unavailable list;
  evidence_limits : string list;
}

let schema = "jacquard-governance-diff-report-v1"
let profile = "workspace-v0"
let unavailable_reason = "operation-not-reached"
let ( let* ) = Result.bind

let evidence_limits =
  [
    "does-not-grant-authority";
    "does-not-prove-execution";
    "does-not-assign-safety-verdict";
    "empty-static-chains-not-runtime-absence";
    "static-operation-detail-is-query-scoped";
  ]

let diagnostic_spec = function
  | "E1539" ->
      ( "Governance review fact families or comparison profiles are incompatible.",
        "Compare the same producer families and static authority query, with exact operation and \
         attempted-driver linkage at each endpoint." )
  | "E1540" ->
      ( "Governance review facts conflict for one exact identity.",
        "Provide at most one normalized fact value for each exact HASH_V0 identity." )
  | "E1541" ->
      ( "Governance review facts violate an internal comparison invariant.",
        "Regenerate the facts from fully verified GM.17A and GM.17B reports." )
  | code -> raise (Diag.Bug_invalid_diagnostic ("unknown governance review-diff code " ^ code))

let error ~code fmt =
  Printf.ksprintf
    (fun cause ->
      let summary, next_step = diagnostic_spec code in
      Error [ Diag.error ~domain:Governance ~code ~summary ~cause ~next_step ~contrast:None () ])
    fmt

let identity_of_why (value : Governance_why_effect.identity) =
  { name = value.name; hash = value.hash }

let dynamic_facts_of_explain (report : Governance_explain.report) =
  {
    proposal_id = report.proposal_id;
    proposal_rendering = report.proposal_rendering;
    proposal_summary = report.proposal_summary;
    call_id = report.call_id;
    operation = { name = report.operation_name; hash = report.operation_id };
    call = report.call;
    authority = report.raw_authority;
    policy_id = report.policy_id;
    policy = report.bound_policy;
    assessment_id = report.assessment_id;
    assessment = report.assessment;
    preview = report.proposal_preview;
    policy_rule = report.policy_rule;
    recorded_verdict = report.recorded_verdict;
    decision_kind = report.decision_kind;
    decision = report.decision;
    attempt = report.attempt;
  }

let static_facts_of_why_effect (report : Governance_why_effect.report) =
  {
    profile;
    requested_effect = identity_of_why report.requested_effect;
    source_root = identity_of_why report.source_root;
    topology = report.topology;
    facade = identity_of_why report.facade;
    facade_operations = List.map identity_of_why report.facade_operations;
    reached_operations = report.reached_operations;
    chains = report.chains;
  }

let compact = Printer.print_compact
let form_equal left right = String.equal (compact left) (compact right)
let identity_equal left right = Hash.equal left.hash right.hash
let exact_identity_equal left right = identity_equal left right && String.equal left.name right.name

let compare_identity left right =
  let by_hash = Hash.compare left.hash right.hash in
  if by_hash <> 0 then by_hash else String.compare left.name right.name

let option_compare compare left right =
  match (left, right) with
  | None, None -> 0
  | None, Some _ -> -1
  | Some _, None -> 1
  | Some left, Some right -> compare left right

let identity_of_form name value = { name; hash = Hash.of_string (compact value) }
let identity_of_string name value = { name; hash = Hash.of_string value }

let change_kind_to_string = function
  | Facade_added -> "facade-added"
  | Facade_removed -> "facade-removed"
  | Facade_changed -> "facade-changed"
  | Source_root_changed -> "source-root-changed"
  | Driver_row_widened -> "driver-row-widened"
  | Driver_row_narrowed -> "driver-row-narrowed"
  | Driver_row_changed -> "driver-row-changed"
  | Policy_changed -> "policy-changed"
  | Simulator_changed -> "simulator-changed"
  | Normalizer_changed -> "normalizer-changed"
  | Driver_changed -> "driver-changed"
  | Authority_changed -> "authority-changed"
  | Attribution_changed -> "attribution-changed"
  | Operation_rendering_only -> "operation-rendering-only"
  | Proposal_rendering_only -> "proposal-rendering-only"
  | Label_changed -> "label-changed"
  | Call_changed -> "call-changed"
  | Assessment_changed -> "assessment-changed"
  | Preview_changed -> "preview-changed"
  | Evaluation_changed -> "evaluation-changed"
  | Decision_changed -> "decision-changed"
  | Attempt_changed -> "attempt-changed"
  | Summarizer_changed -> "summarizer-changed"
  | Proposal_rendering_changed -> "proposal-rendering-changed"
  | Other_semantic_change -> "other-semantic-change"

let change_rank = function
  | Facade_added -> 0
  | Facade_removed -> 1
  | Facade_changed -> 2
  | Source_root_changed -> 3
  | Driver_row_widened -> 4
  | Driver_row_narrowed -> 5
  | Driver_row_changed -> 6
  | Policy_changed -> 7
  | Simulator_changed -> 8
  | Normalizer_changed -> 9
  | Driver_changed -> 10
  | Authority_changed -> 11
  | Attribution_changed -> 12
  | Operation_rendering_only -> 13
  | Proposal_rendering_only -> 14
  | Label_changed -> 15
  | Call_changed -> 16
  | Assessment_changed -> 17
  | Preview_changed -> 18
  | Evaluation_changed -> 19
  | Decision_changed -> 20
  | Attempt_changed -> 21
  | Summarizer_changed -> 22
  | Proposal_rendering_changed -> 23
  | Other_semantic_change -> 24

let compare_change left right =
  let by_kind = Int.compare (change_rank left.kind) (change_rank right.kind) in
  if by_kind <> 0 then by_kind
  else
    let by_subject = compare_identity left.subject right.subject in
    if by_subject <> 0 then by_subject
    else
      let by_old = option_compare compare_identity left.old_identity right.old_identity in
      if by_old <> 0 then by_old
      else option_compare compare_identity left.new_identity right.new_identity

let sort_uniq_changes values = List.sort_uniq compare_change values
let side_rank = function Old -> 0 | New -> 1 | Both -> 2

let compare_unavailable left right =
  let by_subject = compare_identity left.subject right.subject in
  if by_subject <> 0 then by_subject
  else
    let by_side = Int.compare (side_rank left.side) (side_rank right.side) in
    if by_side <> 0 then by_side else String.compare left.reason right.reason

let sort_uniq_unavailable values = List.sort_uniq compare_unavailable values

let make_change kind subject old_identity new_identity =
  { kind; subject; old_identity; new_identity }

let label_change ~subject old_identity new_identity =
  if
    identity_equal old_identity new_identity
    && not (String.equal old_identity.name new_identity.name)
  then [ make_change Label_changed subject (Some old_identity) (Some new_identity) ]
  else []

let normalize_identities ~context values =
  let sorted = List.sort compare_identity values in
  let rec loop reversed = function
    | [] -> Ok (List.rev reversed)
    | [ value ] -> Ok (List.rev (value :: reversed))
    | left :: (right :: _ as rest) ->
        if Hash.equal left.hash right.hash then
          if String.equal left.name right.name then loop reversed rest
          else
            error ~code:"E1540" "%s gives identity #%s both labels %S and %S" context
              (Hash.to_hex left.hash) left.name right.name
        else loop (left :: reversed) rest
  in
  loop [] sorted

let hash_list_equal left right =
  List.length left = List.length right && List.for_all2 identity_equal left right

let subset left right = List.for_all (fun item -> List.exists (identity_equal item) right) left

let set_identity name values =
  let bytes = String.concat "\000" (List.map (fun value -> Hash.to_hex value.hash) values) in
  { name; hash = Hash.of_string bytes }

type normalized_operation = {
  operation : identity;
  raw_authority : identity list;
  normalizer : identity;
  summarizer : identity;
  simulator : identity;
  driver : identity;
  row : identity list;
}

let normalize_operation (fact : Governance_why_effect.operation_fact) =
  let operation = identity_of_why fact.operation in
  let* raw_authority =
    normalize_identities
      ~context:(operation.name ^ " raw authority")
      (List.map identity_of_why fact.raw_authority)
  in
  let* row =
    normalize_identities ~context:(operation.name ^ " driver row")
      (List.map identity_of_why fact.driver_introduced_raw_row)
  in
  Ok
    {
      operation;
      raw_authority;
      normalizer = identity_of_why fact.normalizer;
      summarizer = identity_of_why fact.summarizer;
      simulator = identity_of_why fact.simulator;
      driver = identity_of_why fact.driver;
      row;
    }

let normalized_operation_equal left right =
  exact_identity_equal left.operation right.operation
  && List.length left.raw_authority = List.length right.raw_authority
  && List.for_all2 exact_identity_equal left.raw_authority right.raw_authority
  && exact_identity_equal left.normalizer right.normalizer
  && exact_identity_equal left.summarizer right.summarizer
  && exact_identity_equal left.simulator right.simulator
  && exact_identity_equal left.driver right.driver
  && List.length left.row = List.length right.row
  && List.for_all2 exact_identity_equal left.row right.row

let normalize_operations ~facade facts =
  let rec collect reversed = function
    | [] -> Ok reversed
    | fact :: rest ->
        let* value = normalize_operation fact in
        if not (List.exists (identity_equal value.operation) facade) then
          error ~code:"E1541" "reached operation #%s is absent from the complete facade set"
            (Hash.to_hex value.operation.hash)
        else collect (value :: reversed) rest
  in
  let* values = collect [] facts in
  let sorted =
    List.sort (fun left right -> compare_identity left.operation right.operation) values
  in
  let rec dedupe reversed = function
    | [] -> Ok (List.rev reversed)
    | [ value ] -> Ok (List.rev (value :: reversed))
    | left :: (right :: _ as rest) ->
        if identity_equal left.operation right.operation then
          if normalized_operation_equal left right then dedupe reversed rest
          else
            error ~code:"E1540" "reached operation #%s has conflicting detail facts"
              (Hash.to_hex left.operation.hash)
        else dedupe (left :: reversed) rest
  in
  dedupe [] sorted

type normalized_chain = {
  chain_identity : identity;
  source_path : identity list;
  application_member : identity;
  application_ordinal : int;
  operation : identity;
  forwarding_layers : identity list;
  live_leaf : identity;
  driver : identity;
  raw_effect : identity;
}

let encode_hashes label values =
  String.concat "\000"
    (label
    :: string_of_int (List.length values)
    :: List.map (fun value -> Hash.to_hex value.hash) values)

let attribution_identity ~source_path ~application_member ~application_ordinal ~operation
    ~forwarding_layers ~live_leaf ~driver ~raw_effect =
  let bytes =
    String.concat "\000"
      [
        "governance-review-attribution-chain-v1";
        encode_hashes "source-path" source_path;
        "application-member";
        Hash.to_hex application_member.hash;
        "application-ordinal";
        string_of_int application_ordinal;
        "operation";
        Hash.to_hex operation.hash;
        encode_hashes "forwarding-layers" forwarding_layers;
        "live-leaf";
        Hash.to_hex live_leaf.hash;
        "driver";
        Hash.to_hex driver.hash;
        "raw-effect";
        Hash.to_hex raw_effect.hash;
      ]
  in
  { name = "attribution-chain"; hash = Hash.of_string bytes }

let normalize_chain (chain : Governance_why_effect.chain) =
  if chain.application_site.ordinal < 0 then
    error ~code:"E1541" "attribution application ordinal %d is negative"
      chain.application_site.ordinal
  else
    let source_path = List.map identity_of_why chain.source_path in
    let application_member = identity_of_why chain.application_site.member in
    let application_ordinal = chain.application_site.ordinal in
    let operation = identity_of_why chain.operation in
    let forwarding_layers = List.map identity_of_why chain.forwarding_layers in
    let live_leaf = identity_of_why chain.live_leaf in
    let driver = identity_of_why chain.driver in
    let raw_effect = identity_of_why chain.raw_effect in
    let chain_identity =
      attribution_identity ~source_path ~application_member ~application_ordinal ~operation
        ~forwarding_layers ~live_leaf ~driver ~raw_effect
    in
    Ok
      {
        chain_identity;
        source_path;
        application_member;
        application_ordinal;
        operation;
        forwarding_layers;
        live_leaf;
        driver;
        raw_effect;
      }

let normalized_chain_semantic_equal left right =
  hash_list_equal left.source_path right.source_path
  && identity_equal left.application_member right.application_member
  && Int.equal left.application_ordinal right.application_ordinal
  && identity_equal left.operation right.operation
  && hash_list_equal left.forwarding_layers right.forwarding_layers
  && identity_equal left.live_leaf right.live_leaf
  && identity_equal left.driver right.driver
  && identity_equal left.raw_effect right.raw_effect

let chain_identities value =
  value.application_member :: value.operation :: value.live_leaf :: value.driver :: value.raw_effect
  :: (value.source_path @ value.forwarding_layers)

let normalize_chains chains =
  let rec collect reversed = function
    | [] -> Ok reversed
    | chain :: rest ->
        let* value = normalize_chain chain in
        collect (value :: reversed) rest
  in
  let* values = collect [] chains in
  Ok
    (List.sort (fun left right -> compare_identity left.chain_identity right.chain_identity) values)

let dedupe_chains values =
  let rec loop reversed = function
    | [] -> Ok (List.rev reversed)
    | [ value ] -> Ok (List.rev (value :: reversed))
    | left :: (right :: _ as rest) ->
        if identity_equal left.chain_identity right.chain_identity then
          if normalized_chain_semantic_equal left right then loop reversed rest
          else
            error ~code:"E1540" "attribution chain #%s has conflicting semantic facts"
              (Hash.to_hex left.chain_identity.hash)
        else loop (left :: reversed) rest
  in
  loop [] values

type normalized_static = {
  facts : static_facts;
  facade_operations : identity list;
  reached_operations : normalized_operation list;
  chains : normalized_chain list;
  attribution_labels : identity list;
}

let normalize_static facts =
  if not (String.equal facts.profile profile) then
    error ~code:"E1539" "static facts use unsupported profile %S" facts.profile
  else
    let* facade_operations =
      normalize_identities ~context:"facade operation set" facts.facade_operations
    in
    let* reached_operations =
      normalize_operations ~facade:facade_operations facts.reached_operations
    in
    let* chains = normalize_chains facts.chains in
    let operation_identities (value : normalized_operation) =
      value.operation :: value.normalizer :: value.summarizer :: value.simulator :: value.driver
      :: (value.raw_authority @ value.row)
    in
    let raw_attribution_labels = List.concat_map chain_identities chains in
    let* _all_identities =
      normalize_identities ~context:"static identity facts"
        ((facts.requested_effect :: facts.source_root :: facts.facade :: facade_operations)
        @ List.concat_map operation_identities reached_operations
        @ raw_attribution_labels)
    in
    let* attribution_labels =
      normalize_identities ~context:"attribution identity facts" raw_attribution_labels
    in
    let* chains = dedupe_chains chains in
    Ok { facts; facade_operations; reached_operations; chains; attribution_labels }

let find_operation operation (values : normalized_operation list) =
  List.find_opt
    (fun (value : normalized_operation) -> identity_equal operation value.operation)
    values

let attempted_driver = function
  | Governance_explain.Not_attempted -> None
  | Governance_explain.Attempted value -> Some { name = value.driver_name; hash = value.driver_id }

let validate_link (dynamic : dynamic_facts) (static : normalized_static) =
  if not (List.exists (identity_equal dynamic.operation) static.facade_operations) then
    error ~code:"E1539" "dynamic operation #%s is absent from the static facade operation set"
      (Hash.to_hex dynamic.operation.hash)
  else
    match
      (attempted_driver dynamic.attempt, find_operation dynamic.operation static.reached_operations)
    with
    | Some driver, Some operation when not (identity_equal driver operation.driver) ->
        error ~code:"E1539" "dynamic attempted driver #%s disagrees with static driver #%s"
          (Hash.to_hex driver.hash)
          (Hash.to_hex operation.driver.hash)
    | _ -> Ok ()

let make_snapshot ~dynamic ~static =
  match (dynamic, static) with
  | None, None -> error ~code:"E1539" "a comparison snapshot contains no producer family"
  | dynamic, None -> Ok { dynamic; static = None }
  | None, Some static ->
      let* static = normalize_static static in
      Ok { dynamic = None; static = Some static.facts }
  | Some dynamic, Some static ->
      let* static = normalize_static static in
      let* () = validate_link dynamic static in
      Ok { dynamic = Some dynamic; static = Some static.facts }

let attempt_equal left right =
  match (left, right) with
  | Governance_explain.Not_attempted, Governance_explain.Not_attempted -> true
  | Governance_explain.Attempted left, Governance_explain.Attempted right ->
      String.equal left.state right.state
      && Hash.equal left.attempt_id right.attempt_id
      && Hash.equal left.driver_id right.driver_id
      && Option.equal Hash.equal left.receipt_id right.receipt_id
      && Option.equal Hash.equal left.external_receipt_digest right.external_receipt_digest
  | Governance_explain.Not_attempted, Governance_explain.Attempted _
  | Governance_explain.Attempted _, Governance_explain.Not_attempted ->
      false

let attempt_identity = function
  | Governance_explain.Not_attempted -> identity_of_string "action" "not-attempted"
  | Governance_explain.Attempted value ->
      let optional_hash = Option.fold ~none:"none" ~some:Hash.to_hex in
      identity_of_string "action"
        (String.concat "\000"
           [
             value.state;
             Hash.to_hex value.attempt_id;
             Hash.to_hex value.driver_id;
             optional_hash value.receipt_id;
             optional_hash value.external_receipt_digest;
           ])

let no_attempt = function Governance_explain.Not_attempted -> true | Attempted _ -> false

let proposal_hash_carrier = function
  | { Form.head = "hash"; args = [ Form.Hash proposal_id ]; _ } -> Some proposal_id
  | _ -> None

let released_decision_parts = function
  | {
      Form.head = ("approved-v1" | "denied-v1") as head;
      args = [ Form.F proposal; Form.F actor; Form.F evidence ];
      _;
    } ->
      Option.map
        (fun proposal_id -> (head, proposal_id, [ actor; evidence ]))
        (proposal_hash_carrier proposal)
  | { Form.head = "escalate-v1" as head; args = [ Form.F proposal; Form.F reason ]; _ } ->
      Option.map
        (fun proposal_id -> (head, proposal_id, [ reason ]))
        (proposal_hash_carrier proposal)
  | _ -> None

let decision_equal old_ new_ =
  String.equal old_.decision_kind new_.decision_kind
  &&
  match (released_decision_parts old_.decision, released_decision_parts new_.decision) with
  | Some (old_head, old_proposal, old_fields), Some (new_head, new_proposal, new_fields) ->
      Hash.equal old_proposal old_.proposal_id
      && Hash.equal new_proposal new_.proposal_id
      && String.equal old_head new_head
      && List.length old_fields = List.length new_fields
      && List.for_all2 form_equal old_fields new_fields
  | _ -> form_equal old_.decision new_.decision

let classify_dynamic ~(old_ : dynamic_facts) ~(new_ : dynamic_facts) =
  let subject = old_.operation in
  let changes = ref [] in
  let add kind old_identity new_identity =
    changes := make_change kind subject (Some old_identity) (Some new_identity) :: !changes
  in
  changes := label_change ~subject old_.operation new_.operation @ !changes;
  let call_equal =
    Hash.equal old_.call_id new_.call_id
    && identity_equal old_.operation new_.operation
    && form_equal old_.call new_.call
  in
  if not call_equal then
    add Call_changed { name = "call"; hash = old_.call_id } { name = "call"; hash = new_.call_id };
  let authority_equal = form_equal old_.authority new_.authority in
  if not authority_equal then
    add Authority_changed
      (identity_of_form "authority" old_.authority)
      (identity_of_form "authority" new_.authority);
  let policy_equal =
    Hash.equal old_.policy_id new_.policy_id && form_equal old_.policy new_.policy
  in
  if not policy_equal then
    add Policy_changed
      { name = "bound-policy"; hash = old_.policy_id }
      { name = "bound-policy"; hash = new_.policy_id };
  let assessment_equal =
    Hash.equal old_.assessment_id new_.assessment_id && form_equal old_.assessment new_.assessment
  in
  if not assessment_equal then
    add Assessment_changed
      { name = "assessment"; hash = old_.assessment_id }
      { name = "assessment"; hash = new_.assessment_id };
  let preview_equal = form_equal old_.preview new_.preview in
  if not preview_equal then
    add Preview_changed
      (identity_of_form "preview" old_.preview)
      (identity_of_form "preview" new_.preview);
  let evaluation_equal =
    String.equal old_.policy_rule new_.policy_rule
    && String.equal old_.recorded_verdict new_.recorded_verdict
  in
  if not evaluation_equal then
    add Evaluation_changed
      (identity_of_string "evaluation" (old_.policy_rule ^ "\000" ^ old_.recorded_verdict))
      (identity_of_string "evaluation" (new_.policy_rule ^ "\000" ^ new_.recorded_verdict));
  let decision_equal = decision_equal old_ new_ in
  if not decision_equal then
    add Decision_changed
      (identity_of_form ("decision:" ^ old_.decision_kind) old_.decision)
      (identity_of_form ("decision:" ^ new_.decision_kind) new_.decision);
  let attempt_equal = attempt_equal old_.attempt new_.attempt in
  if not attempt_equal then
    add Attempt_changed (attempt_identity old_.attempt) (attempt_identity new_.attempt);
  (match (attempted_driver old_.attempt, attempted_driver new_.attempt) with
  | Some old_driver, Some new_driver ->
      changes := label_change ~subject old_driver new_driver @ !changes
  | _ -> ());
  let semantic_equal =
    call_equal && authority_equal && policy_equal && assessment_equal && preview_equal
    && evaluation_equal && decision_equal && attempt_equal
  in
  let rendering_equal =
    form_equal old_.proposal_rendering new_.proposal_rendering
    && String.equal old_.proposal_summary new_.proposal_summary
  in
  if not rendering_equal then
    let kind =
      if semantic_equal && no_attempt old_.attempt && no_attempt new_.attempt then
        Proposal_rendering_only
      else Proposal_rendering_changed
    in
    add kind
      { name = "proposal"; hash = old_.proposal_id }
      { name = "proposal"; hash = new_.proposal_id }
  else if semantic_equal && not (Hash.equal old_.proposal_id new_.proposal_id) then
    add Other_semantic_change
      { name = "proposal"; hash = old_.proposal_id }
      { name = "proposal"; hash = new_.proposal_id };
  Ok { changes = sort_uniq_changes !changes; unavailable = [] }

let labels_for_operation (old_ : normalized_operation) (new_ : normalized_operation) =
  let subject = old_.operation in
  label_change ~subject old_.operation new_.operation
  @ label_change ~subject old_.normalizer new_.normalizer
  @ label_change ~subject old_.summarizer new_.summarizer
  @ label_change ~subject old_.simulator new_.simulator
  @ label_change ~subject old_.driver new_.driver
  @ List.concat_map
      (fun old_identity ->
        match List.find_opt (identity_equal old_identity) new_.raw_authority with
        | None -> []
        | Some new_identity -> label_change ~subject old_identity new_identity)
      old_.raw_authority
  @ List.concat_map
      (fun old_identity ->
        match List.find_opt (identity_equal old_identity) new_.row with
        | None -> []
        | Some new_identity -> label_change ~subject old_identity new_identity)
      old_.row

let labels_for_identity_sets old_ new_ =
  List.concat_map
    (fun old_identity ->
      match List.find_opt (identity_equal old_identity) new_ with
      | None -> []
      | Some new_identity -> label_change ~subject:old_identity old_identity new_identity)
    old_

let compare_operation (old_ : normalized_operation) (new_ : normalized_operation) =
  let subject = old_.operation in
  let labels = labels_for_operation old_ new_ in
  let authority_equal = hash_list_equal old_.raw_authority new_.raw_authority in
  let normalizer_equal = identity_equal old_.normalizer new_.normalizer in
  let summarizer_equal = identity_equal old_.summarizer new_.summarizer in
  let simulator_equal = identity_equal old_.simulator new_.simulator in
  let driver_equal = identity_equal old_.driver new_.driver in
  let row_equal = hash_list_equal old_.row new_.row in
  let all_other_equal =
    authority_equal && normalizer_equal && simulator_equal && driver_equal && row_equal
  in
  if (not summarizer_equal) && all_other_equal && labels = [] then
    [ make_change Operation_rendering_only subject (Some old_.summarizer) (Some new_.summarizer) ]
  else
    let changes = ref labels in
    let add kind old_identity new_identity =
      changes := make_change kind subject (Some old_identity) (Some new_identity) :: !changes
    in
    if not authority_equal then
      add Authority_changed
        (set_identity "raw-authority" old_.raw_authority)
        (set_identity "raw-authority" new_.raw_authority);
    if not normalizer_equal then add Normalizer_changed old_.normalizer new_.normalizer;
    if not simulator_equal then add Simulator_changed old_.simulator new_.simulator;
    if not driver_equal then add Driver_changed old_.driver new_.driver;
    (if not row_equal then
       let kind =
         if subset old_.row new_.row then Driver_row_widened
         else if subset new_.row old_.row then Driver_row_narrowed
         else Driver_row_changed
       in
       add kind (set_identity "driver-row" old_.row) (set_identity "driver-row" new_.row));
    if not summarizer_equal then add Summarizer_changed old_.summarizer new_.summarizer;
    !changes

let classify_static ~(old_ : static_facts) ~(new_ : static_facts) =
  let* old_ = normalize_static old_ in
  let* new_ = normalize_static new_ in
  if not (identity_equal old_.facts.requested_effect new_.facts.requested_effect) then
    error ~code:"E1539" "static comparisons request effects #%s and #%s"
      (Hash.to_hex old_.facts.requested_effect.hash)
      (Hash.to_hex new_.facts.requested_effect.hash)
  else
    let changes = ref [] in
    let unavailable = ref [] in
    let facade_subject = old_.facts.facade in
    changes :=
      label_change ~subject:old_.facts.source_root old_.facts.source_root new_.facts.source_root
      @ !changes;
    if not (identity_equal old_.facts.source_root new_.facts.source_root) then
      changes :=
        make_change Source_root_changed old_.facts.source_root (Some old_.facts.source_root)
          (Some new_.facts.source_root)
        :: !changes;
    changes := label_change ~subject:facade_subject old_.facts.facade new_.facts.facade @ !changes;
    if not (identity_equal old_.facts.facade new_.facts.facade) then
      changes :=
        make_change Facade_changed facade_subject (Some old_.facts.facade) (Some new_.facts.facade)
        :: !changes;
    let old_only =
      List.filter
        (fun operation -> not (List.exists (identity_equal operation) new_.facade_operations))
        old_.facade_operations
    in
    let new_only =
      List.filter
        (fun operation -> not (List.exists (identity_equal operation) old_.facade_operations))
        new_.facade_operations
    in
    List.iter
      (fun operation ->
        changes := make_change Facade_removed operation (Some operation) None :: !changes)
      old_only;
    List.iter
      (fun operation ->
        changes := make_change Facade_added operation None (Some operation) :: !changes)
      new_only;
    List.iter
      (fun old_operation ->
        match List.find_opt (identity_equal old_operation) new_.facade_operations with
        | None -> ()
        | Some new_operation -> (
            changes := label_change ~subject:old_operation old_operation new_operation @ !changes;
            let old_fact = find_operation old_operation old_.reached_operations in
            let new_fact = find_operation new_operation new_.reached_operations in
            match (old_fact, new_fact) with
            | Some old_fact, Some new_fact ->
                changes := compare_operation old_fact new_fact @ !changes
            | None, None ->
                unavailable :=
                  { subject = old_operation; side = Both; reason = unavailable_reason }
                  :: !unavailable
            | None, Some _ ->
                unavailable :=
                  { subject = old_operation; side = Old; reason = unavailable_reason }
                  :: !unavailable
            | Some _, None ->
                unavailable :=
                  { subject = old_operation; side = New; reason = unavailable_reason }
                  :: !unavailable))
      old_.facade_operations;
    changes := labels_for_identity_sets old_.attribution_labels new_.attribution_labels @ !changes;
    let old_chains = List.map (fun value -> value.chain_identity) old_.chains in
    let new_chains = List.map (fun value -> value.chain_identity) new_.chains in
    if not (hash_list_equal old_chains new_chains) then
      changes :=
        make_change Attribution_changed old_.facts.requested_effect
          (Some (set_identity "attribution-chains" old_chains))
          (Some (set_identity "attribution-chains" new_chains))
        :: !changes;
    if not (String.equal old_.facts.topology new_.facts.topology) then
      changes :=
        make_change Other_semantic_change facade_subject
          (Some (identity_of_string "topology" old_.facts.topology))
          (Some (identity_of_string "topology" new_.facts.topology))
        :: !changes;
    Ok { changes = sort_uniq_changes !changes; unavailable = sort_uniq_unavailable !unavailable }

let compare ~old_ ~new_ =
  let collect_dynamic =
    match (old_.dynamic, new_.dynamic) with
    | None, None -> Ok { changes = []; unavailable = [] }
    | Some old_, Some new_ -> classify_dynamic ~old_ ~new_
    | None, Some _ | Some _, None ->
        error ~code:"E1539" "the dynamic producer family is present at only one endpoint"
  in
  let* dynamic = collect_dynamic in
  let collect_static =
    match (old_.static, new_.static) with
    | None, None -> Ok { changes = []; unavailable = [] }
    | Some old_, Some new_ -> classify_static ~old_ ~new_
    | None, Some _ | Some _, None ->
        error ~code:"E1539" "the static producer family is present at only one endpoint"
  in
  let* static = collect_static in
  let changes = sort_uniq_changes (dynamic.changes @ static.changes) in
  let unavailable = sort_uniq_unavailable (dynamic.unavailable @ static.unavailable) in
  let completeness =
    if unavailable <> [] then Partial else if changes = [] then No_change else Complete
  in
  Ok { schema; completeness; changes; unavailable; evidence_limits }

let completeness_to_string = function
  | Complete -> "complete"
  | Partial -> "partial"
  | No_change -> "no-change"

let side_to_string = function Old -> "old" | New -> "new" | Both -> "both"

let show_identity = function
  | None -> "none"
  | Some value -> Printf.sprintf "%s #%s" value.name (Hash.to_hex value.hash)

let render_text report =
  let buffer = Buffer.create 1024 in
  Printf.bprintf buffer "ok governance-review-diff-v1 schema=%s\n" report.schema;
  Printf.bprintf buffer "completeness %s\n" (completeness_to_string report.completeness);
  Printf.bprintf buffer "change-count %d\n" (List.length report.changes);
  List.iter
    (fun change ->
      Printf.bprintf buffer "change kind=%s subject=%s #%s old=%s new=%s\n"
        (change_kind_to_string change.kind)
        change.subject.name (Hash.to_hex change.subject.hash)
        (show_identity change.old_identity)
        (show_identity change.new_identity))
    report.changes;
  Printf.bprintf buffer "unavailable-count %d\n" (List.length report.unavailable);
  List.iter
    (fun value ->
      Printf.bprintf buffer "unavailable subject=%s #%s side=%s reason=%s\n" value.subject.name
        (Hash.to_hex value.subject.hash) (side_to_string value.side) value.reason)
    report.unavailable;
  List.iter (Printf.bprintf buffer "evidence-limit %s\n") report.evidence_limits;
  Buffer.contents buffer

let identity_json value =
  `Assoc [ ("name", `String value.name); ("identity", `String (Hash.to_hex value.hash)) ]

let optional_identity_json = function None -> `Null | Some value -> identity_json value

let render_json_v1 report =
  let change_json change =
    `Assoc
      [
        ("kind", `String (change_kind_to_string change.kind));
        ("subject", identity_json change.subject);
        ("old", optional_identity_json change.old_identity);
        ("new", optional_identity_json change.new_identity);
      ]
  in
  let unavailable_json value =
    `Assoc
      [
        ("subject", identity_json value.subject);
        ("side", `String (side_to_string value.side));
        ("reason", `String value.reason);
      ]
  in
  Yojson.Safe.to_string
    (`Assoc
       [
         ("schema", `String report.schema);
         ("completeness", `String (completeness_to_string report.completeness));
         ("changes", `List (List.map change_json report.changes));
         ("unavailable", `List (List.map unavailable_json report.unavailable));
         ("evidence_limits", `List (List.map (fun value -> `String value) report.evidence_limits));
       ])
