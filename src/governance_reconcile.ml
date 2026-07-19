type report = {
  audit_head : Hash.t;
  journal_head : Hash.t;
  no_action_legal : int;
  authorized_not_observed : int;
  attempt_outcome_unknown : int;
  receipt_pending_completion : int;
  reconciled_completed : int;
  completion_without_receipt : int;
}

let ( let* ) = Result.bind
let error ~code fmt = Printf.ksprintf (fun message -> Error [ Diag.error ~code message ]) fmt
let journal_domain = "jacquard-governance-action-journal-v1\000"
let journal_genesis = Hash.of_string "jacquard-governance-action-journal-v1-genesis\000"
let form head values = Form.form head (List.map (fun value -> Form.F value) values)
let hash_form value = Form.form "hash" [ Form.Hash value ]
let lit value = Form.form "lit" [ Form.Text value ]

let hash_value = function
  | { Form.head = "hash"; args = [ Form.Hash value ]; _ } -> Some value
  | _ -> None

let text_value = function
  | { Form.head = "lit"; args = [ Form.Text value ]; _ } -> Some value
  | _ -> None

let int_value = function
  | { Form.head = "lit"; args = [ Form.Int value ]; _ } -> Some value
  | _ -> None

let compact value = Printer.print_compact value
let semantic_hash value = Hash.of_string (compact value)

let attempt_subject ~call_id ~authorization ~branch ~driver_id ~idempotency_key_digest =
  form "governance-action-attempt-subject-v1"
    [
      hash_form call_id;
      hash_form authorization;
      lit branch;
      hash_form driver_id;
      hash_form idempotency_key_digest;
    ]

let attempt_id ~call_id ~authorization ~branch ~driver_id ~idempotency_key_digest =
  semantic_hash (attempt_subject ~call_id ~authorization ~branch ~driver_id ~idempotency_key_digest)

let receipt_subject ~attempt_id ~outcome ~external_receipt_digest =
  form "governance-action-receipt-subject-v1"
    [ hash_form attempt_id; outcome; hash_form external_receipt_digest ]

let receipt_id ~attempt_id ~outcome ~external_receipt_digest =
  semantic_hash (receipt_subject ~attempt_id ~outcome ~external_receipt_digest)

type attempted = {
  sequence : int;
  attempt_id : Hash.t;
  call_id : Hash.t;
  authorization : Hash.t;
  branch : string;
}

type receipt = { sequence : int; receipt_id : Hash.t; attempt_id : Hash.t; outcome_bytes : string }
type journal_entry = Attempted of attempted | Receipt of receipt
type dry_completion = { allowed_branches : string list; mutable completed : bool }

let parse_outcome = function
  | {
      Form.head = "governance-outcome-summary-v0";
      args =
        [
          Form.F { Form.head = "governance-v0"; args = []; _ };
          Form.F { Form.head = "lit"; args = [ Form.Text _ ]; _ };
          Form.F { Form.head = "hash"; args = [ Form.Hash _ ]; _ };
          Form.F { Form.head = "lit"; args = [ Form.Text _ ]; _ };
        ];
      _;
    } as outcome ->
      Some outcome
  | _ -> None

