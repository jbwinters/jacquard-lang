(** Canonical, versioned schedule traces for deterministic structured concurrency.

    Version 1 records scheduler identity, canonical program identity, policy and bounds, every
    task/scope creation, and every decision's exact ordered runnable queue, selected task, and
    observed operation. Parsing is strict and accepts only bytes that are already in canonical form.
    Unversioned and unknown-version logs are refused; there is no compatibility guessing. *)

val format_version : int
(** The only schedule-trace format accepted by this implementation. *)

type operation =
  | Return
  | Failure
  | Async_spawn
  | Async_await
  | Async_cancel
  | Async_yield
  | Async_scope
  | Routed of Hash.t
      (** The evaluator boundary reached by one chosen task. A routed operation carries its exact
          canonical operation-member hash so drift can be rejected before invoking a world callback.
      *)

type creation = {
  scope_path : int list;
  task : Concurrency_contract.task_id;
  parent : Concurrency_contract.task_id option;
}
(** One deterministic task creation. The root body is the sole creation without a parent. Nested
    scope bodies and spawned children name the task whose step created them. *)

type decision = {
  sequence : int;
  runnable : Concurrency_contract.task_id list;
  chosen : Concurrency_contract.task_id;
  operation : operation;
}
(** One scheduler step, including the complete ordered pre-decision queue. *)

type event = Create of creation | Decide of decision

type fork = { decision : int; chosen : Concurrency_contract.task_id }
(** Provenance of an explicitly requested counterfactual branch. This is metadata in the new trace,
    never a permissive replay fallback. *)

type t = {
  scheduler : string;
  program : Hash.t;
  policy : Concurrency_contract.failure_policy;
  max_tasks : int;
  max_decisions : int;
  fork : fork option;
  events : event list;
}

val make :
  scheduler:string ->
  program:Hash.t ->
  policy:Concurrency_contract.failure_policy ->
  max_tasks:int ->
  max_decisions:int ->
  ?fork:fork ->
  event list ->
  (t, Diag.t list) result
(** [make] validates all structural and ordering invariants. Bounds must be positive; the first
    event must create root task [0#0]; task IDs are unique and created before use; decision
    sequences are contiguous from zero; runnable queues contain unique created tasks; and every
    chosen task is present in its queue. Non-root creations must follow their parent's selected
    [async.spawn] or [async.scope] operation with the corresponding scope/ID shape. The linear pass
    enforces declared task, decision, and queue bounds and rejects a task after its recorded
    [return] or [failure]. Invalid traces return E0908 diagnostics. *)

val serialize : t -> string
(** [serialize trace] returns the unique v1 line-oriented byte representation with a trailing LF. *)

val parse : string -> (t, Diag.t list) result
(** [parse bytes] accepts only canonical v1 bytes. Missing or unknown versions, unversioned logs,
    malformed fields/IDs/hashes, impossible event order, and noncanonical whitespace/order return
    E0908. It never migrates or guesses an older format. *)

val parse_channel : in_channel -> (t, Diag.t list) result
(** [parse_channel channel] incrementally bounds the header, each line, total bytes, and total lines
    before constructing the complete input string, then applies {!parse}. The line ceiling is also
    restricted by the header's declared task and decision bounds. Oversized inputs return E0908;
    channel I/O exceptions remain the caller's responsibility. *)

val identity : t -> Hash.t
(** [identity trace] hashes the canonical serialized bytes for cache and replay identity. *)

val operation_to_string : operation -> string
(** Stable canonical token for an operation. *)

val task_id_of_string : string -> (Concurrency_contract.task_id, Diag.t list) result
(** [task_id_of_string text] parses the stable scheduler spelling [path#spawn] with the same
    unsigned component and depth checks used by trace parsing. *)
