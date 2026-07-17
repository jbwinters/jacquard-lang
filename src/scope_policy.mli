(** Deterministic homogeneous scope-result policies over {!Structured_scope}.

    This layer records terminal observations supplied in scheduler decision order. It never chooses
    a runnable task, consults host timing, resumes a continuation, or installs an Async handler. *)

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

val take_awakened : ('resume, 'value) t -> Structured_scope.handle list
(** [take_awakened controller] returns and clears every waiter made runnable by fail-fast sibling
    cancellation. Handles preserve sibling input order and each target's waiter-registration order.
    A scheduler must drain this handoff after [record_terminal] before choosing its next task. *)

val record_terminal :
  ('resume, 'value) t ->
  decision:int ->
  Structured_scope.handle ->
  drop:('resume -> unit) ->
  (unit, Diag.t list) result
(** [record_terminal controller ~decision child ~drop] records one terminal result. Decisions must
    be non-negative and strictly increase. An unregistered same-scope child, a duplicate terminal
    observation, or a nonterminal observation returns E0908. Foreign-run, foreign-scope, and stale
    handles retain E0907 from {!Structured_scope}.

    Once a valid terminal state is inspected, its decision and result are committed before any
    fail-fast cancellation is attempted; cancellation diagnostics or an exception from [drop] do not
    roll that observation back. Under [Fail_fast], the first observed [Failed] or [Cancelled]
    freezes the returned non-success and requests cancellation of every unfinished sibling in input
    order. Already-suspended siblings are delivered immediately through
    {!Structured_scope.deliver_cancel}, which passes their resumes to [drop]. Runnable siblings
    retain an idempotent request until their next cancellation boundary. Every sibling is attempted
    even if [drop] raises; the first such physical exception is re-raised with its original
    backtrace only after all sibling cleanup has been attempted. The policy-local wrapper lets
    {!Structured_scope.deliver_cancel} return normally after a user [drop] failure, so waiters from
    that same delivery are buffered for {!take_awakened}. Waiters from successful earlier or later
    deliveries are buffered as well. [Collect] never requests sibling cancellation. *)

val finish : ('resume, 'value) t -> ('value aggregate, Diag.t list) result
(** [finish controller] succeeds only after every child has been observed terminal. Fail-fast
    returns the first scheduler-decision-ordered [Failed] or [Cancelled], otherwise [Done values] in
    input order. Collect returns every terminal result in input order. Calling it early returns
    E0908. *)
