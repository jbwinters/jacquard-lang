(** Policy-independent ownership and cleanup for structured-concurrency scopes.

    A scope owns one {!Scheduler_core.t}, all nested scopes opened through it, and every affine
    resume token registered in those schedulers. Closing a scope recursively closes descendants and
    explicitly returns each token to a caller-provided destruction function. The module does not
    choose runnable order, deliver cooperative cancellation, or install an Async handler. *)

type handle = Scheduler_core.handle

type exit_reason =
  | Normal
  | Aborted
  | Raised  (** Why a bracket is closing. All reasons have the same mandatory cleanup semantics. *)

type metrics = { open_scopes : int; live_tasks : int; runnable_tasks : int; owned_resumes : int }
(** Recursive ownership counters. Every field is zero after the outer scope closes. *)

type ('resume, 'value) t
(** One scope in a same-run deterministic scope tree. *)

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
(** [request_cancel] records a cooperative request; delivery remains an SC.7 concern. *)

val deliver_cancel :
  ('resume, 'value) t ->
  point:Concurrency_contract.cancellation_point ->
  handle ->
  (handle list, Diag.t list) result
(** [deliver_cancel] delegates explicit frozen-point delivery to the scheduler core. *)

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
