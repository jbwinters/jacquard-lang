type report = {
  head : Hash.t;
  entries : int;
  calls : int;
  policies : int;
  assessments : int;
  proposals : int;
  consents : int;
  transformed_calls : int;
}

let ( let* ) = Result.bind
let error ~code fmt = Printf.ksprintf (fun message -> Error [ Diag.error ~code message ]) fmt
let hash_code value = Form.form "hash" [ Form.Hash value ]
let code_hash value = Hash.of_string (Printer.print_compact value)
let version = function { Form.head = "governance-v0"; args = []; _ } -> true | _ -> false

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
    | (Form.Int _ | Form.Real _ | Form.Text _ | Form.Sym _ | Form.Hash _) :: _ -> None
  in
  loop [] args

let hash_at ~code ~kind ~index value =
  match hash_value value with
  | Some hash -> Ok hash
  | None -> error ~code "%s artifact %d has a malformed hash field" kind index

let text_at ~code ~kind ~index value =
  match text_value value with
  | Some text -> Ok text
  | None -> error ~code "%s artifact %d has a malformed text field" kind index

type authority =
  | Effect of Hash.t
  | Resource of { effect_id : Hash.t; scope : string; configuration : Hash.t }

let compare_effect left right =
  match (Effect_registry.canonical_order left, Effect_registry.canonical_order right) with
  | Some left, Some right -> Int.compare left right
  | Some _, None -> -1
  | None, Some _ -> 1
  | None, None -> String.compare (Hash.to_hex left) (Hash.to_hex right)

let compare_authority left right =
  let effect_id_of_authority = function
    | Effect effect_id | Resource { effect_id; _ } -> effect_id
  in
  match compare_effect (effect_id_of_authority left) (effect_id_of_authority right) with
  | comparison when comparison <> 0 -> comparison
  | _ -> (
      match (left, right) with
      | Effect _, Effect _ -> 0
      | Effect _, Resource _ -> -1
      | Resource _, Effect _ -> 1
      | ( Resource { scope = left_scope; configuration = left_configuration; _ },
          Resource { scope = right_scope; configuration = right_configuration; _ } ) -> (
          match String.compare left_scope right_scope with
          | comparison when comparison <> 0 -> comparison
          | _ -> String.compare (Hash.to_hex left_configuration) (Hash.to_hex right_configuration)))

let parse_authority ~kind ~index = function
  | { Form.head = "governance-authority-list-v0"; args; _ } as form -> (
      match child_forms args with
      | None -> error ~code:"E1500" "%s artifact %d has a malformed authority list" kind index
      | Some values ->
          let parse_entry position = function
            | { Form.head = "governance-effect-v0"; args = [ Form.F effect_hash ]; _ } ->
                let* effect_id =
                  hash_at ~code:"E1500" ~kind:"authority" ~index:position effect_hash
                in
                Ok (Effect effect_id)
            | {
                Form.head = "governance-resource-v0";
                args = [ Form.F effect_hash; Form.F scope; Form.F configuration ];
                _;
              } ->
                let* effect_id =
                  hash_at ~code:"E1500" ~kind:"authority" ~index:position effect_hash
                in
                let* scope = text_at ~code:"E1500" ~kind:"authority" ~index:position scope in
                let* configuration =
                  hash_at ~code:"E1500" ~kind:"authority" ~index:position configuration
                in
                if String.equal scope "" then
                  error ~code:"E1501" "%s artifact %d has an empty authority scope" kind index
                else Ok (Resource { effect_id; scope; configuration })
            | _ ->
                error ~code:"E1500" "%s artifact %d has malformed authority entry %d" kind index
                  position
          in
          let rec parse position reversed = function
            | [] -> Ok (List.rev reversed)
            | value :: rest ->
                let* parsed = parse_entry position value in
                parse (position + 1) (parsed :: reversed) rest
          in
          let* parsed = parse 0 [] values in
          let rec validate seen previous = function
            | [] -> Ok (form, parsed)
            | entry :: rest -> (
                if
                  Option.fold ~none:false
                    ~some:(fun prior -> compare_authority prior entry >= 0)
                    previous
                then
                  error ~code:"E1501" "%s artifact %d authority is not in strict canonical order"
                    kind index
                else
                  let effect_id =
                    match entry with Effect id | Resource { effect_id = id; _ } -> id
                  in
                  match entry with
                  | Effect _ when List.exists (Hash.equal effect_id) seen ->
                      error ~code:"E1501" "%s artifact %d repeats an Effect authority" kind index
                  | Effect _ -> validate (effect_id :: seen) (Some entry) rest
                  | Resource _ when not (List.exists (Hash.equal effect_id) seen) ->
                      error ~code:"E1501"
                        "%s artifact %d has a Resource without its preceding Effect" kind index
                  | Resource _ -> validate seen (Some entry) rest)
          in
          validate [] None parsed)
  | _ -> error ~code:"E1500" "%s artifact %d has a malformed authority carrier" kind index

