(** Policy-independent ownership and cleanup for structured-concurrency scopes.

    A scope owns one {!Scheduler_core.t}, all nested scopes opened through it, and every affine
    resume token registered in those schedulers. Closing a scope recursively closes descendants and
    explicitly returns each token to a caller-provided destruction function. The module does not
    choose runnable order or install an Async handler. Cooperative cancellation is delivered only
    through the explicit suspension/routed-effect boundaries below. *)

type handle = Scheduler_core.handle

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

val inspect : ('resume, 'value) t -> handle -> ('value Scheduler_core.task_view, Diag.t list) result
(** [inspect scope handle] returns the lifecycle view for an open scope. *)

val checkout : ('resume, 'value) t -> handle -> ('resume, Diag.t list) result
(** [checkout scope handle] transfers its runnable resume token. *)

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
    terminal delivery call [drop] zero times. *)

val at_cancellation_point :
  ('resume, 'value) t ->
  point:Concurrency_contract.cancellation_point ->
  task:handle ->
  resume:'resume ->
  drop:('resume -> unit) ->
  ('resume boundary_outcome, Diag.t list) result
(** [at_cancellation_point] checks before any boundary action. First delivery terminalizes the task,
    wakes waiters, and explicitly destroys [resume]. Already-cancelled tasks also destroy a stale
    [resume], ensuring no post-cancellation user step can be recovered. *)

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
    their next boundary. Completed and duplicate target requests are no-ops. *)

val close :
  ('resume, 'value) t ->
  reason:exit_reason ->
  escaping:handle list ->
  drop:('resume -> unit) ->
  (unit, Diag.t list) result
(** [close scope ~reason ~escaping ~drop] recursively closes descendants, cancels unfinished tasks,
    and calls [drop] exactly once for every still-owned resume. A returned or stored handle created
    in this scope tree returns E0907, but cleanup completes before the diagnostic is returned.
    Repeated close is harmless. *)

val protect :
  ('resume, 'value) t ->
  drop:('resume -> unit) ->
  escapes:('a -> handle list) ->
  (('resume, 'value) t -> ('a, Diag.t list) result) ->
  ('a, Diag.t list) result
(** [protect scope ~drop ~escapes body] is the explicit bracket idiom. It closes normally after
    [Ok], aborts after [Error], and closes before re-raising a host exception. Jacquard does not
    rely on language finalizers for scope cleanup. *)

val metrics : ('resume, 'value) t -> metrics
(** [metrics scope] recursively counts open scopes, nonterminal tasks, runnable tasks, and owned
    resume tokens. *)
