(** Policy-independent structured-concurrency task state.

    The core owns opaque scope-local handles and at most one affine resume token per live task. It
    records which tasks become runnable, but deliberately contains no runnable queue or scheduling
    policy. *)

type handle
(** A run- and scope-owned task handle. Handles from another core are rejected with E0907. *)

type suspension =
  | Yielded
  | Awaiting of Concurrency_contract.task_id
  | Channel_sending of Channel_contract.channel_id
  | Channel_receiving of Channel_contract.channel_id
      (** Why a task is suspended. A task has at most one live await edge. *)

type ('resume, 'value) t
(** Scheduler state for one structured scope. Resume tokens and task values remain opaque to the
    core, so the same state machine can own interpreter or native-runtime continuations. *)

type ('resume, 'value) prepared_channel_suspend
(** Runtime-private proof that a checked-out task can be suspended on one exact channel. *)

type ('resume, 'value) prepared_channel_wake
(** Runtime-private proof containing a successfully mapped resume for one exact channel waiter. *)

type 'value task_view = {
  id : Concurrency_contract.task_id;
  lifecycle : Concurrency_contract.lifecycle;
  suspension : suspension option;
  result : 'value Concurrency_contract.task_result option;
  waiters : Concurrency_contract.task_id list;
  cancellation_requested : bool;
  owns_resume : bool;
}
(** Read-only invariant view of a task. Terminal tasks own no resume or waiters and have exactly one
    immutable result. *)

type 'value await_outcome =
  | Await_ready of 'value Concurrency_contract.task_result
  | Await_suspended
  | Await_deadlocked of string
      (** Result of registering an await. A terminal target is observed immediately; a live target
          suspends the waiter; a self-await or closed cycle fails the participating task(s). *)