let risk_rank = function
  | { Form.head = "low"; args = []; _ } -> Some 0
  | { Form.head = "medium"; args = []; _ } -> Some 1
  | { Form.head = "high"; args = []; _ } -> Some 2
  | { Form.head = "forbidden"; args = []; _ } -> Some 3
  | _ -> None

let valid_confidence value = Float.is_finite value && value >= 0. && value <= 1.

type policy_kind = Live | Dry

type call_artifact = {
  call_index : int;
  call_id : Hash.t;
  call_authority : Form.t;
  parent_call_id : Hash.t option;
}

type policy_artifact = { policy_index : int; policy_id : Hash.t; policy_kind : policy_kind }
type assessment_artifact = { assessment_index : int; assessment_id : Hash.t; assessment : Form.t }

type proposal_artifact = {
  proposal_index : int;
  proposal_id : Hash.t;
  proposal_call_id : Hash.t;
  proposal_policy_id : Hash.t;
  proposal_assessment_id : Hash.t;
  proposal_authority : Form.t;
}

let valid_operation_name name =
  let length = String.length name in
  let lower character = character >= 'a' && character <= 'z' in
  let digit character = character >= '0' && character <= '9' in
  let rec loop index need_start =
    if index = length then not need_start
    else
      let character = name.[index] in
      if need_start then lower character && loop (index + 1) false
      else if lower character || digit character then loop (index + 1) false
      else if character = '.' || character = '-' then loop (index + 1) true
      else (character = '?' || character = '!') && index + 1 = length
  in
  length > 0 && loop 0 true

let resolve_operation_id store ~index name =
  match String.index_opt name '.' with
  | None | Some 0 ->
      error ~code:"E1501" "Call artifact %d operation name is not effect-qualified" index
  | Some separator when separator = String.length name - 1 ->
      error ~code:"E1501" "Call artifact %d operation name is not effect-qualified" index
  | Some separator -> (
      let effect_name = String.sub name 0 separator in
      let operation_name = String.sub name (separator + 1) (String.length name - separator - 1) in
      match Store.lookup_kind store effect_name Resolve.KEffect with
      | None -> error ~code:"E1501" "Call artifact %d effect `%s` is not resolved" index effect_name
      | Some { Resolve.hash = effect_hash; _ } -> (
          match Store.locate store effect_hash with
          | Ok
              {
                Store.decl_hash;
                decl = { Kernel.it = Kernel.DefEffect { ops; _ }; _ };
                role = Store.Whole;
                _;
              } ->
              let rec find ordinal = function
                | [] ->
                    error ~code:"E1501"
                      "Call artifact %d operation `%s` is not in resolved effect `%s`" index
                      operation_name effect_name
                | ({ Kernel.op_name; _ } : Kernel.opspec) :: _
                  when String.equal op_name operation_name ->
                    Ok (Canon.op_hash decl_hash ordinal)
                | _ :: rest -> find (ordinal + 1) rest
              in
              find 0 ops
          | Ok _ | Error _ ->
              error ~code:"E1501" "Call artifact %d effect `%s` has no exact declaration" index
                effect_name))

let parse_parent ~index = function
  | { Form.head = "none-v0"; args = []; _ } -> Ok None
  | { Form.head = "some-v0"; args = [ Form.F value ]; _ } ->
      let* parent = hash_at ~code:"E1500" ~kind:"Call parent" ~index value in
      Ok (Some parent)
  | _ -> error ~code:"E1500" "Call artifact %d has a malformed parent-call-id" index

