(** See {!Posterior_risk_verify}. *)

type replay_artifacts = {
  model_ref : Value.t;
  config : Value.t;
  source_evidence : Value.t;
  call : Value.t;
  baseline : Value.t;
  rule : Value.t;
}

type verdict = Allow | Ask | Block

type report = {
  governance : Governance_run_bundle.report;
  entry_index : int;
  call_id : Hash.t;
  policy_id : Hash.t;
  posterior_id : Hash.t;
  projection_id : Hash.t;
  assessment_id : Hash.t;
  verdict : verdict;
}

let ( let* ) = Result.bind

let diagnostic_spec = function
  | "E1548" ->
      ( "The posterior replay target is missing, ambiguous, or unsupported.",
        "Provide one v0-verified bundle with exactly one Evaluated entry for the replayed Call and \
         a live policy." )
  | "E1549" ->
      ( "Exact posterior replay disagrees with the committed governance decision.",
        "Restore the exact model, handler configuration, source evidence, baseline, projection \
         rule, assessment, and verdict used to produce the bundle." )
  | code -> raise (Diag.Bug_invalid_diagnostic ("unknown posterior verifier code " ^ code))

let error ~code fmt =
  Printf.ksprintf
    (fun cause ->
      let summary, next_step = diagnostic_spec code in
      Error [ Diag.error ~domain:Governance ~code ~summary ~cause ~next_step ~contrast:None () ])
    fmt

let hash_value = function
  | { Form.head = "hash"; args = [ Form.Hash value ]; _ } -> Some value
  | _ -> None

let real_value = function
  | { Form.head = "lit"; args = [ Form.Real value ]; _ } -> Some value
  | _ -> None

let risk_rank = function
  | { Form.head = "low"; args = []; _ } -> Some 0
  | { Form.head = "medium"; args = []; _ } -> Some 1
  | { Form.head = "high"; args = []; _ } -> Some 2
  | { Form.head = "forbidden"; args = []; _ } -> Some 3
  | _ -> None

type committed_verdict = Live_verdict of verdict | Simulate

let parse_verdict = function
  | { Form.head = "allow"; args = []; _ } -> Some (Live_verdict Allow)
  | { Form.head = "simulate"; args = []; _ } -> Some Simulate
  | { Form.head = "ask"; args = []; _ } -> Some (Live_verdict Ask)
  | { Form.head = "block"; args = []; _ } -> Some (Live_verdict Block)
  | _ -> None

type evaluated = {
  entry_index : int;
  call_id : Hash.t;
  policy_id : Hash.t;
  assessment : Form.t;
  verdict : committed_verdict;
}

let evaluated_of_record entry_index = function
  | {
      Form.head = "audit-chain-v2";
      args =
        [
          Form.Hash _previous;
          Form.Hash _digest;
          Form.F
            {
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
            };
        ];
      _;
    } -> (
      match (hash_value call, hash_value policy, parse_verdict verdict) with
      | Some call_id, Some policy_id, Some verdict ->
          Ok (Some { entry_index; call_id; policy_id; assessment; verdict })
      | _ -> error ~code:"E1548" "Evaluated entry %d has malformed replay linkage" entry_index)
  | {
      Form.head = "audit-chain-v2";
      args = [ Form.Hash _previous; Form.Hash _digest; Form.F _entry ];
      _;
    } ->
      Ok None
  | _ -> error ~code:"E1548" "Audit record %d is malformed after v0 verification" entry_index

let child_forms = function
  | { Form.args; _ } ->
      let rec loop reversed = function
        | [] -> Ok (List.rev reversed)
        | Form.F value :: rest -> loop (value :: reversed) rest
        | _ -> error ~code:"E1548" "a verified bundle section contains a scalar artifact"
      in
      loop [] args

let extract_sections = function
  | {
      Form.head = "governance-run-bundle-v1";
      args =
        [
          Form.F _head;
          Form.F ({ Form.head = "audit-records-v1"; _ } as records);
          Form.F _calls;
          Form.F ({ Form.head = "bound-policy-artifacts-v1"; _ } as policies);
          Form.F _assessments;
          Form.F _proposals;
        ];
      _;
    } ->
      let* records = child_forms records in
      let* policies = child_forms policies in
      Ok (records, policies)
  | _ -> error ~code:"E1548" "bundle shape changed after v0 verification"

let find_evaluated call_id records =
  let rec loop index matches = function
    | [] -> (
        match matches with
        | [ target ] -> Ok target
        | [] ->
            error ~code:"E1548" "no Evaluated entry names replayed Call #%s" (Hash.to_hex call_id)
        | _ ->
            error ~code:"E1548" "multiple Evaluated entries name replayed Call #%s"
              (Hash.to_hex call_id))
    | record :: rest ->
        let* candidate = evaluated_of_record index record in
        let matches =
          match candidate with
          | Some event when Hash.equal event.call_id call_id -> event :: matches
          | Some _ | None -> matches
        in
        loop (index + 1) matches rest
  in
  loop 0 [] records

type live_policy = { auto_up_to : int; ask_up_to : int; min_confidence : float }