let parse_journal_entry ~index = function
  | {
      Form.head = "action-attempted-v1";
      args =
        [
          Form.F sequence;
          Form.F carried;
          Form.F call;
          Form.F authorization;
          Form.F branch;
          Form.F driver;
          Form.F key;
        ];
      _;
    } -> (
      match
        ( int_value sequence,
          hash_value carried,
          hash_value call,
          hash_value authorization,
          text_value branch,
          hash_value driver,
          hash_value key )
      with
      | ( Some sequence,
          Some carried,
          Some call_id,
          Some authorization,
          Some branch,
          Some driver_id,
          Some idempotency_key_digest )
        when sequence >= 0 && not (String.equal branch "") ->
          let computed =
            attempt_id ~call_id ~authorization ~branch ~driver_id ~idempotency_key_digest
          in
          if not (Hash.equal carried computed) then
            error ~code:"E1512"
              "action journal entry %d carries attempt #%s but its semantic subject hashes to #%s"
              index (Hash.to_hex carried) (Hash.to_hex computed)
          else Ok (Attempted { sequence; attempt_id = carried; call_id; authorization; branch })
      | _ -> error ~code:"E1510" "action journal entry %d is not a valid action-attempted-v1" index)
  | {
      Form.head = "action-receipt-v1";
      args =
        [ Form.F sequence; Form.F carried; Form.F attempt; Form.F outcome; Form.F external_receipt ];
      _;
    } -> (
      match
        ( int_value sequence,
          hash_value carried,
          hash_value attempt,
          parse_outcome outcome,
          hash_value external_receipt )
      with
      | Some sequence, Some carried, Some attempt_id, Some outcome, Some external_receipt_digest
        when sequence >= 0 ->
          let computed = receipt_id ~attempt_id ~outcome ~external_receipt_digest in
          if not (Hash.equal carried computed) then
            error ~code:"E1512"
              "action journal entry %d carries receipt #%s but its semantic subject hashes to #%s"
              index (Hash.to_hex carried) (Hash.to_hex computed)
          else
            Ok
              (Receipt
                 { sequence; receipt_id = carried; attempt_id; outcome_bytes = compact outcome })
      | _ -> error ~code:"E1510" "action journal entry %d is not a valid action-receipt-v1" index)
  | _ -> error ~code:"E1510" "action journal entry %d has an unsupported entry version" index

let entry_sequence = function Attempted value -> value.sequence | Receipt value -> value.sequence

let append_journal ~previous ~entry =
  let* _ = parse_journal_entry ~index:0 entry in
  let digest = Hash.of_string (journal_domain ^ Hash.to_raw previous ^ compact entry) in
  Ok
    ( Form.form "governance-action-chain-v1" [ Form.Hash previous; Form.Hash digest; Form.F entry ],
      digest )

module Hash_table = Hashtbl.Make (struct
  type t = Hash.t

  let equal = Hash.equal
  let hash value = Hashtbl.hash (Hash.to_raw value)
end)

module Triple_table = Hashtbl.Make (struct
  type t = Hash.t * Hash.t * Hash.t

  let equal (ac, ap, aa) (bc, bp, ba) = Hash.equal ac bc && Hash.equal ap bp && Hash.equal aa ba

  let hash (call, policy, assessment) =
    Hashtbl.hash (Hash.to_raw call, Hash.to_raw policy, Hash.to_raw assessment)
end)

type audit_record = { index : int; digest : Hash.t; entry : Form.t }
type ask = { mutable consumed : bool }
type authorization = { auth_call : Hash.t; auth_index : int; mutable attempted : bool }

type completion = {
  completion_index : int;
  call_id : Hash.t;
  outcome_bytes : string;
  mutable used : bool;
}

type policy_kind = Live | Dry

let child_forms args =
  let rec loop reversed = function
    | [] -> Some (List.rev reversed)
    | Form.F value :: rest -> loop (value :: reversed) rest
    | _ -> None
  in
  loop [] args

let extract_run = function
  | {
      Form.head = "governance-run-bundle-v1";
      args =
        [
          Form.F _published;
          Form.F { Form.head = "audit-records-v1"; args = record_args; _ };
          Form.F _calls;
          Form.F { Form.head = "bound-policy-artifacts-v1"; args = policy_args; _ };
          Form.F _assessments;
          Form.F { Form.head = "governance-proposal-artifacts-v1"; args = proposal_args; _ };
        ];
      _;
    } -> (
      match (child_forms record_args, child_forms policy_args, child_forms proposal_args) with
      | Some record_forms, Some policies, Some proposals ->
          let parse_record index = function
            | {
                Form.head = "audit-chain-v2";
                args = [ Form.Hash _; Form.Hash digest; Form.F entry ];
                _;
              } ->
                Ok { index; digest; entry }
            | _ -> error ~code:"E1510" "verified run bundle record %d is malformed" index
          in
          let rec records index reversed = function
            | [] -> Ok (List.rev reversed, policies, proposals)
            | value :: rest ->
                let* parsed = parse_record index value in
                records (index + 1) (parsed :: reversed) rest
          in
          records 0 [] record_forms
      | _ -> error ~code:"E1510" "verified run bundle sections are malformed")
  | _ -> error ~code:"E1510" "reconciliation package does not embed a run bundle"

