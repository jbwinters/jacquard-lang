(** Scheduler-private, run-local scoped-channel handles. *)

type run = Concurrency_owner.t

type t
(** Opaque payload carrying one run owner and deterministic scoped-channel identity. *)

val create : run:run -> id:Channel_contract.channel_id -> t
(** [create] wraps an already validated scheduler-owned channel identity. *)

val validate_run : run:run -> t -> (Channel_contract.channel_id, Diag.t list) result
(** [validate_run] structurally revalidates the embedded deterministic identity and returns it only
    for the creating evaluator run. Malformed/forged and foreign handles return E0907 and expose no
    channel state. This check does not establish liveness; the owning Structured_scope registry must
    also contain the identity before any operation may consume state or a continuation. *)

val validate_scope :
  run:run -> scope_path:int list -> t -> (Channel_contract.channel_id, Diag.t list) result
(** [validate_scope] additionally requires the exact creating open scope. Parent, child, sibling,
    malformed, and foreign handles return E0907. Liveness and stale/destroyed refusal remain the
    responsibility of the owning Structured_scope registry. *)
