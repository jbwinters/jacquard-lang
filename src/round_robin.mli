(** Deterministic FIFO scheduler for real interpreter states and the frozen Async operations.

    Each invocation creates a fresh opaque Task run, binds evaluator validation to that run through
    a private capability, routes every captured Async/world operation through SC.7 cancellation
    boundaries, and delegates sibling aggregation to {!Scope_policy}. Native root scheduling is
    deliberately unsupported. *)

val scheduler_version : string
(** Stable cache-identity component for this scheduler semantics. *)

val seeded_scheduler_version : string
(** Stable cache-identity component for the SplitMix64 decision policy. *)

type bounds = { max_tasks : int; max_decisions : int }
(** Positive deterministic refusal bounds. *)

val default_bounds : bounds

type schedule_mode =
  | Record_schedule
  | Seeded_schedule of { seed : int }
  | Replay_schedule of Schedule_trace.t
  | Fork_schedule of {
      trace : Schedule_trace.t;
      decision : int;
      chosen : Concurrency_contract.task_id;
    }
      (** Explicit schedule handling. [Seeded_schedule] chooses only from the recorded runnable
          queue with the existing SplitMix64 policy and never consults host randomness. Strict
          replay never falls back. A fork validates the source trace through decision
          [decision - 1], validates that decision's exact queue, selects [chosen] only if it is
          runnable, and records the resulting FIFO branch with fork provenance. *)

type outcome = {
  body : Value.t Concurrency_contract.task_result;
  root_error : Runtime_err.t option;
  aggregate : Value.t Scope_policy.aggregate;
  decisions : Concurrency_contract.decision list;
  trace : string;
  task_count : int;
  max_live : int;
  metrics_after_close : Structured_scope.metrics;
}
(** A fully drained evaluator scope. [root_error] retains the exact runtime error when [body] is a
    failed root task, so the CLI preserves established error codes and exit behavior. The recursive
    metrics are always zero. *)

type scheduled = { value : Value.t; outcome : outcome; schedule : Schedule_trace.t }
(** Successful scheduled execution plus its complete freshly recorded canonical trace. Strict replay
    therefore exposes byte-for-byte comparison without retaining a prior runtime value. *)

type scheduled_outcome = { execution_outcome : outcome; execution_schedule : Schedule_trace.t }
(** One complete scheduled execution, including a terminal program failure. *)

type schedule_budget = Task_limit | Decision_limit

type scheduled_attempt =
  | Finished of scheduled_outcome
  | Stopped of {
      budget : schedule_budget;
      error : Runtime_err.t;
      schedule_prefix : Schedule_trace.t;
    }
      (** A complete execution or a validated canonical prefix stopped by one scheduler bound. A
          stopped prefix is not a world, but retains every observed runnable choice so exhaustive
          search can fork alternatives that may complete within the same bound. *)

type recorded_call = {
  result : (Value.t, Runtime_err.t) result;
  outcome : outcome;
  schedule : Schedule_trace.t;
}
(** A completed scheduled callable run. Runtime failures remain in [result] while [schedule] retains
    the exact decisions that reached them. Structural scheduler failures still return from the outer
    result because they cannot claim a complete replayable trace. *)

val run_state :
  Eval.ctx ->
  ?policy:Concurrency_contract.failure_policy ->
  ?bounds:bounds ->
  Eval.state ->
  (outcome, Runtime_err.t) result
(** [run_state ctx state] executes real evaluator states under FIFO round-robin. Invalid bounds,
    lifecycle defects, escaped Tasks, and undrained scopes return runtime diagnostics after
    exception-safe recursive cleanup. *)

val run_expr :
  Eval.ctx ->
  ?policy:Concurrency_contract.failure_policy ->
  ?bounds:bounds ->
  Kernel.expr ->
  (Value.t, Runtime_err.t) result
(** [run_expr] is the default interpreted root scheduler. Pure and language-handled Async programs
    retain their ordinary results; unhandled frozen Async operations use this scheduler. *)