type 'resume cancellation_boundary =
  | Boundary_continue of 'resume
  | Boundary_cancelled of { resume : 'resume; awakened : handle list }
      (** Atomic result of reaching a cancellation point with a checked-out continuation. A
          delivered or already-delivered cancellation returns that continuation for explicit
          destruction; it can never be resumed through this result. *)

val create :
  scope_path:int list -> body_resume:'resume -> (('resume, 'value) t * handle, Diag.t list) result
(** [create] opens a scheduler-owned run and scope and creates its body task at spawn index zero.
    Malformed scope paths return E0907. *)

val create_nested :
  parent:('resume, 'parent_value) t ->
  scope_path:int list ->
  body_resume:'resume ->
  (('resume, 'value) t * handle, Diag.t list) result
(** [create_nested ~parent] creates an independent scheduler state in [parent]'s opaque run. The
    caller remains responsible for choosing and owning the child scope path; no scheduling policy is
    introduced by this shared-run construction seam. *)

val scope_path : ('resume, 'value) t -> int list
(** [scope_path scheduler] returns the immutable deterministic path owned by [scheduler]. *)

val task_views : ('resume, 'value) t -> 'value task_view list
(** [task_views scheduler] returns task views in spawn order for invariant checks and scope-level
    cleanup accounting. *)

val is_closed : ('resume, 'value) t -> bool
(** [is_closed scheduler] reports whether {!close} has run. *)

val spawn : ('resume, 'value) t -> resume:'resume -> (handle, Diag.t list) result
(** [spawn scheduler ~resume] creates the next deterministic one-based child ID. Closed schedulers
    return E0908. *)

val id : ('resume, 'value) t -> handle -> (Concurrency_contract.task_id, Diag.t list) result
(** [id] validates handle ownership and returns its deterministic scheduler ID. *)

val handle_of_id :
  ('resume, 'value) t -> Concurrency_contract.task_id -> (handle, Diag.t list) result
(** [handle_of_id] resolves a scheduler-owned task identity in this exact scope. Unknown,
    cross-scope, or closed-scope identities return E0908 without changing task state. This seam lets
    scope-owned wait queues retain deterministic IDs rather than opaque runtime handles. *)

val task_run : Task_capability.t -> ('resume, 'value) t -> Concurrency_owner.t
(** Runtime-private, capability-gated access to the run owner for evaluator validation binding. *)

val task_value : Task_capability.t -> ('resume, 'value) t -> handle -> (Value.t, Diag.t list) result
(** Runtime-private, capability-gated wrapping of a validated handle. *)

val task_handle :
  Task_capability.t -> ('resume, 'value) t -> Value.t -> (handle, Diag.t list) result
(** Runtime-private, capability-gated unwrapping and exact-scope validation. *)

val validate_run_handle :
  ('resume, 'value) t -> handle -> (Concurrency_contract.task_id, Diag.t list) result
(** [validate_run_handle scheduler handle] validates only the opaque run owner and returns the
    handle's ID. It is intended for structured-scope lineage checks; ordinary task operations must
    use exact-scope validation through {!val-id}. *)

val inspect : ('resume, 'value) t -> handle -> ('value task_view, Diag.t list) result
(** [inspect] returns the current task view after validating ownership. *)

val checkout : ('resume, 'value) t -> handle -> ('resume, Diag.t list) result
(** [checkout] destructively transfers the sole resume token of a runnable task to its caller.
    Missing, suspended, terminal, or foreign tasks return diagnostics rather than raising. *)

val with_checkout :
  ('resume, 'value) t -> handle -> ('resume -> ('a, Diag.t list) result) -> ('a, Diag.t list) result
(** [with_checkout scheduler handle operation] transfers the runnable task's token to [operation].
    If [operation] returns or raises before settling that token through a scheduler transition,
    ownership is restored before control leaves the bracket. A raised physical exception is
    re-thrown with its original raw backtrace after restoration. A missing, suspended, terminal, or
    foreign task returns the same diagnostics as {!checkout}. *)

val suspend_yield : ('resume, 'value) t -> handle -> resume:'resume -> (unit, Diag.t list) result
(** [suspend_yield] returns a checked-out token and transitions Runnable to Suspended/Yielded. *)

val wake_yielded : ('resume, 'value) t -> handle -> (unit, Diag.t list) result
(** [wake_yielded] transitions a yielded task back to Runnable. It does not enqueue or run it. *)

val validate_channel_caller :
  Task_capability.t -> ('resume, 'value) t -> handle -> (unit, Diag.t list) result
(** Runtime-private preflight proving that a channel caller is live, runnable, and checked out. It
    does not mutate scheduler state. *)

val prepare_channel_suspend :
  Task_capability.t ->
  ('resume, 'value) t ->
  handle ->
  channel:Channel_contract.channel_id ->
  direction:[ `Send | `Recv ] ->
  resume:'resume ->
  (('resume, 'value) prepared_channel_suspend, Diag.t list) result
(** [prepare_channel_suspend] validates a pending channel suspension without changing task state.
    The returned proof can be committed only by trusted structured-scope code. *)

val commit_channel_suspend : Task_capability.t -> ('resume, 'value) prepared_channel_suspend -> unit
(** [commit_channel_suspend] applies one previously prepared, infallible scheduler transition. *)

val prepare_channel_wake :
  Task_capability.t ->
  ('resume, 'value) t ->
  handle ->
  channel:Channel_contract.channel_id ->
  map_resume:('resume -> ('resume, Diag.t list) result) ->
  (('resume, 'value) prepared_channel_wake, Diag.t list) result
(** [prepare_channel_wake] validates the exact suspended channel and maps its resume without
    changing scheduler state. Callback errors and exceptions therefore precede channel mutation. *)

val commit_channel_wake : Task_capability.t -> ('resume, 'value) prepared_channel_wake -> unit
(** [commit_channel_wake] makes one previously prepared waiter runnable without further failure. *)

val suspend_channel :
  ('resume, 'value) t ->
  handle ->
  channel:Channel_contract.channel_id ->
  direction:[ `Send | `Recv ] ->
  resume:'resume ->
  (unit, Diag.t list) result
(** [suspend_channel] atomically returns a checked-out affine resume to its task entry and records
    one exact channel wait. Invalid lifecycle state leaves ownership unchanged and returns E0908. *)

val wake_channel_with :
  ('resume, 'value) t ->
  handle ->
  channel:Channel_contract.channel_id ->
  map_resume:('resume -> ('resume, Diag.t list) result) ->
  (unit, Diag.t list) result
(** [wake_channel_with] validates an exact channel suspension, transforms the scheduler-owned resume
    with its operation result, and makes the task runnable as one transition. If validation,
    [map_resume], or a raised callback fails, the task remains suspended with its original resume;
    the callback exception propagates. *)

val await :
  ('resume, 'value) t ->
  waiter:handle ->
  target:handle ->
  resume:'resume ->
  ('value await_outcome * handle list, Diag.t list) result
(** [await] returns a checked-out waiter token. Waiters are registered once in call order. The
    returned handles are tasks made runnable by deadlock failure cleanup, in registration order. *)

val complete : ('resume, 'value) t -> handle -> 'value -> (handle list, Diag.t list) result
(** [complete] terminalizes a checked-out runnable task and wakes every registered waiter in
    registration order. The result is immutable. *)

val fail : ('resume, 'value) t -> handle -> string -> (handle list, Diag.t list) result
(** [fail] is the failure counterpart of {!complete}. *)

val request_cancel : ('resume, 'value) t -> handle -> (unit, Diag.t list) result
(** [request_cancel] records a cooperative request. Repeated requests and terminal targets are
    idempotent. *)

val cancellation_pending : ('resume, 'value) t -> handle -> (bool, Diag.t list) result
(** [cancellation_pending] reports whether first delivery would terminalize this task. It is a
    read-only preflight used before removing a channel waiter. *)

val deliver_cancel :
  ('resume, 'value) t ->
  point:Concurrency_contract.cancellation_point ->
  handle ->
  (handle list * 'resume list, Diag.t list) result
(** [deliver_cancel] terminalizes a requested live task at a frozen cancellation point and wakes its
    waiters. On first delivery it transfers every scheduler-owned resume removed from the target to
    the caller for destruction. Duplicate delivery and terminal targets return empty lists. No
    resume is discarded inside the core. *)

val cancellation_boundary :
  ('resume, 'value) t ->
  point:Concurrency_contract.cancellation_point ->
  handle ->
  resume:'resume ->
  ('resume cancellation_boundary, Diag.t list) result
(** [cancellation_boundary scheduler ~point task ~resume] atomically checks a checked-out runnable
    task before a suspension or routed effect. A pending request terminalizes the task exactly once;
    an already-cancelled task also refuses the stale continuation. Suspended, completed, and failed
    tasks return E0908. *)

val close : ('resume, 'value) t -> 'resume list
(** [close] cancels all unfinished tasks, removes every wait edge, and transfers all still-owned
    resume tokens to the caller for explicit destruction. Repeated close returns [[]]. *)
