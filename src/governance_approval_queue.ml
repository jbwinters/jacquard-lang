(** Crash-safe, single-use approval queue host adapter.

    A committed transaction occupies two canonical LF-terminated lines. The first stores the exact
    versioned record subject and its HASH_V0 identity; the second commits that identity. This
    physical commit boundary lets restart distinguish a recognized uncommitted suffix from a
    committed record without weakening verification of the committed prefix. *)

type decision_evidence = { actor : string; decision : Form.t; decision_id : Hash.t }
type status = Pending | Decided of decision_evidence | Stale_decision of decision_evidence

type item = {
  proposal_id : Hash.t;
  proposal : Form.t;
  allowed_approvers : string list;
  status : status;
}

type snapshot = { head : Hash.t; records : int; items : item list; recoverable_tail : bool }
type mutation = Applied of Hash.t | Unchanged of Hash.t | Stale | Busy

type delivery =
  | Delivered of { actor : string; decision : Form.t; decision_id : Hash.t; head : Hash.t }
  | Pending_delivery
  | Stale_delivery
  | Busy_delivery

type inspection = Snapshot of snapshot | Busy_inspection

let ( let* ) = Result.bind

let diagnostic_spec = function
  | "E1520" ->
      ( "The approval queue journal is malformed or noncanonical.",
        "Restore the exact canonical v1 record/commit framing or recover only an uncommitted tail."
      )
  | "E1521" ->
      ( "The approval queue journal uses an unsupported carrier version.",
        "Supply the released governance-approval-queue v1 carriers." )
  | "E1522" ->
      ( "An approval queue record identity or predecessor is invalid.",
        "Restore the original append-only record and its matching commit line." )
  | "E1523" ->
      ( "A GovernanceProposal or queue approver configuration is invalid.",
        "Submit the exact governance-proposal-v0 Code and sorted unique authenticated principals."
      )
  | "E1524" ->
      ( "An approval Decision or authenticated actor is invalid.",
        "Use an allowed actor and an exact released Decision bound to this proposal." )
  | "E1525" ->
      ( "The requested approval queue transition conflicts with durable state.",
        "Inspect the queue and continue from its current pending, decided, or stale state." )
  | "E1526" ->
      ( "The approval queue could not be read or updated safely.",
        "Use a stable bounded regular file on a local filesystem and retry the operation." )
  | code -> raise (Diag.Bug_invalid_diagnostic ("unknown approval queue code " ^ code))

let error ~code fmt =
  Printf.ksprintf
    (fun cause ->
      let summary, next_step = diagnostic_spec code in
      Error [ Diag.error ~domain:Governance ~code ~summary ~cause ~next_step ~contrast:None () ])
    fmt

let hash_form value = Form.form "hash" [ Form.Hash value ]
let lit value = Form.form "lit" [ Form.Text value ]

let canonical_bytes ~code ~what value =
  match Printer.print_compact value with
  | bytes -> Ok bytes
  | exception Printer.Bug_unprintable message ->
      error ~code "%s is not canonical Code: %s" what message

let code_hash ~code ~what value =
  let* bytes = canonical_bytes ~code ~what value in
  Ok (Hash.of_string bytes)

let genesis_subject = Form.form "governance-approval-queue-genesis-v1" []
let genesis = Hash.of_string (Printer.print_compact genesis_subject)

let hash_value = function
  | { Form.head = "hash"; args = [ Form.Hash value ]; _ } -> Some value
  | _ -> None

let text_value = function
  | { Form.head = "lit"; args = [ Form.Text value ]; _ } -> Some value
  | _ -> None

let child_forms args =
  let rec loop reversed = function
    | [] -> Some (List.rev reversed)
    | Form.F value :: rest -> loop (value :: reversed) rest
    | (Form.Int _ | Form.Real _ | Form.Text _ | Form.Sym _ | Form.Hash _) :: _ -> None
  in
  loop [] args

module Hash_table = Hashtbl.Make (struct
  type t = Hash.t

  let equal = Hash.equal
  let hash value = Hashtbl.hash (Hash.to_raw value)
end)

type authority =
  | Effect of Hash.t
  | Resource of { effect_id : Hash.t; scope : string; configuration : Hash.t }

let compare_effect left right =
  match (Effect_registry.canonical_order left, Effect_registry.canonical_order right) with
  | Some left, Some right -> Int.compare left right
  | Some _, None -> -1
  | None, Some _ -> 1
  | None, None -> Hash.compare left right

let compare_authority left right =
  let effect_id = function Effect value | Resource { effect_id = value; _ } -> value in
  match compare_effect (effect_id left) (effect_id right) with
  | value when value <> 0 -> value
  | _ -> (
      match (left, right) with
      | Effect _, Effect _ -> 0
      | Effect _, Resource _ -> -1
      | Resource _, Effect _ -> 1
      | ( Resource { scope = left_scope; configuration = left_configuration; _ },
          Resource { scope = right_scope; configuration = right_configuration; _ } ) -> (
          match String.compare left_scope right_scope with
          | value when value <> 0 -> value
          | _ -> Hash.compare left_configuration right_configuration))

