(** Trusted two-run bridge from the released GovernanceApprovalV1 operation to the durable approval
    queue.

    The first run submits one exact GovernanceProposal and returns [Awaiting_approval] without
    resuming its affine continuation. After an authenticated host records a Decision through
    {!Governance_approval_queue.decide_file}, a complete rerun consumes that Decision durably and
    resumes the new continuation exactly once. The bridge neither authenticates principals nor
    persists continuations, and one invocation supports at most one queue-backed approval
    rendezvous. *)

type outcome =
  | Completed of Value.t
  | Awaiting_approval of { proposal_id : Hash.t; queue_head : Hash.t }
  | Busy of { proposal_id : Hash.t }
  | Stale_approval of { proposal_id : Hash.t }
      (** Host-visible outcome. Pending, Busy, and Stale outcomes never resume the captured
          GovernanceApprovalV1 continuation. *)

val run :
  Eval.ctx ->
  file:string ->
  allowed_approvers:string list ->
  Eval.state ->
  (outcome, Diag.t list) result
(** [run ctx ~file ~allowed_approvers initial] executes [initial] through the guarded root router.
    It intercepts only the exact released [governance-approval.ask] operation, dispatches other
    installed root handlers normally, and never installs or accepts a handler callback.

    A newly applied Submit returns [Awaiting_approval] immediately, even if a reviewer races to
    record a Decision. Only an unchanged Submit from a later complete run attempts Consume; only a
    queue [Delivered] result is converted to the released Decision runtime constructor and used to
    resume the affine continuation. Busy and stale queue states are typed outcomes. Invalid carriers
    and queue configuration retain E1523--E1526; a rebound frozen schema or second sequential
    approval request returns E1527. Unhandled effects also return diagnostics. A consumed Decision
    cannot be replayed by a later invocation. *)
