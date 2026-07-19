(** Offline reconciliation between a verified governance run and a separately chained action
    journal. *)

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
(** Stable counts for one internally linked reconciliation package. Nonzero gap counts are operator
    work, not claims of rollback or safe retry. [completion_without_receipt] includes a uniquely
    authorized live completion even when no Attempted entry names it. *)

val journal_genesis : Hash.t
(** The fixed empty predecessor for [governance-action-journal-v1]. *)

val attempt_id :
  call_id:Hash.t ->
  authorization:Hash.t ->
  branch:string ->
  driver_id:Hash.t ->
  idempotency_key_digest:Hash.t ->
  Hash.t
(** Recomputes the semantic identity carried by an [action-attempted-v1] entry. Empty branches are
    rejected by verification even though this pure identity helper is total. *)

val receipt_id : attempt_id:Hash.t -> outcome:Form.t -> external_receipt_digest:Hash.t -> Hash.t
(** Recomputes the semantic identity carried by an [action-receipt-v1] entry. *)

val append_journal : previous:Hash.t -> entry:Form.t -> (Form.t * Hash.t, Diag.t list) result
(** Validates one journal entry, commits its canonical bytes to [previous], and returns the exact
    [governance-action-chain-v1] record plus its new head. Malformed entries return E1510. *)

val verify_form : store:Store.t -> file:string -> Form.t -> (report, Diag.t list) result
(** Verifies one exact [governance-reconciliation-bundle-v1]. It first applies the unchanged run
    bundle verifier, then verifies the Live/Dry verdict matrix, unique evaluated Call occurrences,
    journal identity and order, authorization, every live completion, and exact receipt links.
    Structural contradictions return E1510--E1515. Honest recovery gaps remain in [report]; the
    public command reports those as E1516. *)

val verify_string : store:Store.t -> file:string -> string -> (report, Diag.t list) result
(** Accepts exactly one compact canonical reconciliation form followed by LF. *)

val verify_file : store:Store.t -> file:string -> (report, Diag.t list) result
(** Performs a bounded, race-detecting regular-file read before verification. Expected I/O failures
    return E1510 and no exception escapes. *)
