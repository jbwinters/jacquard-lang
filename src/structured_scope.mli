(** Policy-independent ownership and cleanup for structured-concurrency scopes.

    A scope owns one {!Scheduler_core.t}, all nested scopes opened through it, and every affine
    resume token registered in those schedulers. Closing a scope recursively closes descendants and
    explicitly returns each token to a caller-provided destruction function. The module does not
    choose runnable order or install an Async handler. Cooperative cancellation is delivered only
    through the explicit suspension/routed-effect boundaries below. Cancellation terminalizes and
    transfers continuation ownership before invoking a supplied [drop] callback. Destruction
    callbacks must normally not raise. If one does, its exception propagates, but the scheduler does
    not re-own or transfer that continuation again. *)

type handle = Scheduler_core.handle

type channel_handle
(** Opaque run- and exact-scope-owned channel handle. It has no public constructor, equality,
    rendering, or serialization operation. *)

type exit_reason =
  | Normal
  | Aborted
  | Raised  (** Why a bracket is closing. All reasons have the same mandatory cleanup semantics. *)

type metrics = { open_scopes : int; live_tasks : int; runnable_tasks : int; owned_resumes : int }
(** Recursive ownership counters. Every field is zero after the outer scope closes. *)

type ('resume, 'value) t
(** One scope in a same-run deterministic scope tree. *)

type 'resume boundary_outcome =
  | Boundary_continue of 'resume
  | Boundary_cancelled of handle list
      (** Result of a cancellation-point check. The continuation is returned only when execution may
          continue; cancellation destroys it through the supplied [drop] callback. *)

type 'value cooperative_await_outcome =
  | Await_performed of 'value Scheduler_core.await_outcome * handle list
  | Await_cancelled of handle list

type yield_outcome = Yield_suspended | Yield_cancelled of handle list

type ('resume, 'value) routed_effect_outcome =
  | Effect_routed of { resume : 'resume; result : ('value, Diag.t list) result }
  | Effect_cancelled of handle list

