(** Budgeted, deterministic enumeration of structured-concurrency schedules.

    A runnable queue is the support of one scheduler [Choose] decision. Enumeration follows every
    task ID in queue order. Each branch starts a fresh evaluator run and uses the strict SC.10 trace
    fork seam, so branching never copies or reuses an affine Async resumption. There is no state
    hashing or partial-order pruning in v0. *)

type bounds = { max_tasks : int; max_decisions : int; max_worlds : int }
(** Three independent positive bounds. Task and decision bounds apply to each world; [max_worlds]
    bounds the number of fresh schedule executions started by the search. *)

val default_bounds : bounds

(** Why the search could not prove that it covered the complete bounded schedule tree. A routed
    effect is refused before its root callback, keeping exhaustive exploration hermetic. *)
type incomplete_reason =
  | Task_budget of { limit : int }
  | Decision_budget of { limit : int }
  | World_budget of { limit : int }
  | Routed_effect of { decision : int; operation : Hash.t }
  | Scheduler_refusal of string

type completeness = Complete | Incomplete of incomplete_reason list

type world = {
  result : (Value.t, Runtime_err.t) result;
  outcome : Round_robin.outcome;
  schedule : Schedule_trace.t;
}
(** One complete schedule. [schedule] is canonical and can be passed to strict replay. Program
    failure is a complete world and is retained in [result], rather than aborting the search. *)

type report = {
  worlds : world list;
  explored : int;
  worlds_started : int;
  completeness : completeness;
}
(** Exact search accounting. [explored] equals [List.length worlds]. [worlds_started] also includes
    executions that ended at a task/decision/hermeticity refusal. *)

val run_expr :
  Eval.ctx ->
  ?policy:Concurrency_contract.failure_policy ->
  ?bounds:bounds ->
  Kernel.expr ->
  (report, Diag.t list) result
(** [run_expr] explores every bounded runnable-task choice in deterministic depth-first queue order.
    No schedules are deduplicated. Invalid non-positive bounds return diagnostics. Reaching any
    bound returns [Ok] with [Incomplete _], never [Complete]. A stopped schedule retains its
    canonical choice prefix, so alternatives before the refusal are still explored and complete
    in-bound worlds remain in the report. Unhandled routed effects are recorded and refused without
    invoking a root callback. *)

val incomplete_reason_to_string : incomplete_reason -> string
(** Stable human-readable rendering for evidence and test reports. *)