let proposal_index proposals =
  let table = Hash_table.create (max 16 (List.length proposals)) in
  let rec loop index = function
    | [] -> Ok table
    | {
        Form.head = "governance-proposal-artifact-v1";
        args =
          [
            Form.F _version;
            Form.F proposal;
            Form.F call;
            Form.F policy;
            Form.F assessment;
            Form.F _rendering;
            Form.F _summary;
            Form.F _authority;
            Form.F _preview;
          ];
        _;
      }
      :: rest -> (
        match (hash_value proposal, hash_value call, hash_value policy, hash_value assessment) with
        | Some proposal, Some call, Some policy, Some assessment ->
            Hash_table.replace table proposal (call, policy, assessment);
            loop (index + 1) rest
        | _ -> error ~code:"E1510" "verified Proposal artifact %d is malformed" index)
    | _ :: _ -> error ~code:"E1510" "verified Proposal artifact %d is malformed" index
  in
  loop 0 proposals

let policy_index policies =
  let table = Hash_table.create (max 16 (List.length policies)) in
  let rec loop index = function
    | [] -> Ok table
    | {
        Form.head = "bound-policy-artifact-v1";
        args = [ Form.F _version; Form.F policy; Form.F value ];
        _;
      }
      :: rest -> (
        match (hash_value policy, value.Form.head) with
        | Some policy, "live-policy-v0" ->
            Hash_table.replace table policy Live;
            loop (index + 1) rest
        | Some policy, "dry-policy-v0" ->
            Hash_table.replace table policy Dry;
            loop (index + 1) rest
        | _ -> error ~code:"E1510" "verified Policy artifact %d is malformed" index)
    | _ :: _ -> error ~code:"E1510" "verified Policy artifact %d is malformed" index
  in
  loop 0 policies

