(** Verified, proposal-scoped projection of one governance reconciliation package. *)

type audit_entry = { index : int; digest : Hash.t; entry : Form.t }
(** One relevant Audit v2 entry in original chain order. [digest] is the verified record digest. *)

type attempted = {
  state : string;
  attempt_id : Hash.t;
  driver_name : string;
  driver_id : Hash.t;
  receipt_id : Hash.t option;
  external_receipt_digest : Hash.t option;
}
(** Exact committed action evidence. [state] is one of [attempt-outcome-unknown],
    [completed-without-receipt], [receipt-pending-completion], or [reconciled-completed]. The driver
    identity proves what the Attempted subject committed, not that the driver ran. *)

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
(** The complete typed explanation for one exact Proposal. Every field is committed by, or
    deterministically recomputed from, a fully verified reconciliation package. *)

val schema : string
(** The exact success-report schema, [jacquard-governance-explain-report-v1]. *)

val review_facts_schema : string
(** The exact nested dynamic-facts schema, [jacquard-governance-review-facts-v1]. The schema
    contains only facts available from the verified reconciliation package; it has no simulator or
    provenance placeholders. *)

val proposal_id_of_string : string -> (Hash.t, Diag.t list) result
(** Parses exactly 64 lowercase HASH_V0 hexadecimal digits. Malformed input returns E1530. *)

val of_verified :
  proposal_id:Hash.t -> Governance_reconcile.verified -> (report, Diag.t list) result
(** Selects exactly one linked Proposal from a completely verified reconciliation package,
    recomputes the live policy rule and verdict, and validates any committed Workspace driver.
    Missing or unrelated selection, policy disagreement, unsupported Workspace identity, driver
    mismatch, or an approved-completion gap returns E1531--E1533. It never guesses a driver or
    claims that committed action evidence proves execution. *)

val verify_form :
  store:Store.t -> file:string -> proposal_id:Hash.t -> Form.t -> (report, Diag.t list) result
(** Completely verifies [bundle] through {!Governance_reconcile.verify_detailed_form} before
    selecting or rendering [proposal_id]. No report is returned for a partial verification. *)

val verify_string :
  store:Store.t -> file:string -> proposal_id:Hash.t -> string -> (report, Diag.t list) result
(** Accepts exactly one compact canonical reconciliation form followed by LF, verifies it once in
    full, then produces the selected explanation. *)

val verify_file : store:Store.t -> file:string -> proposal_id:Hash.t -> (report, Diag.t list) result
(** Performs the reconciliation verifier's bounded, race-detecting regular-file read, verifies the
    whole package before projection, and returns stable diagnostics without leaking exceptions. *)

val render_text : report -> string
(** Renders every report field in deterministic human-readable order with a trailing LF. *)

val render_json_v1 : report -> string
(** Renders every report field as one compact deterministic JSON object without a trailing LF. *)