let parse_call ~store index = function
  | {
      Form.head = "governance-call-artifact-v1";
      args =
        [
          Form.F version_value;
          Form.F carried_value;
          Form.F operation_value;
          Form.F operation_name_value;
          Form.F arguments;
          Form.F authority;
          Form.F summary_value;
          Form.F preconditions;
          Form.F parent;
        ];
      _;
    } ->
      if not (version version_value) then
        error ~code:"E1500" "Call artifact %d has an unsupported Governance version" index
      else
        let* call_id = hash_at ~code:"E1500" ~kind:"Call" ~index carried_value in
        let* operation_id = hash_at ~code:"E1500" ~kind:"Call operation" ~index operation_value in
        let* operation_name =
          text_at ~code:"E1500" ~kind:"Call operation name" ~index operation_name_value
        in
        let* _summary = text_at ~code:"E1500" ~kind:"Call summary" ~index summary_value in
        let* authority, _ = parse_authority ~kind:"Call" ~index authority in
        let* parent_call_id = parse_parent ~index parent in
        if not (valid_operation_name operation_name) then
          error ~code:"E1501" "Call artifact %d has a noncanonical operation name" index
        else
          let* resolved_operation_id = resolve_operation_id store ~index operation_name in
          if not (Hash.equal operation_id resolved_operation_id) then
            error ~code:"E1501" "Call artifact %d operation hash does not match resolved `%s`" index
              operation_name
          else
            let subject =
              Form.form "governance-call-v0"
                [
                  Form.F version_value;
                  Form.F (hash_code operation_id);
                  Form.F arguments;
                  Form.F authority;
                  Form.F preconditions;
                  Form.F parent;
                ]
            in
            let computed = code_hash subject in
            if not (Hash.equal call_id computed) then
              error ~code:"E1501"
                "Call artifact %d carries #%s but canonical governance-call-v0 bytes hash to #%s"
                index (Hash.to_hex call_id) (Hash.to_hex computed)
            else Ok { call_index = index; call_id; call_authority = authority; parent_call_id }
  | _ -> error ~code:"E1500" "Call artifact %d has a malformed v1 wrapper" index

let parse_policy_value ~index value =
  match value with
  | {
   Form.head = "live-policy-v0";
   args = [ Form.F version_value; Form.F auto; Form.F ask; Form.F confidence ];
   _;
  } -> (
      if not (version version_value) then
        error ~code:"E1500" "Policy artifact %d has an unsupported Governance version" index
      else
        match (risk_rank auto, risk_rank ask, real_value confidence) with
        | Some auto, Some ask, Some confidence when valid_confidence confidence && auto <= ask ->
            Ok Live
        | _ -> error ~code:"E1501" "Policy artifact %d has a noncanonical live policy" index)
  | { Form.head = "dry-policy-v0"; args = [ Form.F version_value; Form.F confidence ]; _ } -> (
      if not (version version_value) then
        error ~code:"E1500" "Policy artifact %d has an unsupported Governance version" index
      else
        match real_value confidence with
        | Some confidence when valid_confidence confidence -> Ok Dry
        | _ -> error ~code:"E1501" "Policy artifact %d has a noncanonical dry policy" index)
  | _ -> error ~code:"E1500" "Policy artifact %d has a malformed policy value" index

let parse_policy index = function
  | {
      Form.head = "bound-policy-artifact-v1";
      args = [ Form.F version_value; Form.F carried_value; Form.F value ];
      _;
    } ->
      if not (version version_value) then
        error ~code:"E1500" "Policy artifact %d has an unsupported Governance version" index
      else
        let* policy_id = hash_at ~code:"E1500" ~kind:"Policy" ~index carried_value in
        let* policy_kind = parse_policy_value ~index value in
        let computed = code_hash value in
        if not (Hash.equal policy_id computed) then
          error ~code:"E1501"
            "Policy artifact %d carries #%s but canonical policy bytes hash to #%s" index
            (Hash.to_hex policy_id) (Hash.to_hex computed)
        else Ok { policy_index = index; policy_id; policy_kind }
  | _ -> error ~code:"E1500" "Policy artifact %d has a malformed v1 wrapper" index