let audit_evidence records policies proposals =
  let* policy_by_id = policy_index policies in
  let* proposal_by_id = proposal_index proposals in
  let asks = Triple_table.create 16 in
  let evaluation_by_call = Hash_table.create 16 in
  let authorizations = Hash_table.create 16 in
  let authorization_by_call = Hash_table.create 16 in
  let dry_completions = Hash_table.create 16 in
  let no_action = ref 0 in
  let completions = ref [] in
  let add_ask tuple =
    let current = Option.value ~default:[] (Triple_table.find_opt asks tuple) in
    Triple_table.replace asks tuple ({ consumed = false } :: current)
  in
  let consume_ask tuple =
    match Triple_table.find_opt asks tuple with
    | Some values -> (
        match List.find_opt (fun value -> not value.consumed) values with
        | Some value -> value.consumed <- true
        | None -> ())
    | None -> ()
  in
  let add_evaluation record call =
    match Hash_table.find_opt evaluation_by_call call with
    | Some earlier ->
        error ~code:"E1515"
          "Call #%s has evaluations at Audit records %d and %d; v1 cannot identify a unique \
           occurrence"
          (Hash.to_hex call) earlier record.index
    | None ->
        Hash_table.add evaluation_by_call call record.index;
        Ok ()
  in
  let add_authorization record call =
    match Hash_table.find_opt authorization_by_call call with
    | Some earlier ->
        error ~code:"E1515"
          "Call #%s has executable authorizations at Audit records %d and %d; v1 cannot identify a \
           unique occurrence"
          (Hash.to_hex call) earlier.auth_index record.index
    | None ->
        let authorization = { auth_call = call; auth_index = record.index; attempted = false } in
        Hash_table.add authorizations record.digest authorization;
        Hash_table.add authorization_by_call call authorization;
        Ok ()
  in
  let add_dry_completion call allowed_branches =
    Hash_table.replace dry_completions call { allowed_branches; completed = false }
  in
  let consume_dry_completion call branch =
    match Hash_table.find_opt dry_completions call with
    | Some evidence
      when (not evidence.completed) && List.exists (String.equal branch) evidence.allowed_branches
      ->
        evidence.completed <- true;
        Ok ()
    | Some { completed = true; _ } ->
        error ~code:"E1515" "Call #%s has more than one dry completion" (Hash.to_hex call)
    | _ ->
        error ~code:"E1515"
          "Call #%s has completion branch `%s` without a compatible earlier dry evaluation"
          (Hash.to_hex call) branch
  in
  let scan record =
    match record.entry with
    | {
     Form.head = "audit-entry-v2";
     args =
       [
         Form.F
           {
             Form.head = "evaluated-v2";
             args =
               [ Form.F _; Form.F _; Form.F call; Form.F policy; Form.F assessment; Form.F verdict ];
             _;
           };
       ];
     _;
    } -> (
        match (hash_value call, hash_value policy, child_forms verdict.args) with
        | Some call, Some policy, Some [] -> (
            let* () = add_evaluation record call in
            let assessment_id = semantic_hash assessment in
            match Hash_table.find_opt policy_by_id policy with
            | None -> error ~code:"E1510" "verified Evaluated record names a missing Policy"
            | Some Live when String.equal verdict.head "allow" -> add_authorization record call
            | Some Live when String.equal verdict.head "ask" ->
                add_ask (call, policy, assessment_id);
                Ok ()
            | Some Dry when String.equal verdict.head "simulate" ->
                add_dry_completion call [ "no-simulation"; "simulated"; "simulation-failed" ];
                incr no_action;
                Ok ()
            | Some Dry when String.equal verdict.head "block" ->
                add_dry_completion call [ "blocked" ];
                incr no_action;
                Ok ()
            | Some Live when String.equal verdict.head "block" ->
                incr no_action;
                Ok ()
            | Some Live ->
                error ~code:"E1515" "live Policy evaluation has incompatible verdict `%s`"
                  verdict.head
            | Some Dry ->
                error ~code:"E1515" "dry Policy evaluation has incompatible verdict `%s`"
                  verdict.head)
        | _ -> Ok ())
    | {
     Form.head = "audit-entry-v2";
     args =
       [
         Form.F
           {
             Form.head = "consented-v2";
             args = [ Form.F _; Form.F _; Form.F call; Form.F proposal; Form.F decision ];
             _;
           };
       ];
     _;
    } -> (
        match (hash_value call, hash_value proposal) with
        | Some call, Some proposal ->
            Option.iter consume_ask (Hash_table.find_opt proposal_by_id proposal);
            if String.equal decision.head "approved-v1" then add_authorization record call
            else (
              incr no_action;
              Ok ())
        | _ -> Ok ())
    | {
     Form.head = "audit-entry-v2";
     args =
       [
         Form.F
           {
             Form.head = "completed-v2";
             args = [ Form.F _; Form.F _; Form.F call; Form.F branch; Form.F outcome ];
             _;
           };
       ];
     _;
    } -> (
        match (hash_value call, text_value branch) with
        | Some call_id, Some branch when String.equal branch "live" ->
            completions :=
              {
                completion_index = record.index;
                call_id;
                outcome_bytes = compact outcome;
                used = false;
              }
              :: !completions;
            Ok ()
        | Some call_id, Some branch -> consume_dry_completion call_id branch
        | _ -> Ok ())
    | _ -> Ok ()
  in
  let rec scan_records = function
    | [] -> Ok ()
    | record :: rest ->
        let* () = scan record in
        scan_records rest
  in
  let* () = scan_records records in
  Triple_table.iter
    (fun _ values -> List.iter (fun value -> if not value.consumed then incr no_action) values)
    asks;
  Ok (authorizations, authorization_by_call, List.rev !completions, !no_action)