let validate_authority = function
  | { Form.head = "governance-authority-list-v0"; args; _ } -> (
      match child_forms args with
      | None -> error ~code:"E1523" "GovernanceProposal has a malformed authority list"
      | Some values ->
          let parse position = function
            | { Form.head = "governance-effect-v0"; args = [ Form.F value ]; _ } -> (
                match hash_value value with
                | Some effect_id -> Ok (Effect effect_id)
                | None ->
                    error ~code:"E1523"
                      "GovernanceProposal authority entry %d has a malformed Effect hash" position)
            | {
                Form.head = "governance-resource-v0";
                args = [ Form.F effect_value; Form.F scope; Form.F configuration ];
                _;
              } -> (
                match (hash_value effect_value, text_value scope, hash_value configuration) with
                | Some effect_id, Some scope, Some configuration when not (String.equal scope "") ->
                    Ok (Resource { effect_id; scope; configuration })
                | _ ->
                    error ~code:"E1523"
                      "GovernanceProposal authority entry %d has a malformed Resource" position)
            | _ -> error ~code:"E1523" "GovernanceProposal authority entry %d is malformed" position
          in
          let rec parse_all position reversed = function
            | [] -> Ok (List.rev reversed)
            | value :: rest ->
                let* value = parse position value in
                parse_all (position + 1) (value :: reversed) rest
          in
          let* parsed = parse_all 0 [] values in
          let seen = Hash_table.create (max 16 (List.length parsed)) in
          let rec check previous = function
            | [] -> Ok ()
            | value :: rest -> (
                if
                  Option.fold ~none:false
                    ~some:(fun prior -> compare_authority prior value >= 0)
                    previous
                then
                  error ~code:"E1523"
                    "GovernanceProposal authority is not in strict canonical order"
                else
                  let effect_id =
                    match value with Effect id | Resource { effect_id = id; _ } -> id
                  in
                  match value with
                  | Effect _ when Hash_table.mem seen effect_id ->
                      error ~code:"E1523" "GovernanceProposal authority repeats an Effect"
                  | Effect _ ->
                      Hash_table.add seen effect_id ();
                      check (Some value) rest
                  | Resource _ when not (Hash_table.mem seen effect_id) ->
                      error ~code:"E1523"
                        "GovernanceProposal authority has a Resource without its preceding Effect"
                  | Resource _ -> check (Some value) rest)
          in
          check None parsed)
  | _ -> error ~code:"E1523" "GovernanceProposal has no governance-authority-list-v0 carrier"

let validate_outcome = function
  | {
      Form.head = "governance-outcome-summary-v0";
      args = [ Form.F version; Form.F status; Form.F digest; Form.F detail ];
      _;
    } ->
      version.Form.head = "governance-v0"
      && version.args = []
      && Option.fold ~none:false
           ~some:(fun value -> not (String.equal value ""))
           (text_value status)
      && Option.is_some (hash_value digest)
      && Option.is_some (text_value detail)
  | _ -> false

let validate_preview = function
  | { Form.head = "none-v0"; args = []; _ } -> true
  | { Form.head = "some-v0"; args = [ Form.F outcome ]; _ } -> validate_outcome outcome
  | _ -> false

let proposal_id proposal =
  match proposal with
  | {
   Form.head = "governance-proposal-v0";
   args =
     [
       Form.F version;
       Form.F call;
       Form.F policy;
       Form.F assessment;
       Form.F authority;
       Form.F preview;
       Form.F _rendering;
       Form.F summary;
     ];
   _;
  }
    when version.Form.head = "governance-v0"
         && version.args = []
         && Option.is_some (hash_value call)
         && Option.is_some (hash_value policy)
         && Option.is_some (hash_value assessment)
         && validate_preview preview
         && Option.is_some (text_value summary) ->
      let* () = validate_authority authority in
      code_hash ~code:"E1523" ~what:"GovernanceProposal" proposal
  | { Form.head; _ } when not (String.equal head "governance-proposal-v0") ->
      error ~code:"E1523" "expected governance-proposal-v0, found `%s`" head
  | _ -> error ~code:"E1523" "GovernanceProposal does not match the released semantic Code schema"

type decision_kind = Approved of string | Denied of string | Escalated

let decision_shape = function
  | { Form.head = "approved-v1"; args = [ Form.F proposal; Form.F approver; Form.F _evidence ]; _ }
    -> (
      match (hash_value proposal, text_value approver) with
      | Some proposal_id, Some approver -> Ok (proposal_id, Approved approver)
      | _ -> error ~code:"E1524" "Approved Decision has malformed proposal or approver fields")
  | { Form.head = "denied-v1"; args = [ Form.F proposal; Form.F approver; Form.F reason ]; _ } -> (
      match (hash_value proposal, text_value approver, text_value reason) with
      | Some proposal_id, Some approver, Some _ -> Ok (proposal_id, Denied approver)
      | _ ->
          error ~code:"E1524" "Denied Decision has malformed proposal, approver, or reason fields")
  | { Form.head = "escalate-v1"; args = [ Form.F proposal; Form.F reason ]; _ } -> (
      match (hash_value proposal, text_value reason) with
      | Some proposal_id, Some _ -> Ok (proposal_id, Escalated)
      | _ -> error ~code:"E1524" "Escalate Decision has malformed proposal or reason fields")
  | { Form.head; _ } -> error ~code:"E1524" "unsupported or malformed Decision carrier `%s`" head

