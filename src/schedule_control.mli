(** Runtime-private strict record/replay controller for {!Round_robin}. *)

type mode =
  | Record
  | Record_with of
      (sequence:int ->
      runnable:Concurrency_contract.task_id list ->
      (Concurrency_contract.task_id, Diag.t list) result)
  | Replay of Schedule_trace.t
  | Fork of { trace : Schedule_trace.t; decision : int; chosen : Concurrency_contract.task_id }

type t

val create :
  scheduler:string ->
  program:Hash.t ->
  policy:Concurrency_contract.failure_policy ->
  max_tasks:int ->
  max_decisions:int ->
  mode ->
  (t, Diag.t list) result
(** Validates a replay header before any scheduler state is allocated. *)

val creation : t -> Schedule_trace.creation -> (unit, Diag.t list) result
(** Validates the next expected creation before the caller mutates allocation state, then records it
    in the fresh trace. *)

val begin_decision :
  t ->
  sequence:int ->
  runnable:Concurrency_contract.task_id list ->
  (Concurrency_contract.task_id, Diag.t list) result
(** Validates the exact sequence and ordered runnable queue and returns the task that may be chosen.
    Strict replay returns the recorded task; plain record mode returns the FIFO head; [Record_with]
    delegates to a deterministic policy; an explicit fork returns its requested live task only at
    the named decision. *)

val observe_operation : t -> Schedule_trace.operation -> (unit, Diag.t list) result
(** Validates the chosen step's operation. Callers must invoke this before a routed world callback
    or allocation action. *)

val finish_decision : t -> (unit, Diag.t list) result
(** Commits the fully observed decision followed by any creation events produced by that step. *)

val finish : t -> (Schedule_trace.t, Diag.t list) result
(** Refuses missing or extra replay events and returns the canonical fresh trace. *)
