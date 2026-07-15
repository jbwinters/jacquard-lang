(** Deterministic homogeneous scope-result policies over {!Structured_scope}.

    This layer records terminal observations supplied in lexicographic scheduler-decision and stable
    sub-observation order. It never chooses a runnable task, consults host timing, resumes a
    continuation, or installs an Async handler. *)

type ('resume, 'value) t
(** A controller for one ordered set of same-scope child handles. The input order is the result
    order for both policies. *)

type 'value aggregate =
  | Fail_fast_result of 'value Concurrency_contract.fail_fast_result
  | Collect_result of 'value Concurrency_contract.collect_result
      (** A completed homogeneous scope result. [Fail_fast_result] contains no partial values. *)

val create :
  ?policy:Concurrency_contract.failure_policy ->
  ('resume, 'value) Structured_scope.t ->
  children:Structured_scope.handle list ->
  (('resume, 'value) t, Diag.t list) result
(** [create scope ~children] validates every handle against [scope]. Foreign-run, foreign-scope, and
    stale handles retain the E0907 handle-lifetime diagnostic; duplicate same-scope children return
    E0908. The default policy is {!Concurrency_contract.default_failure_policy}. An empty child list
    is valid and immediately finishable. *)

val policy : ('resume, 'value) t -> Concurrency_contract.failure_policy
(** [policy controller] returns its immutable policy. *)

val register_child : ('resume, 'value) t -> Structured_scope.handle -> (unit, Diag.t list) result
(** [register_child controller handle] appends one newly spawned same-scope child to the policy's
    creation-ordered result set. Duplicate, foreign, or stale registration is rejected before
    mutating the controller. *)

val record_terminal :
  ('resume, 'value) t ->
  decision:int ->
  ?ordinal:int ->
  Structured_scope.handle ->
  drop:('resume -> unit) ->
  (unit, Diag.t list) result
(** [record_terminal controller ~decision ~ordinal child ~drop] records one terminal result under
    the lexicographic observation key [(decision, ordinal)]. Both components must be non-negative,
    and keys must strictly increase. [ordinal] defaults to zero for schedulers that observe at most
    one terminal per decision. An unregistered same-scope child, a duplicate terminal observation,
    or a nonterminal observation returns E0908. Foreign-run, foreign-scope, and stale handles retain
    E0907 from {!Structured_scope}.

    Once a valid terminal state is inspected, its decision and result are committed before any
    fail-fast cancellation is attempted; cancellation diagnostics or an exception from [drop] do not
    roll that observation back. Under [Fail_fast], the first observed [Failed] or [Cancelled]
    freezes the returned non-success and requests cancellation of every unfinished sibling in input
    order. Already-suspended siblings are delivered immediately through
    {!Structured_scope.deliver_cancel}, which passes their resumes to [drop]. Runnable siblings
    retain an idempotent request until their next cancellation boundary. Every sibling is attempted
    even if [drop] raises; the first such exception is re-raised only after all sibling cleanup has
    been attempted. [Collect] never requests sibling cancellation. *)

val take_awakened : ('resume, 'value) t -> Structured_scope.handle list
(** [take_awakened controller] returns and clears waiters awakened by policy-triggered immediate
    cancellation. The scheduler appends them to its FIFO queue after the current transition. *)

val finish : ('resume, 'value) t -> ('value aggregate, Diag.t list) result
(** [finish controller] succeeds only after every child has been observed terminal. Fail-fast
    returns the first lexicographically scheduler-observed [Failed] or [Cancelled], otherwise
    [Done values] in input order. Collect returns every terminal result in input order. Calling it
    early returns E0908. *)
