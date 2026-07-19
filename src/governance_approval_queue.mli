(** Crash-safe host storage for single-use GovernanceApprovalV1 decisions.

    This module is an explicit OCaml host adapter. It does not install a Jacquard handler,
    authenticate a human, evaluate policy, or perform any governed action. *)

type decision_evidence = { actor : string; decision : Form.t; decision_id : Hash.t }
(** The authenticated host actor and the exact released Decision Code stored by the queue. *)

type status =
  | Pending
  | Decided of decision_evidence
  | Stale_decision of decision_evidence
      (** Administrative state. A stale item retains historical evidence for inspection but can
          never be delivered or reset. *)

type item = {
  proposal_id : Hash.t;
  proposal : Form.t;
  allowed_approvers : string list;
  status : status;
}
(** One verified proposal and its sorted, unique host authorization metadata. The allowed-principal
    list is queue metadata and is not part of [proposal_id]. *)

type snapshot = { head : Hash.t; records : int; items : item list; recoverable_tail : bool }
(** A verified queue snapshot in submission order. [recoverable_tail] is true only when locked
    inspection recognized a physically uncommitted suffix after the last valid commit boundary;
    strict string verification never returns such a snapshot. *)

type mutation =
  | Applied of Hash.t
  | Unchanged of Hash.t
  | Stale
  | Busy
      (** Result of a mutating queue operation. [Applied head] acknowledges a durable append or
          recovery; [Unchanged head] is an exact idempotent retry or a clean recovery check; [Stale]
          refuses a consumed proposal; and [Busy] means an exclusion guard was unavailable. *)

type delivery =
  | Delivered of { actor : string; decision : Form.t; decision_id : Hash.t; head : Hash.t }
  | Pending_delivery
  | Stale_delivery
  | Busy_delivery
      (** Result of Consume. Every Decision variant is delivered only after its Consume record has
          been appended and synced. A crash after that sync may strand the result, but the queue
          will not deliver it twice. *)

type inspection =
  | Snapshot of snapshot
  | Busy_inspection
      (** Result of administrative inspection. Inspection includes stale historical evidence but
          never converts it back into a deliverable decision. *)

val genesis : Hash.t
(** Fixed HASH_V0 identity of the exact versioned [(governance-approval-queue-genesis-v1)] Code
    value. *)

val proposal_id : Form.t -> (Hash.t, Diag.t list) result
(** [proposal_id subject] validates the exact released [governance-proposal-v0] semantic Code and
    returns its unchanged HASH_V0 identity. Malformed or noncanonical subjects return E1523. *)

val decision_id : proposal_id:Hash.t -> Form.t -> (Hash.t, Diag.t list) result
(** [decision_id ~proposal_id decision] validates one exact released [approved-v1], [denied-v1], or
    [escalate-v1] Code value bound to [proposal_id], then returns its unchanged HASH_V0 identity.
    Malformed or stale Decisions return E1524. *)

val verify_string : file:string -> string -> (snapshot, Diag.t list) result
(** [verify_string ~file bytes] strictly verifies an LF-terminated canonical v1 journal from the
    fixed genesis through every stored record identity and state transition. It never performs
    torn-tail recovery. Malformed, corrupt, redundant, or illegal records fail closed with
    E1520--E1525. *)

val inspect_file : file:string -> (inspection, Diag.t list) result
(** [inspect_file ~file] takes the nonblocking whole-file lock, performs a bounded stable read and
    full verification, and returns the administrative snapshot. It reports, but does not mutate, a
    narrowly recognized physically uncommitted tail. A missing file is an empty queue. Lock
    contention returns [Busy_inspection]; unsafe paths and I/O failures return E1526. *)

val recover_file : file:string -> (mutation, Diag.t list) result
(** [recover_file ~file] durably truncates one narrowly recognized physically uncommitted suffix to
    the last committed transaction boundary. [Applied head] means recovery occurred,
    [Unchanged head] means the journal was already clean, and [Busy] means no mutation occurred.
    Every successful existing-file result establishes a file-and-parent-directory durability barrier
    before return. Committed corruption always fails closed. *)

val submit_file :
  file:string ->
  proposal_id:Hash.t ->
  proposal:Form.t ->
  allowed_approvers:string list ->
  (mutation, Diag.t list) result
(** [submit_file] validates that [proposal_id] is the HASH_V0 identity of the exact supplied
    GovernanceProposal and that [allowed_approvers] is nonempty, sorted, unique, and contains only
    nonempty single-line principals. It then locks, fully verifies, and durably appends a Submit. An
    exact retry is [Unchanged]; drift conflicts with E1525; stale state returns [Stale]. Every
    successful result other than [Busy] establishes a file-and-parent-directory durability barrier
    before return. *)

val decide_file :
  file:string ->
  proposal_id:Hash.t ->
  actor:string ->
  decision:Form.t ->
  (mutation, Diag.t list) result
(** [decide_file] requires [actor] to be an allowed authenticated principal. Approved and Denied
    Decision approvers must equal [actor]; Escalate records [actor] only as queue metadata, leaving
    the released Decision Code unchanged. An exact retry is [Unchanged], a different decision is
    E1525, and stale state returns [Stale]. Every successful result other than [Busy] establishes a
    file-and-parent-directory durability barrier before return. *)

val consume_file : file:string -> proposal_id:Hash.t -> (delivery, Diag.t list) result
(** [consume_file] returns [Pending_delivery] without mutation for an undecided proposal. For any
    Decision variant it durably appends Consume before returning the exact Decision once. A missing
    proposal is E1525; consumed state is [Stale_delivery]. Every successful result other than
    [Busy_delivery] establishes a file-and-parent-directory durability barrier before return. The
    pathname checks require a trusted, stable parent directory; hostile concurrent renames cannot be
    made race-free with pathname checks alone. *)