val run_expr_scheduled :
  Eval.ctx ->
  ?policy:Concurrency_contract.failure_policy ->
  ?bounds:bounds ->
  mode:schedule_mode ->
  Kernel.expr ->
  (scheduled, Runtime_err.t) result
(** [run_expr_scheduled] records, strictly replays, or explicitly forks one canonical expression.
    Header, creation, sequence, exact queue, chosen-task, operation, EOF, and leftover drift return
    E0908 after recursive cleanup. Creation records are checked before allocation; routed operation
    hashes are checked before their root callbacks. *)

val run_expr_outcome_scheduled :
  Eval.ctx ->
  ?policy:Concurrency_contract.failure_policy ->
  ?bounds:bounds ->
  ?allow_routed:bool ->
  mode:schedule_mode ->
  Kernel.expr ->
  (scheduled_outcome, Runtime_err.t) result
(** [run_expr_outcome_scheduled] is the lower-level complete-world seam used by schedule model
    checking. Unlike {!run_expr_scheduled}, a terminal task failure remains an [Ok] execution with
    its trace. When [allow_routed] is false, the scheduler records but does not invoke an unhandled
    routed operation; the world terminates with a hermeticity error. Lifecycle, replay, and budget
    defects still return [Error] because they do not describe a complete world. *)

val run_expr_scheduled_attempt :
  Eval.ctx ->
  ?policy:Concurrency_contract.failure_policy ->
  ?bounds:bounds ->
  ?allow_routed:bool ->
  mode:schedule_mode ->
  Kernel.expr ->
  (scheduled_attempt, Runtime_err.t) result
(** [run_expr_scheduled_attempt] is the bounded-search seam. Task and decision exhaustion return a
    [Stopped] canonical prefix after recursive cleanup; invalid inputs, lifecycle defects, and
    replay drift remain [Error]. The prefix contains no evaluator state, Task handle, or resumption.
    Strict replay of a task-budget prefix with the same bounds reproduces the same refusal and a
    byte-identical prefix. Callers must never count [Stopped] as a complete world. *)

val run_call :
  Eval.ctx ->
  ?policy:Concurrency_contract.failure_policy ->
  ?bounds:bounds ->
  Value.t ->
  Value.t list ->
  (Value.t, Runtime_err.t) result
(** [run_call] is the corresponding scheduled entry for an already evaluated callable. *)

val run_call_scheduled :
  Eval.ctx ->
  ?policy:Concurrency_contract.failure_policy ->
  ?bounds:bounds ->
  program:Hash.t ->
  mode:schedule_mode ->
  Value.t ->
  Value.t list ->
  (scheduled, Runtime_err.t) result
(** [run_call_scheduled] runs a callable under an explicit scheduler policy. [program] is the
    canonical test/program identity written into the replayable schedule header. *)

val run_call_recorded :
  Eval.ctx ->
  ?policy:Concurrency_contract.failure_policy ->
  ?bounds:bounds ->
  program:Hash.t ->
  mode:schedule_mode ->
  Value.t ->
  Value.t list ->
  (recorded_call, Runtime_err.t) result
(** [run_call_recorded] is the evidence-preserving form of [run_call_scheduled]: a language runtime
    failure does not discard the complete canonical schedule that produced it. *)

type cache
type cache_status = Hit | Miss

val create_cache : unit -> cache

val run_expr_cached :
  cache ->
  Eval.ctx ->
  ?policy:Concurrency_contract.failure_policy ->
  ?bounds:bounds ->
  Kernel.expr ->
  (outcome * cache_status, Runtime_err.t) result
(** [run_expr_cached] computes its key from the canonical expression hash, scheduler version,
    schedule format version, failure policy, and both bounds. Cache entries contain only
    deterministic trace/decision proof, never evaluator closures, continuations, Task handles, or
    result values; execution still produces a fresh run-local result and verifies a hit against the
    stored proof. *)
