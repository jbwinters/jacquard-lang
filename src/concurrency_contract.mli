(** Frozen, runtime-free contracts for structured concurrency (SC.0).

    This module owns nominal identities and pure deterministic state/ordering rules. It deliberately
    contains no Jacquard [Task] value representation, effect handler, or host scheduling. *)

exception Bug_invalid_task_id of string
(** Internal invariant failure raised when scheduler code attempts to construct a malformed task
    path, spawn index, or decision sequence. User-supplied Jacquard values cannot construct these
    scheduler records. *)

val task_type_hash : string
(** HASH_V0 identity of the exact frozen [Task a = TaskOpaque] declaration. *)

val task_opaque_constructor_hash : string
(** Derived constructor identity of the frozen scheduler-private [TaskOpaque] carrier. The store,
    checker, interpreter, and native lowerer use this identity to prevent Jacquard code from
    constructing a Task value. *)

val is_task_private_hash : Hash.t -> bool
(** [is_task_private_hash hash] is the single store/checker/runtime predicate for identities that
    must never receive a Jacquard name or construction path. In SC.3 this set contains exactly the
    frozen [TaskOpaque] constructor identity. *)

val task_result_type_hash : string
(** HASH_V0 identity of the exact frozen [TaskResult a] declaration. *)

val async_effect_hash : string
(** HASH_V0 identity of the exact frozen four-operation [Async a] declaration. This identity is
    structurally derived from the declarations above, all operation names and modes, and the
    self-effect row encoding; it is not a namespace/name authorization. *)

val async_operation_hashes : (string * string) list
(** Exact operation-member identities, in declaration order from [async.spawn] through
    [async.yield]. *)

val scope_control_hash : Hash.t
(** Internal non-Async identity used only to transfer [async.scope] control from the evaluator to
    the trusted scheduler. It is not a fifth Async operation and is never serialized as a value. *)

type task_id = private { scope_path : int list; spawn_index : int }
(** Opaque, run-local identity. The root [scope_path] is [[0]]; a nested scope appends its one-based
    creation ordinal. [spawn_index] is zero for the scope body and otherwise the one-based spawn
    ordinal. IDs have no Jacquard [Show] or serialization contract and are invalid outside their
    owning run. *)

val task_id : scope_path:int list -> spawn_index:int -> task_id
(** [task_id ~scope_path ~spawn_index] constructs a scheduler-owned ID. The path must be nonempty,
    begin with zero, and have only positive one-based components after the root; the spawn index
    must be non-negative. Every component and spawn index must fit unsigned 32 bits, and the path
    length is at most 65,532 components so the native Task block length fits unsigned 16 bits.
    Invalid input raises [Bug_invalid_task_id]. *)

val compare_task_id : task_id -> task_id -> int
(** [compare_task_id left right] orders scope paths lexicographically, then spawn ordinals. It is
    deterministic and independent of allocation addresses or hash-table iteration. *)