let verify_journal ~expected_head records =
  let attempts = Hash_table.create 16 in
  let receipts = Hash_table.create 16 in
  let rec loop index previous reversed_attempts = function
    | [] ->
        if Hash.equal previous expected_head then Ok (List.rev reversed_attempts, receipts)
        else
          error ~code:"E1511" "published action-journal head is #%s but reconstructed head is #%s"
            (Hash.to_hex expected_head) (Hash.to_hex previous)
    | {
        Form.head = "governance-action-chain-v1";
        args = [ Form.Hash carried_previous; Form.Hash carried_digest; Form.F entry ];
        _;
      }
      :: rest -> (
        if not (Hash.equal carried_previous previous) then
          error ~code:"E1511" "action journal record %d has a broken predecessor" index
        else
          let computed = Hash.of_string (journal_domain ^ Hash.to_raw previous ^ compact entry) in
          if not (Hash.equal computed carried_digest) then
            error ~code:"E1511" "action journal record %d has a mismatched digest" index
          else
            let* parsed = parse_journal_entry ~index entry in
            if entry_sequence parsed <> index then
              error ~code:"E1511" "action journal record %d has sequence %d" index
                (entry_sequence parsed)
            else
              match parsed with
              | Attempted value when Hash_table.mem attempts value.attempt_id ->
                  error ~code:"E1513" "action journal record %d duplicates attempt #%s" index
                    (Hash.to_hex value.attempt_id)
              | Attempted value ->
                  Hash_table.add attempts value.attempt_id value;
                  loop (index + 1) computed (value :: reversed_attempts) rest
              | Receipt value when Hash_table.mem receipts value.attempt_id ->
                  error ~code:"E1513" "action journal record %d repeats a receipt for attempt #%s"
                    index (Hash.to_hex value.attempt_id)
              | Receipt value when not (Hash_table.mem attempts value.attempt_id) ->
                  error ~code:"E1514" "action journal record %d precedes its attempt #%s" index
                    (Hash.to_hex value.attempt_id)
              | Receipt value ->
                  Hash_table.add receipts value.attempt_id value;
                  loop (index + 1) computed reversed_attempts rest)
    | _ :: _ -> error ~code:"E1510" "action journal record %d is malformed" index
  in
  loop 0 journal_genesis [] records

let reconcile authorizations authorization_by_call completions no_action attempts receipts
    audit_head journal_head =
  let attempt_outcome_unknown = ref 0 in
  let receipt_pending_completion = ref 0 in
  let reconciled_completed = ref 0 in
  let completion_without_receipt = ref 0 in
  let completion_by_call = Hash_table.create (max 16 (List.length completions)) in
  let rec index_completions = function
    | [] -> Ok ()
    | completion :: rest -> (
        match Hash_table.find_opt authorization_by_call completion.call_id with
        | None ->
            error ~code:"E1515" "Call #%s has a live completion without executable authorization"
              (Hash.to_hex completion.call_id)
        | Some authorization when authorization.auth_index >= completion.completion_index ->
            error ~code:"E1515" "Call #%s has a live completion before its executable authorization"
              (Hash.to_hex completion.call_id)
        | Some _ when Hash_table.mem completion_by_call completion.call_id ->
            error ~code:"E1515"
              "Call #%s has more than one live completion; v1 cannot identify a unique occurrence"
              (Hash.to_hex completion.call_id)
        | Some _ ->
            Hash_table.add completion_by_call completion.call_id completion;
            index_completions rest)
  in
  let* () = index_completions completions in
  let rec check_attempts = function
    | [] -> Ok ()
    | (attempt : attempted) :: rest -> (
        if not (String.equal attempt.branch "live") then
          error ~code:"E1515" "attempt #%s selects non-executable branch `%s`"
            (Hash.to_hex attempt.attempt_id) attempt.branch
        else
          match Hash_table.find_opt authorizations attempt.authorization with
          | None ->
              error ~code:"E1515" "attempt #%s does not name a live Allow or Approved authorization"
                (Hash.to_hex attempt.attempt_id)
          | Some authorization when not (Hash.equal authorization.auth_call attempt.call_id) ->
              error ~code:"E1515" "attempt #%s names the wrong Call"
                (Hash.to_hex attempt.attempt_id)
          | Some authorization when authorization.attempted ->
              error ~code:"E1515" "authorization #%s has more than one attempt"
                (Hash.to_hex attempt.authorization)
          | Some authorization -> (
              authorization.attempted <- true;
              let completion = Hash_table.find_opt completion_by_call attempt.call_id in
              match Hash_table.find_opt receipts attempt.attempt_id with
              | None -> (
                  match completion with
                  | None ->
                      incr attempt_outcome_unknown;
                      check_attempts rest
                  | Some completion when completion.used ->
                      error ~code:"E1515" "attempt #%s reuses an Audit completion"
                        (Hash.to_hex attempt.attempt_id)
                  | Some completion ->
                      completion.used <- true;
                      incr completion_without_receipt;
                      check_attempts rest)
              | Some (receipt : receipt) -> (
                  match completion with
                  | None ->
                      incr receipt_pending_completion;
                      check_attempts rest
                  | Some completion
                    when not (String.equal completion.outcome_bytes receipt.outcome_bytes) ->
                      error ~code:"E1515" "receipt #%s disagrees with the Audit completion outcome"
                        (Hash.to_hex receipt.receipt_id)
                  | Some completion ->
                      if completion.used then
                        error ~code:"E1515" "receipt #%s reuses an Audit completion"
                          (Hash.to_hex receipt.receipt_id)
                      else (
                        completion.used <- true;
                        incr reconciled_completed;
                        check_attempts rest))))
  in
  let* () = check_attempts attempts in
  List.iter
    (fun completion ->
      if not completion.used then (
        completion.used <- true;
        incr completion_without_receipt))
    completions;
  let authorized_not_observed = ref 0 in
  Hash_table.iter
    (fun _ authorization -> if not authorization.attempted then incr authorized_not_observed)
    authorizations;
  Ok
    {
      audit_head;
      journal_head;
      no_action_legal = no_action;
      authorized_not_observed = !authorized_not_observed;
      attempt_outcome_unknown = !attempt_outcome_unknown;
      receipt_pending_completion = !receipt_pending_completion;
      reconciled_completed = !reconciled_completed;
      completion_without_receipt = !completion_without_receipt;
    }