let decision_id ~proposal_id decision =
  let* embedded, _ = decision_shape decision in
  if not (Hash.equal embedded proposal_id) then
    error ~code:"E1524" "Decision names proposal #%s instead of exact proposal #%s"
      (Hash.to_hex embedded) (Hash.to_hex proposal_id)
  else code_hash ~code:"E1524" ~what:"Decision" decision

let valid_principal value =
  (not (String.equal value ""))
  && (not (String.contains value '\n'))
  && not (String.contains value '\r')

let validate_approvers values =
  if values = [] then error ~code:"E1523" "allowed approvers must not be empty"
  else if not (List.for_all valid_principal values) then
    error ~code:"E1523" "allowed approvers must be nonempty single-line principals"
  else
    let rec ordered = function
      | [] | [ _ ] -> true
      | left :: (right :: _ as rest) -> String.compare left right < 0 && ordered rest
    in
    if ordered values then Ok ()
    else error ~code:"E1523" "allowed approvers must be sorted and unique"

type event =
  | Submit_event of { proposal_id : Hash.t; proposal : Form.t; allowed_approvers : string list }
  | Decide_event of { proposal_id : Hash.t; evidence : decision_evidence }
  | Consume_event of { proposal_id : Hash.t; decision_id : Hash.t }

let approvers_form values =
  Form.form "governance-approval-queue-approvers-v1"
    (List.map (fun value -> Form.F (lit value)) values)

let event_form = function
  | Submit_event { proposal_id; proposal; allowed_approvers } ->
      Form.form "governance-approval-queue-submitted-v1"
        [
          Form.F (hash_form proposal_id); Form.F proposal; Form.F (approvers_form allowed_approvers);
        ]
  | Decide_event { proposal_id; evidence } ->
      Form.form "governance-approval-queue-decided-v1"
        [ Form.F (hash_form proposal_id); Form.F (lit evidence.actor); Form.F evidence.decision ]
  | Consume_event { proposal_id; decision_id } ->
      Form.form "governance-approval-queue-consumed-v1"
        [ Form.F (hash_form proposal_id); Form.F (hash_form decision_id) ]

let parse_approvers = function
  | { Form.head = "governance-approval-queue-approvers-v1"; args; _ } -> (
      match child_forms args with
      | None -> error ~code:"E1523" "queue approver metadata contains a scalar leaf"
      | Some forms ->
          let rec values reversed = function
            | [] -> Ok (List.rev reversed)
            | value :: rest -> (
                match text_value value with
                | Some value -> values (value :: reversed) rest
                | None -> error ~code:"E1523" "queue approver metadata contains a non-text value")
          in
          let* values = values [] forms in
          let* () = validate_approvers values in
          Ok values)
  | _ -> error ~code:"E1523" "queue approver metadata has an unsupported carrier"

let parse_event = function
  | {
      Form.head = "governance-approval-queue-submitted-v1";
      args = [ Form.F carried; Form.F proposal; Form.F approvers ];
      _;
    } -> (
      match hash_value carried with
      | None -> error ~code:"E1523" "Submit event has a malformed proposal identity"
      | Some carried ->
          let* computed = proposal_id proposal in
          if not (Hash.equal carried computed) then
            error ~code:"E1523" "Submit carries proposal #%s but exact Proposal hashes to #%s"
              (Hash.to_hex carried) (Hash.to_hex computed)
          else
            let* allowed_approvers = parse_approvers approvers in
            Ok (Submit_event { proposal_id = carried; proposal; allowed_approvers }))
  | {
      Form.head = "governance-approval-queue-decided-v1";
      args = [ Form.F proposal; Form.F actor; Form.F decision ];
      _;
    } -> (
      match (hash_value proposal, text_value actor) with
      | Some proposal_id, Some actor when valid_principal actor ->
          let* decision_id = decision_id ~proposal_id decision in
          Ok (Decide_event { proposal_id; evidence = { actor; decision; decision_id } })
      | _ -> error ~code:"E1524" "Decide event has malformed proposal or actor metadata")
  | {
      Form.head = "governance-approval-queue-consumed-v1";
      args = [ Form.F proposal; Form.F decision ];
      _;
    } -> (
      match (hash_value proposal, hash_value decision) with
      | Some proposal_id, Some decision_id -> Ok (Consume_event { proposal_id; decision_id })
      | _ -> error ~code:"E1524" "Consume event has malformed proposal or Decision identity")
  | { Form.head; _ }
    when String.equal head "governance-approval-queue-submitted-v1"
         || String.equal head "governance-approval-queue-decided-v1"
         || String.equal head "governance-approval-queue-consumed-v1" ->
      error ~code:"E1520" "malformed approval queue event `%s`" head
  | { Form.head; _ } -> error ~code:"E1521" "unsupported approval queue event `%s`" head