let policy_of_artifact target_id = function
  | {
      Form.head = "bound-policy-artifact-v1";
      args =
        [
          Form.F _version;
          Form.F carried;
          Form.F
            {
              Form.head = "live-policy-v0";
              args = [ Form.F _policy_version; Form.F auto; Form.F ask; Form.F confidence ];
              _;
            };
        ];
      _;
    } -> (
      match (hash_value carried, risk_rank auto, risk_rank ask, real_value confidence) with
      | Some policy_id, Some auto_up_to, Some ask_up_to, Some min_confidence
        when Hash.equal target_id policy_id ->
          Ok (Some { auto_up_to; ask_up_to; min_confidence })
      | Some policy_id, _, _, _ when not (Hash.equal target_id policy_id) -> Ok None
      | _ -> error ~code:"E1548" "linked live policy is malformed after v0 verification")
  | {
      Form.head = "bound-policy-artifact-v1";
      args = [ Form.F _version; Form.F carried; Form.F { Form.head = "dry-policy-v0"; _ } ];
      _;
    } -> (
      match hash_value carried with
      | Some policy_id when Hash.equal target_id policy_id ->
          error ~code:"E1548"
            "Evaluated policy #%s is dry; simulator availability is not bound by the run bundle"
            (Hash.to_hex target_id)
      | Some _ -> Ok None
      | None -> error ~code:"E1548" "linked dry policy is malformed after v0 verification")
  | _ -> Ok None

let find_live_policy policy_id policies =
  let rec loop matches = function
    | [] -> (
        match matches with
        | [ policy ] -> Ok policy
        | [] ->
            error ~code:"E1548" "Evaluated policy #%s is absent after v0 verification"
              (Hash.to_hex policy_id)
        | _ ->
            error ~code:"E1548" "Evaluated policy #%s is ambiguous after v0 verification"
              (Hash.to_hex policy_id))
    | artifact :: rest ->
        let* candidate = policy_of_artifact policy_id artifact in
        loop (match candidate with Some policy -> policy :: matches | None -> matches) rest
  in
  loop [] policies

let assessment_fields = function
  | {
      Form.head = "governance-assessment-v0";
      args = [ Form.F _version; Form.F risk; Form.F confidence; Form.F _reasons; Form.F _evidence ];
      _;
    } -> (
      match (risk_rank risk, real_value confidence) with
      | Some risk, Some confidence -> Ok (risk, confidence)
      | _ -> error ~code:"E1548" "committed assessment is malformed after v0 verification")
  | _ -> error ~code:"E1548" "committed assessment is malformed after v0 verification"

let live_verdict policy risk confidence =
  if risk = 3 then Block
  else if confidence >= policy.min_confidence then
    if risk <= policy.auto_up_to then Allow else if risk <= policy.ask_up_to then Ask else Block
  else if risk <= policy.ask_up_to then Ask
  else Block

let verdict_name = function
  | Live_verdict Allow -> "Allow"
  | Simulate -> "Simulate"
  | Live_verdict Ask -> "Ask"
  | Live_verdict Block -> "Block"

let verify_form ~ctx ~builtin_signatures ~file ~replay bundle =
  let store = Eval.store ctx in
  let* governance = Governance_run_bundle.verify_form ~store ~file bundle in
  let replayed =
    Posterior_risk.replay_exact ctx ~builtin_signatures ~model_ref:replay.model_ref
      ~config:replay.config ~source_evidence:replay.source_evidence ~call:replay.call
      ~baseline:replay.baseline ~rule:replay.rule
  in
  let* replayed =
    match replayed with
    | Ok replayed -> Ok replayed
    | Error cause -> error ~code:"E1549" "exact posterior replay failed: %s" cause
  in
  let* records, policies = extract_sections bundle in
  let* evaluated = find_evaluated replayed.call_id records in
  let committed_bytes = Printer.print_compact evaluated.assessment in
  let replayed_bytes = Printer.print_compact replayed.assessment_code in
  let* () =
    if String.equal committed_bytes replayed_bytes then Ok ()
    else
      error ~code:"E1549"
        "Evaluated entry %d assessment differs from exact replay (committed #%s, replayed #%s)"
        evaluated.entry_index
        (Hash.to_hex (Hash.of_string committed_bytes))
        (Hash.to_hex replayed.assessment_id)
  in
  let* policy = find_live_policy evaluated.policy_id policies in
  let* risk, confidence = assessment_fields evaluated.assessment in
  let expected_verdict = live_verdict policy risk confidence in
  let* () =
    if Live_verdict expected_verdict = evaluated.verdict then Ok ()
    else
      error ~code:"E1549"
        "Evaluated entry %d commits %s but unchanged Governance v0 live policy recomputes %s"
        evaluated.entry_index (verdict_name evaluated.verdict)
        (verdict_name (Live_verdict expected_verdict))
  in
  Ok
    {
      governance;
      entry_index = evaluated.entry_index;
      call_id = replayed.call_id;
      policy_id = evaluated.policy_id;
      posterior_id = replayed.posterior_id;
      projection_id = replayed.projection_id;
      assessment_id = replayed.assessment_id;
      verdict = expected_verdict;
    }