type 'resume cancel_outcome =
  | Cancel_continues of { resume : 'resume; awakened : handle list }
  | Cancel_caller_cancelled of handle list

type channel_open_outcome =
  | Channel_opened of channel_handle
  | Channel_invalid_capacity of int
      (** Typed result of [channel.open]. Rejected negative capacities allocate no channel identity.
      *)

type 'value channel_result =
  | Channel_send_ok
  | Channel_recv_ok of 'value
  | Channel_closed
      (** Scheduler-internal result used to transform a channel operation's affine resume. *)

type 'resume channel_transition =
  | Channel_continues of { resume : 'resume; awakened : handle list }
  | Channel_suspended
      (** A channel operation either leaves its caller continuation checked out and reports
          counterpart wakeups in required FIFO order, or returns that continuation to the caller's
          scheduler entry as one channel suspension. *)

val create : body_resume:'resume -> (('resume, 'value) t * handle, Diag.t list) result
(** [create] opens root scope path [[0]] and creates its body task at spawn index zero. *)

val nest :
  ('resume, 'value) t -> body_resume:'resume -> (('resume, 'value) t * handle, Diag.t list) result
(** [nest parent] opens the next one-based child path under [parent]. A closed parent returns E0907.
*)

val scope_path : ('resume, 'value) t -> int list
(** [scope_path scope] returns its immutable deterministic lineage. *)

val spawn : ('resume, 'value) t -> resume:'resume -> (handle, Diag.t list) result
(** [spawn scope] registers a child task and its sole resume token. Closed scopes return E0907. *)

val id : ('resume, 'value) t -> handle -> (Concurrency_contract.task_id, Diag.t list) result
(** [id scope handle] validates exact open-scope ownership. *)

val with_eval_task_context :
  Task_capability.t -> Eval.ctx -> ('resume, 'value) t -> (unit -> 'a) -> 'a
(** Runtime-private binding of evaluator Task validation to this scope's fresh run and path. *)

val task_value : Task_capability.t -> ('resume, 'value) t -> handle -> (Value.t, Diag.t list) result
(** Runtime-private Task wrapping, gated by the unforgeable scheduler capability. *)

val task_handle :
  Task_capability.t -> ('resume, 'value) t -> Value.t -> (handle, Diag.t list) result
(** Runtime-private Task unwrapping, gated by the unforgeable scheduler capability. *)

val channel_open : ('resume, 'value) t -> capacity:int -> (channel_open_outcome, Diag.t list) result
(** [channel_open] allocates the next zero-based successful-open identity in this exact open scope.
    A negative capacity returns [Channel_invalid_capacity] before identity allocation. A closed
    scope returns E0907 and native ChannelId exhaustion returns E0908 without allocation. Trusted
    scheduler code must establish the routed cancellation boundary before calling this lower seam.
*)

val channel_value :
  Task_capability.t -> ('resume, 'value) t -> channel_handle -> (Value.t, Diag.t list) result
(** Runtime-private wrapping of a validated live exact-scope channel handle. The unforgeable
    scheduler capability prevents ordinary OCaml clients from manufacturing the opaque carrier. *)

val channel_handle :
  Task_capability.t -> ('resume, 'value) t -> Value.t -> (channel_handle, Diag.t list) result
(** Runtime-private unwrapping of a [Value.VChannel]. Non-channel, stale, foreign-run, and
    cross-scope values return E0907 without exposing channel state. *)

val channel_send :
  ('resume, 'value) t ->
  task:handle ->
  channel:channel_handle ->
  resume:'resume ->
  value:'value ->
  map_resume:('resume -> 'value channel_result -> 'resume) ->
  ('resume channel_transition, Diag.t list) result
(** [channel_send] requires a cancellation-checked, checked-out caller continuation. It validates
    exact live run/scope ownership and preflights all resume mappings before channel mutation, then
    commits FIFO handoff, buffering, or scheduler-owned suspension without another failure point.
    Invalid handles or task lifecycle return diagnostics without consuming the continuation or
    payload. *)

val channel_recv :
  ('resume, 'value) t ->
  task:handle ->
  channel:channel_handle ->
  resume:'resume ->
  map_resume:('resume -> 'value channel_result -> 'resume) ->
  ('resume channel_transition, Diag.t list) result
(** [channel_recv] is the receive counterpart of {!channel_send}. Buffered values are FIFO and one
    oldest blocked sender is promoted or rendezvous-completed before the receiver continues. *)

val channel_close :
  ('resume, 'value) t ->
  task:handle ->
  channel:channel_handle ->
  resume:'resume ->
  map_resume:('resume -> 'value channel_result -> 'resume) ->
  map_closer:('resume -> 'resume) ->
  ('resume channel_transition, Diag.t list) result
(** [channel_close] preserves accepted buffered values, wakes rejected senders and drained receivers
    FIFO before the closer, and is idempotent. [map_resume] supplies typed closed results to waiters
    while [map_closer] supplies the close operation's unit result. Exact ownership and every waiter
    mapping are prepared before state or continuation consumption, so a later invalid waiter cannot
    partially close the channel. *)

val inspect : ('resume, 'value) t -> handle -> ('value Scheduler_core.task_view, Diag.t list) result
(** [inspect scope handle] returns the lifecycle view for an open scope. *)

val checkout : ('resume, 'value) t -> handle -> ('resume, Diag.t list) result
(** [checkout scope handle] transfers its runnable resume token. *)

val with_checkout :
  ('resume, 'value) t -> handle -> ('resume -> ('a, Diag.t list) result) -> ('a, Diag.t list) result
(** [with_checkout scope handle operation] brackets a runnable-token transfer. If [operation]
    returns or raises before a lifecycle transition settles the token, the scope owns it again
    before control leaves the bracket. A raised physical exception retains its original raw
    backtrace. Closed scopes and invalid handles return diagnostics. *)

val suspend_yield : ('resume, 'value) t -> handle -> resume:'resume -> (unit, Diag.t list) result
(** [suspend_yield] returns a checked-out token and records a yielded suspension. *)

val wake_yielded : ('resume, 'value) t -> handle -> (unit, Diag.t list) result
(** [wake_yielded] makes a yielded task runnable without choosing queue order. *)

val await :
  ('resume, 'value) t ->
  waiter:handle ->
  target:handle ->
  resume:'resume ->
  ('value Scheduler_core.await_outcome * handle list, Diag.t list) result
(** [await] registers a same-scope join using the policy-independent scheduler core. *)

val complete : ('resume, 'value) t -> handle -> 'value -> (handle list, Diag.t list) result
(** [complete] terminalizes a checked-out runnable task. *)

val fail : ('resume, 'value) t -> handle -> string -> (handle list, Diag.t list) result
(** [fail] terminalizes a checked-out runnable task with a stable failure message. *)

val request_cancel : ('resume, 'value) t -> handle -> (unit, Diag.t list) result
(** [request_cancel] records a cooperative request. Repeated and terminal-target requests are
    deterministic no-ops. *)

val deliver_cancel :
  ('resume, 'value) t ->
  point:Concurrency_contract.cancellation_point ->
  handle ->
  drop:('resume -> unit) ->
  (handle list, Diag.t list) result
(** [deliver_cancel] delegates frozen-point delivery to the scheduler core and passes every removed
    scheduler-owned resume exactly once to [drop] before returning awakened handles. Duplicate and
    terminal delivery call [drop] zero times. The target is terminal and its resume has transferred
    before [drop] runs. If [drop] raises, the exception propagates; later duplicate delivery neither
    re-owns nor re-drops that resume. *)

val at_cancellation_point :
  ('resume, 'value) t ->
  point:Concurrency_contract.cancellation_point ->
  task:handle ->
  resume:'resume ->
  drop:('resume -> unit) ->
  ('resume boundary_outcome, Diag.t list) result
(** [at_cancellation_point] checks before any boundary action. First delivery terminalizes the task,
    wakes waiters, and explicitly destroys [resume]. Already-cancelled tasks also destroy a stale
    [resume], ensuring no post-cancellation user step can be recovered. The handoff is consumed even
    if [drop] raises: the exception propagates and the task remains terminal. *)

val await_cooperatively :
  ('resume, 'value) t ->
  waiter:handle ->
  target:handle ->
  resume:'resume ->
  drop:('resume -> unit) ->
  ('value cooperative_await_outcome, Diag.t list) result
(** [await_cooperatively] delivers a pending request before observing the target or registering a
    waiter. *)

val yield_cooperatively :
  ('resume, 'value) t ->
  task:handle ->
  resume:'resume ->
  drop:('resume -> unit) ->
  (yield_outcome, Diag.t list) result
(** [yield_cooperatively] delivers before recording a yielded suspension. *)

val route_effect :
  ('resume, 'task_value) t ->
  task:handle ->
  resume:'resume ->
  drop:('resume -> unit) ->
  action:(unit -> ('value, Diag.t list) result) ->
  (('resume, 'value) routed_effect_outcome, Diag.t list) result
(** [route_effect] checks before invoking one scheduler-routed Async or world operation. On
    cancellation [action] is never called. Otherwise its result, including a fault diagnostic, is
    returned beside the still-caller-owned continuation; this layer does not schedule or resume it.
*)

val cancel :
  ('resume, 'value) t ->
  caller:handle ->
  target:handle ->
  resume:'resume ->
  drop:('resume -> unit) ->
  ('resume cancel_outcome, Diag.t list) result
(** [cancel] implements the routed [async.cancel] boundary. A pre-cancelled caller performs no
    target request. Self-cancel is delivered at this same routed-effect point. A suspended target is
    delivered immediately at its existing await/yield point; runnable targets observe the request at
    their next boundary. Completed and duplicate target requests are no-ops. Immediate delivery
    terminalizes and transfers the target resume before calling [drop]. If [drop] raises, the
    exception propagates without restoring that resume or making a later duplicate call drop it. *)

val close :
  ('resume, 'value) t ->
  reason:exit_reason ->
  escaping:handle list ->
  drop:('resume -> unit) ->
  (unit, Diag.t list) result
(** [close scope ~reason ~escaping ~drop] recursively closes descendants, cancels unfinished tasks,
    and calls [drop] exactly once for every still-owned resume. A returned or stored handle created
    in this scope tree returns E0907, but cleanup completes before the diagnostic is returned.
    Repeated close is harmless. If one or more [drop] calls raise, cleanup still attempts every
    resume and re-raises the first cleanup exception. *)

val protect :
  ('resume, 'value) t ->
  drop:('resume -> unit) ->
  escapes:('a -> handle list) ->
  (('resume, 'value) t -> ('a, Diag.t list) result) ->
  ('a, Diag.t list) result
(** [protect scope ~drop ~escapes body] is the explicit bracket idiom. It closes normally after
    [Ok], aborts after [Error], and closes before re-raising a host exception. Cleanup always
    attempts every still-owned resume. After a normal [Ok], a cleanup exception propagates. After a
    body [Error], the original diagnostics take precedence over cleanup exceptions. After a host
    exception, the original exception and raw backtrace take precedence. Re-raising may append OCaml
    re-raise frames, but the original backtrace remains its prefix. Jacquard does not rely on
    language finalizers for scope cleanup. *)

val metrics : ('resume, 'value) t -> metrics
(** [metrics scope] recursively counts open scopes, nonterminal tasks, runnable tasks, and owned
    resume tokens. *)

val channel_deadlocked : ('resume, 'value) t -> bool
(** [channel_deadlocked] holds when every remaining live task in this scope tree is suspended and at
    least one waits on a Channel. It is a read-only empty-runnable-queue diagnostic; it never closes
    a channel or changes task state. *)