type internal_status = I_pending | I_decided of decision_evidence | I_stale of decision_evidence

type internal_item = {
  proposal_id : Hash.t;
  proposal : Form.t;
  allowed_approvers : string list;
  mutable status : internal_status;
}

type internal_snapshot = {
  mutable head : Hash.t;
  mutable records : int;
  mutable reverse_order : Hash.t list;
  table : internal_item Hash_table.t;
}

let empty_internal () =
  { head = genesis; records = 0; reverse_order = []; table = Hash_table.create 16 }

let public_snapshot ~recoverable_tail internal =
  let items =
    List.rev_map
      (fun id ->
        let value = Hash_table.find internal.table id in
        let status =
          match value.status with
          | I_pending -> Pending
          | I_decided evidence -> Decided evidence
          | I_stale evidence -> Stale_decision evidence
        in
        ({
           proposal_id = value.proposal_id;
           proposal = value.proposal;
           allowed_approvers = value.allowed_approvers;
           status;
         }
          : item))
      internal.reverse_order
  in
  { head = internal.head; records = internal.records; items; recoverable_tail }

let evidence_equal left right =
  String.equal left.actor right.actor
  && Hash.equal left.decision_id right.decision_id
  && Form.equal_ignoring_meta left.decision right.decision

let transition internal event =
  match event with
  | Submit_event { proposal_id; proposal; allowed_approvers } ->
      if Hash_table.mem internal.table proposal_id then
        error ~code:"E1525" "journal submits proposal #%s more than once" (Hash.to_hex proposal_id)
      else
        Ok
          (fun () ->
            Hash_table.add internal.table proposal_id
              { proposal_id; proposal; allowed_approvers; status = I_pending };
            internal.reverse_order <- proposal_id :: internal.reverse_order)
  | Decide_event { proposal_id; evidence } -> (
      match Hash_table.find_opt internal.table proposal_id with
      | None -> error ~code:"E1525" "journal decides unknown proposal #%s" (Hash.to_hex proposal_id)
      | Some { status = I_decided _; _ } ->
          error ~code:"E1525" "journal decides proposal #%s more than once"
            (Hash.to_hex proposal_id)
      | Some { status = I_stale _; _ } ->
          error ~code:"E1525" "journal decides stale proposal #%s" (Hash.to_hex proposal_id)
      | Some ({ status = I_pending; allowed_approvers; _ } as item) -> (
          if not (List.mem evidence.actor allowed_approvers) then
            error ~code:"E1524" "actor %S is not allowed to decide proposal #%s" evidence.actor
              (Hash.to_hex proposal_id)
          else
            let* _, kind = decision_shape evidence.decision in
            match kind with
            | (Approved approver | Denied approver) when not (String.equal approver evidence.actor)
              ->
                error ~code:"E1524" "authenticated actor %S does not match Decision approver %S"
                  evidence.actor approver
            | Approved _ | Denied _ | Escalated -> Ok (fun () -> item.status <- I_decided evidence))
      )
  | Consume_event { proposal_id; decision_id } -> (
      match Hash_table.find_opt internal.table proposal_id with
      | None ->
          error ~code:"E1525" "journal consumes unknown proposal #%s" (Hash.to_hex proposal_id)
      | Some { status = I_pending; _ } ->
          error ~code:"E1525" "journal consumes pending proposal #%s" (Hash.to_hex proposal_id)
      | Some { status = I_stale _; _ } ->
          error ~code:"E1525" "journal consumes stale proposal #%s more than once"
            (Hash.to_hex proposal_id)
      | Some ({ status = I_decided evidence; _ } as item) ->
          if not (Hash.equal evidence.decision_id decision_id) then
            error ~code:"E1524" "Consume names Decision #%s but durable Decision is #%s"
              (Hash.to_hex decision_id)
              (Hash.to_hex evidence.decision_id)
          else Ok (fun () -> item.status <- I_stale evidence))

type parsed_record = { record_id : Hash.t; event : event }

let record_subject ~previous event =
  Form.form "governance-approval-queue-record-v1"
    [ Form.F (hash_form previous); Form.F (event_form event) ]

let record_envelope ~record_id subject =
  Form.form "governance-approval-queue-record-envelope-v1"
    [ Form.F (hash_form record_id); Form.F subject ]

let commit_form record_id =
  Form.form "governance-approval-queue-commit-v1" [ Form.F (hash_form record_id) ]