let parse_assessment index = function
  | {
      Form.head = "governance-assessment-v0";
      args =
        [ Form.F version_value; Form.F risk; Form.F confidence; Form.F reasons; Form.F _evidence ];
      _;
    } as assessment ->
      let reasons_valid =
        match reasons with
        | { Form.head = "text-list-v1"; args; _ } ->
            Option.fold ~none:false
              ~some:(List.for_all (fun value -> Option.is_some (text_value value)))
              (child_forms args)
        | _ -> false
      in
      if
        (not (version version_value))
        || Option.is_none (risk_rank risk)
        || (not reasons_valid)
        || not (Option.fold ~none:false ~some:valid_confidence (real_value confidence))
      then error ~code:"E1501" "Assessment artifact %d is not canonical Governance v0" index
      else Ok { assessment_index = index; assessment_id = code_hash assessment; assessment }
  | _ -> error ~code:"E1500" "Assessment artifact %d has a malformed v0 carrier" index

let parse_outcome = function
  | {
      Form.head = "governance-outcome-summary-v0";
      args = [ Form.F version_value; Form.F status; Form.F digest; Form.F detail ];
      _;
    } ->
      version version_value
      && Option.fold ~none:false
           ~some:(fun value -> not (String.equal value ""))
           (text_value status)
      && Option.is_some (hash_value digest)
      && Option.is_some (text_value detail)
  | _ -> false

let parse_preview ~index = function
  | { Form.head = "none-v0"; args = []; _ } -> Ok ()
  | { Form.head = "some-v0"; args = [ Form.F outcome ]; _ } when parse_outcome outcome -> Ok ()
  | _ -> error ~code:"E1501" "Proposal artifact %d has a noncanonical preview" index

let parse_proposal index = function
  | {
      Form.head = "governance-proposal-artifact-v1";
      args =
        [
          Form.F version_value;
          Form.F carried_value;
          Form.F call_value;
          Form.F policy_value;
          Form.F assessment_value;
          Form.F rendering;
          Form.F summary_value;
          Form.F authority;
          Form.F preview;
        ];
      _;
    } ->
      if not (version version_value) then
        error ~code:"E1500" "Proposal artifact %d has an unsupported Governance version" index
      else
        let* proposal_id = hash_at ~code:"E1500" ~kind:"Proposal" ~index carried_value in
        let* proposal_call_id = hash_at ~code:"E1500" ~kind:"Proposal call" ~index call_value in
        let* proposal_policy_id =
          hash_at ~code:"E1500" ~kind:"Proposal policy" ~index policy_value
        in
        let* proposal_assessment_id =
          hash_at ~code:"E1500" ~kind:"Proposal assessment" ~index assessment_value
        in
        let* summary = text_at ~code:"E1500" ~kind:"Proposal summary" ~index summary_value in
        let* proposal_authority, _ = parse_authority ~kind:"Proposal" ~index authority in
        let* () = parse_preview ~index preview in
        let subject =
          Form.form "governance-proposal-v0"
            [
              Form.F version_value;
              Form.F (hash_code proposal_call_id);
              Form.F (hash_code proposal_policy_id);
              Form.F (hash_code proposal_assessment_id);
              Form.F proposal_authority;
              Form.F preview;
              Form.F rendering;
              Form.F (Form.form "lit" [ Form.Text summary ]);
            ]
        in
        let computed = code_hash subject in
        if not (Hash.equal proposal_id computed) then
          error ~code:"E1501"
            "Proposal artifact %d carries #%s but canonical governance-proposal-v0 bytes hash to \
             #%s"
            index (Hash.to_hex proposal_id) (Hash.to_hex computed)
        else
          Ok
            {
              proposal_index = index;
              proposal_id;
              proposal_call_id;
              proposal_policy_id;
              proposal_assessment_id;
              proposal_authority;
            }
  | _ -> error ~code:"E1500" "Proposal artifact %d has a malformed v1 wrapper" index

type verdict = Allow | Simulate | Ask | Block

type event =
  | Evaluated of {
      entry_index : int;
      call_id : Hash.t;
      policy_id : Hash.t;
      assessment : Form.t;
      assessment_id : Hash.t;
      verdict : verdict;
    }
  | Consented of {
      entry_index : int;
      call_id : Hash.t;
      proposal_id : Hash.t;
      decision_proposal_id : Hash.t;
    }
  | Completed of { entry_index : int; call_id : Hash.t }

