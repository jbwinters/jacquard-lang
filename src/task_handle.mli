(** Scheduler-owned, run-local Task value payloads.

    This module is private to the Jacquard runtime. It deliberately exposes no equality, rendering,
    or serialization operation: a handle is useful only after validation against the current run and
    structured scope. *)

type run = Concurrency_owner.t
(** An opaque runtime identity. It is compared by identity and never enters a Task's deterministic
    scheduler ID or a user-visible value. *)

type t
(** An opaque Task payload carrying a run owner and the deterministic scope-path/spawn-index ID
    frozen by SC.0. *)

val create_run : unit -> run
(** [create_run ()] allocates the owner token for one evaluator/scheduler run. *)

val create : run:run -> scope_path:int list -> spawn_index:int -> (t, Diag.t list) result
(** [create] constructs a scheduler-owned handle. Malformed paths or spawn indices return E0907;
    internal task-ID exceptions never cross this boundary. *)

val validate_run : run:run -> t -> (Concurrency_contract.task_id, Diag.t list) result
(** [validate_run] returns the deterministic ID only when [t] belongs to [run] and its encoded ID is
    well formed. Foreign, stale, or malformed handles return E0907. *)

val validate_scope :
  run:run -> scope_path:int list -> t -> (Concurrency_contract.task_id, Diag.t list) result
(** [validate_scope] additionally requires the exact owning scope path. It returns E0907 for
    cross-scope use and never raises for malformed input. *)