let parse_canonical_line ~file ~line_number line =
  match Reader.parse_one ~file line with
  | Error diagnostics ->
      let cause =
        match diagnostics with
        | diagnostic :: _ -> Diag.cause diagnostic
        | [] -> "unknown reader failure"
      in
      error ~code:"E1520" "%s:%d: malformed queue journal line: %s" file line_number cause
  | Ok value -> (
      match canonical_bytes ~code:"E1520" ~what:"queue journal line" value with
      | Error _ as error -> error
      | Ok rendered when not (String.equal rendered line) ->
          error ~code:"E1520" "%s:%d: queue journal line is not canonical one-line Code" file
            line_number
      | Ok _ -> Ok value)

let parse_record_line ~file ~line_number ~previous line =
  let* value = parse_canonical_line ~file ~line_number line in
  match value with
  | {
   Form.head = "governance-approval-queue-record-envelope-v1";
   args = [ Form.F stored; Form.F subject ];
   _;
  } -> (
      match (hash_value stored, subject) with
      | ( Some stored,
          {
            Form.head = "governance-approval-queue-record-v1";
            args = [ Form.F predecessor; Form.F event ];
            _;
          } ) -> (
          match hash_value predecessor with
          | None -> error ~code:"E1520" "%s:%d: record predecessor is malformed" file line_number
          | Some predecessor when not (Hash.equal predecessor previous) ->
              error ~code:"E1522" "%s:%d: expected predecessor #%s, found #%s" file line_number
                (Hash.to_hex previous) (Hash.to_hex predecessor)
          | Some _ ->
              let* computed = code_hash ~code:"E1522" ~what:"queue record subject" subject in
              if not (Hash.equal stored computed) then
                error ~code:"E1522" "%s:%d: stored record #%s recomputes to #%s" file line_number
                  (Hash.to_hex stored) (Hash.to_hex computed)
              else
                let* event = parse_event event in
                Ok { record_id = stored; event })
      | _ -> error ~code:"E1520" "%s:%d: malformed queue record envelope" file line_number)
  | { Form.head; _ } when not (String.equal head "governance-approval-queue-record-envelope-v1") ->
      error ~code:"E1521" "%s:%d: unsupported queue record carrier `%s`" file line_number head
  | _ -> error ~code:"E1520" "%s:%d: malformed queue record envelope" file line_number

let parse_commit_line ~file ~line_number ~record_id line =
  let* value = parse_canonical_line ~file ~line_number line in
  match value with
  | { Form.head = "governance-approval-queue-commit-v1"; args = [ Form.F value ]; _ } -> (
      match hash_value value with
      | Some value when Hash.equal value record_id -> Ok ()
      | Some value ->
          error ~code:"E1522" "%s:%d: commit names record #%s instead of #%s" file line_number
            (Hash.to_hex value) (Hash.to_hex record_id)
      | None -> error ~code:"E1520" "%s:%d: commit identity is malformed" file line_number)
  | { Form.head; _ } when not (String.equal head "governance-approval-queue-commit-v1") ->
      error ~code:"E1521" "%s:%d: unsupported queue commit carrier `%s`" file line_number head
  | _ -> error ~code:"E1520" "%s:%d: malformed queue commit" file line_number

type scan = { internal : internal_snapshot; recover_at : int option }

let record_envelope_prefix = "(governance-approval-queue-record-envelope-v1"

let partial_record_prefix value =
  let value_length = String.length value in
  let prefix_length = String.length record_envelope_prefix in
  if value_length <= prefix_length then
    String.equal value (String.sub record_envelope_prefix 0 value_length)
  else String.starts_with ~prefix:record_envelope_prefix value

let complete_lines source =
  let length = String.length source in
  let terminated = length = 0 || source.[length - 1] = '\n' in
  let parts = String.split_on_char '\n' source in
  if terminated then
    let parts = if parts = [] then [] else List.rev (List.tl (List.rev parts)) in
    (parts, None)
  else
    match List.rev parts with
    | fragment :: reversed_lines -> (List.rev reversed_lines, Some fragment)
    | [] -> ([], Some source)

let scan_string ~file source =
  let lines, fragment = complete_lines source in
  let internal = empty_internal () in
  let rec committed line_number committed_bytes = function
    | record_line :: commit_line :: rest ->
        let* record = parse_record_line ~file ~line_number ~previous:internal.head record_line in
        let* apply = transition internal record.event in
        let* () =
          parse_commit_line ~file ~line_number:(line_number + 1) ~record_id:record.record_id
            commit_line
        in
        apply ();
        internal.head <- record.record_id;
        internal.records <- internal.records + 1;
        committed (line_number + 2)
          (committed_bytes + String.length record_line + String.length commit_line + 2)
          rest
    | [ record_line ] -> (
        let* record = parse_record_line ~file ~line_number ~previous:internal.head record_line in
        let* _apply = transition internal record.event in
        let expected_commit = Printer.print_compact (commit_form record.record_id) in
        match fragment with
        | None -> Ok { internal; recover_at = Some committed_bytes }
        | Some partial
          when String.length partial <= String.length expected_commit
               && String.equal partial (String.sub expected_commit 0 (String.length partial)) ->
            Ok { internal; recover_at = Some committed_bytes }
        | Some _ ->
            error ~code:"E1520"
              "%s:%d: partial commit is not a prefix of the expected canonical commit" file
              (line_number + 1))
    | [] -> (
        match fragment with
        | None -> Ok { internal; recover_at = None }
        | Some partial when partial_record_prefix partial ->
            Ok { internal; recover_at = Some committed_bytes }
        | Some _ ->
            error ~code:"E1520"
              "%s:%d: uncommitted suffix does not begin with the exact queue record-envelope prefix"
              file line_number)
  in
  committed 1 0 lines