let verify_form ~store ~file = function
  | {
      Form.head = "governance-reconciliation-bundle-v1";
      args =
        [
          Form.F run_bundle;
          Form.F
            { Form.head = "published-action-journal-head-v1"; args = [ Form.Hash journal_head ]; _ };
          Form.F { Form.head = "governance-action-journal-v1"; args = journal_args; _ };
        ];
      _;
    } ->
      let* run_report = Governance_run_bundle.verify_form ~store ~file run_bundle in
      let* records, policies, proposals = extract_run run_bundle in
      let* authorizations, authorization_by_call, completions, no_action =
        audit_evidence records policies proposals
      in
      let* journal_records =
        match child_forms journal_args with
        | Some values -> Ok values
        | None -> error ~code:"E1510" "governance-action-journal-v1 contains a scalar record"
      in
      let* attempts, receipts = verify_journal ~expected_head:journal_head journal_records in
      reconcile authorizations authorization_by_call completions no_action attempts receipts
        run_report.head journal_head
  | { Form.head; _ } when not (String.equal head "governance-reconciliation-bundle-v1") ->
      error ~code:"E1510" "unsupported governance reconciliation bundle version `%s`" head
  | _ -> error ~code:"E1510" "malformed governance-reconciliation-bundle-v1"

let verify_string ~store ~file source =
  let length = String.length source in
  if length = 0 || source.[length - 1] <> '\n' then
    error ~code:"E1510" "%s: governance reconciliation bundle must end with LF" file
  else
    let body = String.sub source 0 (length - 1) in
    if String.equal body "" || String.contains body '\n' || String.contains body '\r' then
      error ~code:"E1510" "%s: governance reconciliation bundle must be one canonical compact line"
        file
    else
      match Reader.parse_one ~file body with
      | Error diagnostics ->
          let detail =
            match diagnostics with
            | diagnostic :: _ -> diagnostic.Diag.message
            | [] -> "unknown reader failure"
          in
          error ~code:"E1510" "%s: malformed governance reconciliation bundle: %s" file detail
      | Ok form when not (String.equal (compact form) body) ->
          error ~code:"E1510" "%s: governance reconciliation bundle is not canonical" file
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
      let descriptor = Unix.openfile file [ Unix.O_RDONLY; Unix.O_NONBLOCK ] 0 in
      Fun.protect
        ~finally:(fun () -> Unix.close descriptor)
        (fun () ->
          let before = Unix.fstat descriptor in
          if before.st_kind <> Unix.S_REG then Error "is not a regular file"
          else if before.st_size > max_bundle_bytes then Error "exceeds the 16777216-byte limit"
          else (
            Unix.clear_nonblock descriptor;
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
            else Ok (Buffer.contents buffer)))
    with exception_ -> (
      match io_exception exception_ with Some message -> Error message | None -> raise exception_)
  with
  | Ok bytes -> Ok bytes
  | Error message ->
      error ~code:"E1510" "cannot read governance reconciliation bundle %s: %s" file message

let verify_file ~store ~file =
  let* source = read_file file in
  verify_string ~store ~file source