val trace_task_id : task_id -> string
(** [trace_task_id id] renders the scheduler-only stable spelling [path#spawn], with path components
    separated by [/], for example [0/2#3]. This is a trace/diagnostic encoding, not a Jacquard
    [Show] instance or canonical value serialization. *)

type 'a task
(** Abstract contract placeholder for a scope-local [Task a]. This module exposes no constructor or
    value-producing function; Task 127 / SC.3 owns the C1 runtime representation. *)

type 'a task_result =
  | Done of 'a
  | Failed of string
  | Cancelled
      (** Terminal result of one task. Failure text is stable user-facing text; cancellation carries
          no value and no hidden exception. *)

type lifecycle =
  | Runnable
  | Suspended
  | Done_state
  | Failed_state
  | Cancelled_state
      (** Complete C1 lifecycle vocabulary. The suffixes keep terminal states distinct from the
          [task_result] constructors in OCaml while preserving the Jacquard names. *)

val valid_transition : from_:lifecycle -> into:lifecycle -> bool
(** [valid_transition ~from_ ~into] accepts only runnable-to-suspended/terminal and
    suspended-to-runnable/terminal transitions. Terminal states are immutable and self-transitions
    are rejected. *)

val wake_waiters : task_id list -> task_id list
(** [wake_waiters waiters] returns every registered waiter in original registration order. *)

type 'a completion = { sequence : int; task : task_id; result : 'a task_result }
(** A terminal observation with scheduler-decision sequence. Scheduler implementations must supply
    non-negative, monotonically increasing sequences. *)

val order_completions : 'a completion list -> 'a completion list
(** [order_completions completions] orders by decision sequence, then deterministic task identity,
    and otherwise preserves input order. This is the frozen result/failure ordering relation. *)

val first_failure : 'a completion list -> 'a completion option
(** [first_failure completions] returns the first scheduler-ordered [Failed] or [Cancelled]
    completion, ignoring successful [Done] values. *)

type wait_edge = { waiter : task_id; target : task_id }
(** One suspended await dependency. Each waiter has at most one live edge in valid scheduler state.
*)

val detect_wait_cycle : wait_edge list -> task_id list option
(** [detect_wait_cycle edges] returns a deterministic closed cycle [id; ...; id], including
    self-await, or [None]. For malformed duplicate waiter edges, the lowest target is used so the
    result remains deterministic; scheduler validation must reject such state separately. *)

type failure_policy =
  | Fail_fast
  | Collect  (** Scope sibling-failure policy. [Fail_fast] is the default. *)

type 'a fail_fast_result = 'a list task_result
(** Homogeneous fail-fast aggregation: [Done values] preserves creation/input order; the first
    scheduler-ordered [Failed] or [Cancelled] contains no partial values. *)

type 'a collect_result = 'a task_result list
(** Homogeneous collect aggregation: one terminal result per input, in creation/input order. *)

type schemas = {
  spawn : string;
  await : string;
  cancel : string;
  yield : string;
  scope : string;
  scope_fail_fast : string;
  scope_collect : string;
}
(** Exact whitespace-normalized surface schemas frozen by SC.0. They are data for conformance
    checks, not a substitute for the checker's resolved structural typing rule. *)

val schemas : schemas
(** [schemas] returns the exact Task/Async/scope spellings indexed in [docs/concurrency.md]. *)

val default_failure_policy : failure_policy
(** [default_failure_policy] is [Fail_fast] (D50). *)

type cancellation_point =
  | Await
  | Yield
  | Routed_effect
      (** Cooperative cancellation is observed only at [Await], [Yield], and any effect operation
          routed through the scheduler. The latter includes Async operations such as spawn and
          cancel. *)

val cancellation_points : cancellation_point list
(** [cancellation_points] lists the complete v0 suspension/cancellation boundary in stable order. *)

val task_escape_code : string
(** [task_escape_code] is the frozen dynamic-defect diagnostic [E0907]. *)

val task_escape_message : string
(** [task_escape_message] is the stable diagnostic text for returning, storing beyond, or using a
    [Task] outside the scope that created it. *)

type decision = { sequence : int; runnable : task_id list; chosen : task_id }
(** A deterministic scheduler decision records its zero-based sequence, the exact FIFO runnable
    queue before selection, and the selected head. *)

val decide_round_robin : sequence:int -> task_id list -> decision option
(** [decide_round_robin ~sequence runnable] chooses the FIFO head, or [None] for an empty queue. It
    raises [Bug_invalid_task_id] when [sequence] is negative. *)

val requeue_after_suspend : runnable:task_id list -> current:task_id -> task_id list
(** [requeue_after_suspend ~runnable ~current] appends a still-runnable current task to the FIFO
    tail after tasks that were already runnable. *)

val requeue_after_spawn : runnable:task_id list -> child:task_id -> parent:task_id -> task_id list
(** [requeue_after_spawn] appends the newly created child and then the suspended parent. Thus a
    child created with no other runnable siblings is selected before its parent resumes. *)