let verify_string ~file source =
  let* scan = scan_string ~file source in
  match scan.recover_at with
  | None -> Ok (public_snapshot ~recoverable_tail:false scan.internal)
  | Some _ ->
      error ~code:"E1520" "%s ends after a physically uncommitted approval queue suffix" file

let max_journal_bytes = 16 * 1024 * 1024

let io_message = function
  | Sys_error message -> Some message
  | End_of_file -> Some "unexpected end of file"
  | Unix.Unix_error (code, operation, path) ->
      Some
        (if String.equal path "" then Printf.sprintf "%s: %s" operation (Unix.error_message code)
         else Printf.sprintf "%s: %s" path (Unix.error_message code))
  | _ -> None

let same_file left right =
  left.Unix.st_kind = Unix.S_REG && right.Unix.st_kind = Unix.S_REG && left.st_dev = right.st_dev
  && left.st_ino = right.st_ino

let read_descriptor ~file descriptor =
  let before = Unix.fstat descriptor in
  if before.st_kind <> Unix.S_REG then Error "not a regular file"
  else if before.st_size > max_journal_bytes then
    Error (Printf.sprintf "exceeds the %d-byte journal limit" max_journal_bytes)
  else
    let buffer = Buffer.create (min before.st_size 65536) in
    let chunk = Bytes.create 65536 in
    ignore (Unix.lseek descriptor 0 Unix.SEEK_SET);
    let rec read total =
      let count = Unix.read descriptor chunk 0 (Bytes.length chunk) in
      if count = 0 then Ok total
      else
        let total = total + count in
        if total > max_journal_bytes then Error "grew past the bounded-read limit"
        else (
          Buffer.add_subbytes buffer chunk 0 count;
          read total)
    in
    let* total = read 0 in
    let after = Unix.fstat descriptor in
    let path_after = Unix.lstat file in
    if not (same_file after path_after) then Error "path changed while the journal was read"
    else if before.st_size <> after.st_size || total <> before.st_size then
      Error "journal size changed while it was read"
    else Ok (Buffer.contents buffer)

type locked = Missing | Busy_lock | Locked of Unix.file_descr

(* POSIX record locks are per-process, so Domains need a process-local guard as well. Store the
   owner PID rather than a bool: after [fork], a child can replace its inherited stale parent PID
   and then rely on the kernel lock for inter-process exclusion. *)
let process_guard = Atomic.make 0

let acquire_process_guard () =
  let owner = Unix.getpid () in
  let rec acquire () =
    let observed = Atomic.get process_guard in
    if observed = owner then false
    else if Atomic.compare_and_set process_guard observed owner then true
    else acquire ()
  in
  acquire ()

let release_process_guard () =
  let owner = Unix.getpid () in
  ignore (Atomic.compare_and_set process_guard owner 0)

let close_descriptor descriptor =
  match Unix.close descriptor with
  | () -> Ok ()
  | exception exception_ -> (
      match io_message exception_ with Some message -> Error message | None -> raise exception_)

let open_locked ~file ~create =
  let rec open_path attempts =
    if attempts = 4 then raise (Sys_error "queue path changed repeatedly while opening")
    else
      match Unix.lstat file with
      | stats when stats.st_kind <> Unix.S_REG ->
          raise (Sys_error "queue path is not a regular file")
      | _ -> Locked (Unix.openfile file [ Unix.O_RDWR; Unix.O_APPEND ] 0)
      | exception Unix.Unix_error (Unix.ENOENT, _, _) when not create -> Missing
      | exception Unix.Unix_error (Unix.ENOENT, _, _) -> (
          match
            Unix.openfile file [ Unix.O_RDWR; Unix.O_APPEND; Unix.O_CREAT; Unix.O_EXCL ] 0o600
          with
          | descriptor -> (
              match Unix.fchmod descriptor 0o600 with
              | () -> Locked descriptor
              | exception exception_ ->
                  ignore (close_descriptor descriptor);
                  raise exception_)
          | exception Unix.Unix_error (Unix.EEXIST, _, _) -> open_path (attempts + 1))
  in
  match open_path 0 with
  | Missing -> Ok Missing
  | Busy_lock -> Ok Busy_lock
  | Locked descriptor -> (
      match
        try
          Unix.lockf descriptor Unix.F_TLOCK 0;
          let descriptor_stats = Unix.fstat descriptor in
          let path_stats = Unix.lstat file in
          if not (same_file descriptor_stats path_stats) then
            raise (Sys_error "queue path changed before lock acquisition");
          Ok (Locked descriptor)
        with
        | Unix.Unix_error ((Unix.EAGAIN | Unix.EACCES), _, _) -> Ok Busy_lock
        | exception_ -> Error exception_
      with
      | Ok Busy_lock -> (
          match close_descriptor descriptor with
          | Ok () -> Ok Busy_lock
          | Error message -> raise (Sys_error message))
      | Ok value -> Ok value
      | Error exception_ -> (
          match close_descriptor descriptor with
          | Ok () -> raise exception_
          | Error message -> raise (Sys_error message)))