let parse_verdict = function
  | { Form.head = "allow"; args = []; _ } -> Some Allow
  | { Form.head = "simulate"; args = []; _ } -> Some Simulate
  | { Form.head = "ask"; args = []; _ } -> Some Ask
  | { Form.head = "block"; args = []; _ } -> Some Block
  | _ -> None

let decision_proposal = function
  | { Form.head = "approved-v1"; args = Form.F proposal :: _; _ }
  | { Form.head = "denied-v1"; args = Form.F proposal :: _; _ }
  | { Form.head = "escalate-v1"; args = Form.F proposal :: _; _ } ->
      hash_value proposal
  | _ -> None

let parse_event entry_index = function
  | {
      Form.head = "audit-entry-v2";
      args =
        [
          Form.F
            {
              Form.head = "evaluated-v2";
              args =
                [
                  Form.F _version;
                  Form.F _sequence;
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
      match (hash_value call, hash_value policy, parse_verdict verdict) with
      | Some call_id, Some policy_id, Some verdict ->
          Ok
            (Evaluated
               {
                 entry_index;
                 call_id;
                 policy_id;
                 assessment;
                 assessment_id = code_hash assessment;
                 verdict;
               })
      | _ -> error ~code:"E1500" "Audit entry %d has malformed Evaluated linkage" entry_index)
  | {
      Form.head = "audit-entry-v2";
      args =
        [
          Form.F
            {
              Form.head = "consented-v2";
              args =
                [ Form.F _version; Form.F _sequence; Form.F call; Form.F proposal; Form.F decision ];
              _;
            };
        ];
      _;
    } -> (
      match (hash_value call, hash_value proposal, decision_proposal decision) with
      | Some call_id, Some proposal_id, Some decision_proposal_id ->
          Ok (Consented { entry_index; call_id; proposal_id; decision_proposal_id })
      | _ -> error ~code:"E1500" "Audit entry %d has malformed Consented linkage" entry_index)
  | {
      Form.head = "audit-entry-v2";
      args =
        [
          Form.F
            {
              Form.head = "completed-v2";
              args = Form.F _version :: Form.F _sequence :: Form.F call :: _;
              _;
            };
        ];
      _;
    } -> (
      match hash_value call with
      | Some call_id -> Ok (Completed { entry_index; call_id })
      | None -> error ~code:"E1500" "Audit entry %d has malformed Completed linkage" entry_index)
  | _ -> error ~code:"E1500" "Audit entry %d has an unsupported carrier" entry_index

let parse_indexed parse values =
  let rec loop index reversed = function
    | [] -> Ok (List.rev reversed)
    | value :: rest ->
        let* parsed = parse index value in
        loop (index + 1) (parsed :: reversed) rest
  in
  loop 0 [] values

let ensure_unique ~kind id index seen =
  match List.find_opt (fun (known, _) -> Hash.equal id known) seen with
  | None -> Ok ((id, index) :: seen)
  | Some (_, previous) ->
      error ~code:"E1502" "%s artifact %d duplicates identity from artifact %d" kind index previous

let validate_unique ~kind ~identity ~index values =
  let rec loop seen = function
    | [] -> Ok ()
    | value :: rest ->
        let* seen = ensure_unique ~kind (identity value) (index value) seen in
        loop seen rest
  in
  loop [] values

let find_by id identity values = List.find_opt (fun value -> Hash.equal id (identity value)) values

let require_by ~kind ~entry_index id identity values =
  match find_by id identity values with
  | Some value -> Ok value
  | None ->
      error ~code:"E1503" "Audit entry %d references missing %s #%s" entry_index kind
        (Hash.to_hex id)

type evaluation = {
  evaluation_entry : int;
  evaluation_call : Hash.t;
  evaluation_policy : Hash.t;
  evaluation_assessment : Hash.t;
  evaluation_verdict : verdict;
  mutable consented : bool;
}

let mark reference index = if not (List.mem index !reference) then reference := index :: !reference

let verify_links calls policies assessments proposals events =
  let used_calls = ref []
  and used_policies = ref []
  and used_assessments = ref []
  and used_proposals = ref [] in
  let evaluations = ref [] and consents = ref 0 in
  let rec loop = function
    | [] -> Ok ()
    | Evaluated event :: rest ->
        let* call =
          require_by ~kind:"Call" ~entry_index:event.entry_index event.call_id
            (fun value -> value.call_id)
            calls
        in
        let* policy =
          require_by ~kind:"Policy" ~entry_index:event.entry_index event.policy_id
            (fun value -> value.policy_id)
            policies
        in
        let* assessment =
          require_by ~kind:"Assessment" ~entry_index:event.entry_index event.assessment_id
            (fun value -> value.assessment_id)
            assessments
        in
        if not (Form.equal_ignoring_meta event.assessment assessment.assessment) then
          error ~code:"E1504" "Audit entry %d Assessment bytes disagree with artifact %d"
            event.entry_index assessment.assessment_index
        else (
          mark used_calls call.call_index;
          mark used_policies policy.policy_index;
          mark used_assessments assessment.assessment_index;
          evaluations :=
            {
              evaluation_entry = event.entry_index;
              evaluation_call = event.call_id;
              evaluation_policy = event.policy_id;
              evaluation_assessment = event.assessment_id;
              evaluation_verdict = event.verdict;
              consented = false;
            }
            :: !evaluations;
          loop rest)
    | Consented event :: rest -> (
        if not (Hash.equal event.proposal_id event.decision_proposal_id) then
          error ~code:"E1504"
            "Audit entry %d Decision names proposal #%s instead of Consented proposal #%s"
            event.entry_index
            (Hash.to_hex event.decision_proposal_id)
            (Hash.to_hex event.proposal_id)
        else
          let* call =
            require_by ~kind:"Call" ~entry_index:event.entry_index event.call_id
              (fun value -> value.call_id)
              calls
          in
          let* proposal =
            require_by ~kind:"Proposal" ~entry_index:event.entry_index event.proposal_id
              (fun value -> value.proposal_id)
              proposals
          in
          if not (Hash.equal proposal.proposal_call_id event.call_id) then
            error ~code:"E1505" "Proposal artifact %d names a different Call than audit entry %d"
              proposal.proposal_index event.entry_index
          else
            let* policy =
              require_by ~kind:"Policy" ~entry_index:event.entry_index proposal.proposal_policy_id
                (fun value -> value.policy_id)
                policies
            in
            let* assessment =
              require_by ~kind:"Assessment" ~entry_index:event.entry_index
                proposal.proposal_assessment_id
                (fun value -> value.assessment_id)
                assessments
            in
            if policy.policy_kind <> Live then
              error ~code:"E1505" "Proposal artifact %d binds a dry policy" proposal.proposal_index
            else if not (Form.equal_ignoring_meta proposal.proposal_authority call.call_authority)
            then
              error ~code:"E1505" "Proposal artifact %d authority disagrees with Call artifact %d"
                proposal.proposal_index call.call_index
            else
              let candidates =
                List.filter
                  (fun evaluation ->
                    (not evaluation.consented)
                    && evaluation.evaluation_verdict = Ask
                    && Hash.equal evaluation.evaluation_call event.call_id
                    && Hash.equal evaluation.evaluation_policy proposal.proposal_policy_id
                    && Hash.equal evaluation.evaluation_assessment proposal.proposal_assessment_id)
                  !evaluations
              in
              match candidates with
              | [ evaluation ] ->
                  evaluation.consented <- true;
                  incr consents;
                  mark used_calls call.call_index;
                  mark used_policies policy.policy_index;
                  mark used_assessments assessment.assessment_index;
                  mark used_proposals proposal.proposal_index;
                  loop rest
              | [] ->
                  error ~code:"E1504"
                    "Audit entry %d has no earlier unconsented Ask evaluation for proposal \
                     artifact %d"
                    event.entry_index proposal.proposal_index
              | _ ->
                  error ~code:"E1504"
                    "Audit entry %d ambiguously matches earlier Ask evaluations at entries %s"
                    event.entry_index
                    (String.concat ","
                       (List.map
                          (fun evaluation -> string_of_int evaluation.evaluation_entry)
                          candidates)))
    | Completed event :: rest ->
        let* call =
          require_by ~kind:"Call" ~entry_index:event.entry_index event.call_id
            (fun value -> value.call_id)
            calls
        in
        if
          not
            (List.exists
               (fun evaluation -> Hash.equal evaluation.evaluation_call event.call_id)
               !evaluations)
        then
          error ~code:"E1504" "Audit entry %d Completed has no earlier Evaluated entry"
            event.entry_index
        else (
          mark used_calls call.call_index;
          loop rest)
  in
  let* () = loop events in
  let unused kind index values used =
    match List.find_opt (fun value -> not (List.mem (index value) !used)) values with
    | None -> Ok ()
    | Some value ->
        error ~code:"E1507" "%s artifact %d is not linked from the Audit chain" kind (index value)
  in
  let* () = unused "Call" (fun value -> value.call_index) calls used_calls in
  let* () = unused "Policy" (fun value -> value.policy_index) policies used_policies in
  let* () =
    unused "Assessment" (fun value -> value.assessment_index) assessments used_assessments
  in
  let* () = unused "Proposal" (fun value -> value.proposal_index) proposals used_proposals in
  Ok !consents

let verify_lineage calls =
  let rec visit origin path call =
    if List.exists (Hash.equal call.call_id) path then
      error ~code:"E1506" "Call artifact %d participates in a parent-call cycle" origin.call_index
    else
      match call.parent_call_id with
      | None -> Ok ()
      | Some parent when Hash.equal parent call.call_id ->
          error ~code:"E1506" "Call artifact %d names itself as parent" call.call_index
      | Some parent -> (
          match find_by parent (fun value -> value.call_id) calls with
          | None ->
              error ~code:"E1506" "Call artifact %d references missing parent Call #%s"
                call.call_index (Hash.to_hex parent)
          | Some parent_call -> visit origin (call.call_id :: path) parent_call)
  in
  let rec loop = function
    | [] -> Ok ()
    | call :: rest ->
        let* () = visit call [] call in
        loop rest
  in
  loop calls

let section expected = function
  | { Form.head; args; _ } when String.equal head expected -> (
      match child_forms args with
      | Some values -> Ok values
      | None -> error ~code:"E1500" "bundle section `%s` contains a scalar entry" expected)
  | _ -> error ~code:"E1500" "bundle is missing fixed section `%s`" expected

let extract_entry index = function
  | {
      Form.head = "audit-chain-v2";
      args = [ Form.Hash _previous; Form.Hash _digest; Form.F entry ];
      _;
    } ->
      Ok entry
  | _ -> error ~code:"E1500" "Audit record %d has a malformed audit-chain-v2 wrapper" index

let verify_form ~store ~file = function
  | {
      Form.head = "governance-run-bundle-v1";
      args =
        [
          Form.F { Form.head = "published-head-v1"; args = [ Form.Hash expected_head ]; _ };
          Form.F records_section;
          Form.F calls_section;
          Form.F policies_section;
          Form.F assessments_section;
          Form.F proposals_section;
        ];
      _;
    } ->
      let* records = section "audit-records-v1" records_section in
      let* call_forms = section "governance-call-artifacts-v1" calls_section in
      let* policy_forms = section "bound-policy-artifacts-v1" policies_section in
      let* assessment_forms = section "governance-assessment-artifacts-v1" assessments_section in
      let* proposal_forms = section "governance-proposal-artifacts-v1" proposals_section in
      let log =
        match records with
        | [] -> ""
        | _ -> String.concat "\n" (List.map Printer.print_compact records) ^ "\n"
      in
      let* head = Audit_chain.verify_string ~file:(file ^ ":audit") ~expected_head log in
      let* entries = parse_indexed extract_entry records in
      let* events = parse_indexed parse_event entries in
      let* calls = parse_indexed (parse_call ~store) call_forms in
      let* policies = parse_indexed parse_policy policy_forms in
      let* assessments = parse_indexed parse_assessment assessment_forms in
      let* proposals = parse_indexed parse_proposal proposal_forms in
      let* () =
        validate_unique ~kind:"Call"
          ~identity:(fun value -> value.call_id)
          ~index:(fun value -> value.call_index)
          calls
      in
      let* () =
        validate_unique ~kind:"Policy"
          ~identity:(fun value -> value.policy_id)
          ~index:(fun value -> value.policy_index)
          policies
      in
      let* () =
        validate_unique ~kind:"Assessment"
          ~identity:(fun value -> value.assessment_id)
          ~index:(fun value -> value.assessment_index)
          assessments
      in
      let* () =
        validate_unique ~kind:"Proposal"
          ~identity:(fun value -> value.proposal_id)
          ~index:(fun value -> value.proposal_index)
          proposals
      in
      let* () = verify_lineage calls in
      let* consents = verify_links calls policies assessments proposals events in
      Ok
        {
          head;
          entries = List.length entries;
          calls = List.length calls;
          policies = List.length policies;
          assessments = List.length assessments;
          proposals = List.length proposals;
          consents;
          transformed_calls =
            List.fold_left
              (fun count call -> count + if Option.is_some call.parent_call_id then 1 else 0)
              0 calls;
        }
  | { Form.head; _ } when not (String.equal head "governance-run-bundle-v1") ->
      error ~code:"E1500" "unsupported governance run bundle version `%s`" head
  | _ -> error ~code:"E1500" "malformed governance-run-bundle-v1"

let verify_string ~store ~file source =
  let length = String.length source in
  if length = 0 || source.[length - 1] <> '\n' then
    error ~code:"E1500" "%s: governance run bundle must end with LF" file
  else
    let body = String.sub source 0 (length - 1) in
    if String.equal body "" || String.contains body '\n' || String.contains body '\r' then
      error ~code:"E1500" "%s: governance run bundle must be one canonical compact line" file
    else
      match Reader.parse_one ~file body with
      | Error diagnostics ->
          let detail =
            match diagnostics with
            | diagnostic :: _ -> diagnostic.Diag.message
            | [] -> "unknown reader failure"
          in
          error ~code:"E1500" "%s: malformed governance run bundle: %s" file detail
      | Ok form when not (String.equal (Printer.print_compact form) body) ->
          error ~code:"E1500" "%s: governance run bundle is not canonical" file
      | Ok form -> verify_form ~store ~file form

let max_bundle_bytes = 16 * 1024 * 1024

let changed before after =
  before.Unix.st_dev <> after.Unix.st_dev
  || before.st_ino <> after.st_ino || before.st_kind <> after.st_kind
  || before.st_size <> after.st_size || before.st_mtime <> after.st_mtime
  || before.st_ctime <> after.st_ctime

let io_exception = function
  | Sys_error message -> Some message
  | Unix.Unix_error (code, operation, path) ->
      Some
        (if String.equal path "" then Printf.sprintf "%s: %s" operation (Unix.error_message code)
         else Printf.sprintf "%s: %s" path (Unix.error_message code))
  | End_of_file -> Some "unexpected end of file"
  | _ -> None

let read_file file =
  match
    try
      let descriptor = Unix.openfile file [ Unix.O_RDONLY ] 0 in
      Fun.protect
        ~finally:(fun () -> Unix.close descriptor)
        (fun () ->
          let before = Unix.fstat descriptor in
          if before.st_kind <> Unix.S_REG then Error "is not a regular file"
          else if before.st_size > max_bundle_bytes then
            Error (Printf.sprintf "exceeds the %d-byte limit" max_bundle_bytes)
          else
            let buffer = Buffer.create before.st_size in
            let chunk = Bytes.create 65536 in
            let rec loop total =
              match Unix.read descriptor chunk 0 (Bytes.length chunk) with
              | 0 -> total
              | count ->
                  if total + count > max_bundle_bytes then
                    raise (Sys_error "bundle grew past limit")
                  else (
                    Buffer.add_subbytes buffer chunk 0 count;
                    loop (total + count))
            in
            let total = loop 0 in
            let after = Unix.fstat descriptor in
            let path_after = Unix.stat file in
            if changed before after || changed after path_after || total <> before.st_size then
              Error "changed while it was being read"
            else Ok (Buffer.contents buffer))
    with exception_ -> (
      match io_exception exception_ with Some message -> Error message | None -> raise exception_)
  with
  | Ok bytes -> Ok bytes
  | Error message -> error ~code:"E1500" "cannot read governance run bundle %s: %s" file message

let verify_file ~store ~file =
  let* source = read_file file in
  verify_string ~store ~file source