let with_locked ~file ~create use =
  if not (acquire_process_guard ()) then use Busy_lock
  else
    Fun.protect ~finally:release_process_guard (fun () ->
        match
          try open_locked ~file ~create
          with exception_ -> (
            match io_message exception_ with
            | Some message -> Error message
            | None -> raise exception_)
        with
        | Error message -> error ~code:"E1526" "cannot lock approval queue %s: %s" file message
        | Ok Missing -> use Missing
        | Ok Busy_lock -> use Busy_lock
        | Ok (Locked descriptor) -> (
            match use (Locked descriptor) with
            | outcome -> (
                match close_descriptor descriptor with
                | Ok () -> outcome
                | Error message ->
                    error ~code:"E1526" "cannot close approval queue %s: %s" file message)
            | exception exception_ ->
                ignore (close_descriptor descriptor);
                raise exception_))

let read_scan ~file descriptor =
  match
    try read_descriptor ~file descriptor
    with exception_ -> (
      match io_message exception_ with Some message -> Error message | None -> raise exception_)
  with
  | Error message -> error ~code:"E1526" "cannot read approval queue %s: %s" file message
  | Ok bytes -> scan_string ~file bytes

let check_visible_path ~file descriptor =
  let descriptor_stats = Unix.fstat descriptor in
  let path_stats = Unix.lstat file in
  if same_file descriptor_stats path_stats then Ok ()
  else Error "queue path changed while the locked inode was being updated"

let truncate_recovery ~file descriptor = function
  | None -> Ok false
  | Some offset -> (
      match
        try
          Unix.ftruncate descriptor offset;
          Unix.fsync descriptor;
          check_visible_path ~file descriptor
        with exception_ -> (
          match io_message exception_ with
          | Some message -> Error message
          | None -> raise exception_)
      with
      | Ok () -> Ok true
      | Error message -> error ~code:"E1526" "cannot recover approval queue %s: %s" file message)

let write_all descriptor bytes =
  let rec loop offset =
    if offset = String.length bytes then ()
    else
      let count = Unix.write_substring descriptor bytes offset (String.length bytes - offset) in
      if count = 0 then raise (Sys_error "zero-byte write while appending queue transaction")
      else loop (offset + count)
  in
  loop 0

let sync_parent file =
  let directory = Filename.dirname file in
  let descriptor = Unix.openfile directory [ Unix.O_RDONLY ] 0 in
  match Unix.fsync descriptor with
  | () -> (
      match close_descriptor descriptor with
      | Ok () -> ()
      | Error message -> raise (Sys_error message))
  | exception exception_ ->
      ignore (close_descriptor descriptor);
      raise exception_

let durability_barrier ~file descriptor =
  let durable =
    try
      Unix.fsync descriptor;
      match check_visible_path ~file descriptor with
      | Error _ as error -> error
      | Ok () ->
          sync_parent file;
          check_visible_path ~file descriptor
    with exception_ -> (
      match io_message exception_ with Some message -> Error message | None -> raise exception_)
  in
  match durable with
  | Ok () -> Ok ()
  | Error message -> error ~code:"E1526" "cannot make approval queue %s durable: %s" file message

let append_event ~file descriptor internal event =
  let subject = record_subject ~previous:internal.head event in
  let record_id = Hash.of_string (Printer.print_compact subject) in
  let record = Printer.print_compact (record_envelope ~record_id subject) ^ "\n" in
  let commit = Printer.print_compact (commit_form record_id) ^ "\n" in
  match
    try
      let current_size = (Unix.fstat descriptor).st_size in
      if current_size + String.length record + String.length commit > max_journal_bytes then
        Ok `Too_large
      else (
        ignore (Unix.lseek descriptor 0 Unix.SEEK_END);
        write_all descriptor record;
        Unix.fsync descriptor;
        write_all descriptor commit;
        Unix.fsync descriptor;
        Ok `Appended)
    with exception_ -> (
      match io_message exception_ with Some message -> Error message | None -> raise exception_)
  with
  | Ok `Too_large ->
      error ~code:"E1526" "approval queue %s would exceed the %d-byte journal limit" file
        max_journal_bytes
  | Ok `Appended ->
      let* () = durability_barrier ~file descriptor in
      Ok record_id
  | Error message -> error ~code:"E1526" "cannot append approval queue %s: %s" file message

let inspect_file ~file =
  with_locked ~file ~create:false (function
    | Missing -> Ok (Snapshot (public_snapshot ~recoverable_tail:false (empty_internal ())))
    | Busy_lock -> Ok Busy_inspection
    | Locked descriptor ->
        let* scan = read_scan ~file descriptor in
        Ok
          (Snapshot
             (public_snapshot ~recoverable_tail:(Option.is_some scan.recover_at) scan.internal)))

let recover_file ~file =
  with_locked ~file ~create:false (function
    | Missing -> Ok (Unchanged genesis)
    | Busy_lock -> Ok Busy
    | Locked descriptor ->
        let* scan = read_scan ~file descriptor in
        let* changed = truncate_recovery ~file descriptor scan.recover_at in
        let* () = durability_barrier ~file descriptor in
        Ok (if changed then Applied scan.internal.head else Unchanged scan.internal.head))

let submit_file ~file ~proposal_id:carried ~proposal ~allowed_approvers =
  let* computed = proposal_id proposal in
  if not (Hash.equal carried computed) then
    error ~code:"E1523" "Submit carries proposal #%s but exact Proposal hashes to #%s"
      (Hash.to_hex carried) (Hash.to_hex computed)
  else
    let* () = validate_approvers allowed_approvers in
    with_locked ~file ~create:true (function
      | Missing -> raise (Diag.Bug_invalid_diagnostic "create=true returned Missing")
      | Busy_lock -> Ok Busy
      | Locked descriptor -> (
          let* scan = read_scan ~file descriptor in
          let* _recovered = truncate_recovery ~file descriptor scan.recover_at in
          let* () = durability_barrier ~file descriptor in
          match Hash_table.find_opt scan.internal.table carried with
          | None ->
              let event = Submit_event { proposal_id = carried; proposal; allowed_approvers } in
              let* _apply = transition scan.internal event in
              let* head = append_event ~file descriptor scan.internal event in
              Ok (Applied head)
          | Some { status = I_stale _; _ } -> Ok Stale
          | Some existing
            when Form.equal_ignoring_meta existing.proposal proposal
                 && existing.allowed_approvers = allowed_approvers ->
              Ok (Unchanged scan.internal.head)
          | Some _ ->
              error ~code:"E1525" "proposal #%s is already durable with different queue metadata"
                (Hash.to_hex carried)))

let decide_file ~file ~proposal_id ~actor ~decision =
  if not (valid_principal actor) then
    error ~code:"E1524" "authenticated actor must be a nonempty single-line principal"
  else
    let* decision_id = decision_id ~proposal_id decision in
    let evidence = { actor; decision; decision_id } in
    with_locked ~file ~create:false (function
      | Missing -> error ~code:"E1525" "cannot decide absent proposal #%s" (Hash.to_hex proposal_id)
      | Busy_lock -> Ok Busy
      | Locked descriptor -> (
          let* scan = read_scan ~file descriptor in
          let* _recovered = truncate_recovery ~file descriptor scan.recover_at in
          let* () = durability_barrier ~file descriptor in
          match Hash_table.find_opt scan.internal.table proposal_id with
          | None ->
              error ~code:"E1525" "cannot decide absent proposal #%s" (Hash.to_hex proposal_id)
          | Some { status = I_stale _; _ } -> Ok Stale
          | Some { status = I_decided prior; _ } when evidence_equal prior evidence ->
              Ok (Unchanged scan.internal.head)
          | Some { status = I_decided _; _ } ->
              error ~code:"E1525" "proposal #%s already has a different durable Decision"
                (Hash.to_hex proposal_id)
          | Some { status = I_pending; _ } ->
              let event = Decide_event { proposal_id; evidence } in
              let* _apply = transition scan.internal event in
              let* head = append_event ~file descriptor scan.internal event in
              Ok (Applied head)))

let consume_file ~file ~proposal_id =
  with_locked ~file ~create:false (function
    | Missing -> error ~code:"E1525" "cannot consume absent proposal #%s" (Hash.to_hex proposal_id)
    | Busy_lock -> Ok Busy_delivery
    | Locked descriptor -> (
        let* scan = read_scan ~file descriptor in
        let* _recovered = truncate_recovery ~file descriptor scan.recover_at in
        let* () = durability_barrier ~file descriptor in
        match Hash_table.find_opt scan.internal.table proposal_id with
        | None -> error ~code:"E1525" "cannot consume absent proposal #%s" (Hash.to_hex proposal_id)
        | Some { status = I_pending; _ } -> Ok Pending_delivery
        | Some { status = I_stale _; _ } -> Ok Stale_delivery
        | Some { status = I_decided evidence; _ } ->
            let event = Consume_event { proposal_id; decision_id = evidence.decision_id } in
            let* _apply = transition scan.internal event in
            let* head = append_event ~file descriptor scan.internal event in
            Ok
              (Delivered
                 {
                   actor = evidence.actor;
                   decision = evidence.decision;
                   decision_id = evidence.decision_id;
                   head;
                 })))
