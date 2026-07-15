(** Guarded CPS evaluator API. Context storage, validation caches, and unchecked machine drivers are
    intentionally abstract. *)

type ctx
(** Evaluator configuration and mutable runtime caches. The representation is sealed so clients
    cannot forge memo trust or mutate recovery-validation state. *)

val make_ctx : Store.t -> ctx
(** [make_ctx store] creates an evaluator over [store] with empty native registrations and caches.
*)

val store : ctx -> Store.t
(** [store ctx] returns the backing store used for declaration and name lookup. *)

val validate_task_value :
  ctx -> scope_path:int list -> Value.t -> (Concurrency_contract.task_id, Diag.t list) result
(** [validate_task_value ctx ~scope_path value] accepts a Task only in its creating evaluator run
    and exact structured scope. Malformed, non-Task, stale, or foreign values return E0907. *)

val reject_task_escape : ctx -> scope_path:int list -> Value.t -> (unit, Diag.t list) result
(** [reject_task_escape ctx ~scope_path value] scans the complete reachable runtime-value graph and
    rejects with E0907 when a Task created in [scope_path] or one of its descendants is reachable.
    Tuples, constructors, closure cells, resumptions, and cyclic environments are handled. Tasks
    owned by an enclosing scope remain valid. *)

val register_builtin : ctx -> Hash.t -> Value.t -> unit
(** [register_builtin ctx hash value] installs a native implementation for a term. Recovery-marked
    values are rejected with the evaluator's runtime exception; custom callbacks are guarded before
    and after every invocation. *)

val register_root_handler :
  ctx -> Hash.t -> (Value.t list -> (Value.t, Runtime_err.t) result) -> unit
(** [register_root_handler ctx op handler] installs an explicitly granted root operation handler.
    Its arguments, continuation mutation, and result are guarded at dispatch; callback failures are
    returned as runtime errors. *)

val set_coverage_tracking : ctx -> bool -> unit
(** [set_coverage_tracking ctx enabled] enables or disables term-reference coverage bookkeeping. *)

val with_fresh_coverage : ctx -> (unit -> 'a) -> 'a * Hash.t list
(** [with_fresh_coverage ctx f] runs [f] with isolated coverage, merges it into the enclosing set,
    restores the enclosing set even if [f] raises, and returns [f]'s result plus covered hashes. *)

val match_pat : Value.t -> Kernel.pat -> Value.env -> Value.env option
(** [match_pat value pattern env] returns [env] extended with fresh binding cells when the resolved
    pattern matches, or [None] on an ordinary mismatch. An unresolved constructor pattern raises the
    evaluator's internal runtime exception. *)

type state =
  | SEval of Value.scope * Kernel.expr * Value.kont
  | SApply of Value.t * Value.kont
      (** Explicit evaluator machine state. Constructors remain public for inference and handler
          drivers; all public runners validate reachable recovery markers before execution. *)

val run_expr : ctx -> Kernel.expr -> (Value.t, Runtime_err.t) result
(** [run_expr ctx expression] validates and evaluates a resolved expression. Language/runtime
    failures are returned; malformed store invariants may raise an internal [Bug_*] exception. *)

type captured_kont
(** A mode-aware root continuation. Multi captures are reusable by {!resume_captured_state}; Once
    captures retain one shared affine budget. Captures are bound to their originating evaluator
    context. The representation is sealed so a Once capture cannot be converted back into raw
    frames. *)

type capture =
  | CValue of Value.t
  | COp of { op : Hash.t; name : string; args : Value.t list; kont : captured_kont }
      (** A terminal value or an unhandled root operation with its mode-aware continuation. *)

val run_state_capturing : ctx -> state -> (capture, Runtime_err.t) result
(** [run_state_capturing ctx state] validates [state], then runs to a value or the first unhandled
    root operation. Runtime failures are returned. *)

val resume_captured_state : ctx -> captured_kont -> Value.t -> (state, Runtime_err.t) result
(** [resume_captured_state ctx kont value] validates [value] and constructs a resumed state. A Multi
    capture may be resumed repeatedly; a second use of a Once capture returns E0906. Resuming under
    a context other than the capturing context returns E0907 before consuming a Once budget. *)

type once_capture =
  | OCValue of Value.t
  | OCOp of { op : Hash.t; name : string; args : Value.t list; resume : Value.t }
      (** A terminal value or root operation whose actual continuation is already sealed as one
          opaque, originating-context-bound once-resumption instance. *)

val run_state_capturing_once : ctx -> state -> (once_capture, Runtime_err.t) result
(** [run_state_capturing_once ctx state] validates and runs [state]. A captured root continuation is
    sealed before it crosses the API, preventing clients from extracting frames and minting another
    budget for the same captured instance. Calling its resume value under another context returns
    E0907 before consuming the Once budget. *)

type validated_state
(** An unforgeable state accepted by the reusable inference driver and bound to the exact evaluator
    context that validated it. *)

type validated_captured_kont
(** An unforgeable, mode-aware continuation captured from a validated execution. *)

type validated_capture =
  | VCValue of Value.t
  | VCOp of { op : Hash.t; name : string; args : Value.t list; kont : validated_captured_kont }
      (** A terminal value or root operation produced from a validated state. *)

val validate_state_once : ctx -> state -> (validated_state, Runtime_err.t) result
(** [validate_state_once ctx state] scans a complete initial state and snapshots its mutable runtime
    graph. Recovery markers and malformed runtime values are returned as errors. *)

val fresh_validated_state : ctx -> validated_state -> validated_state
(** [fresh_validated_state ctx initial] restores the mutable graph captured by [validate_state_once]
    and evaluator-owned memo snapshots for one independent execution. Affine resumption consumption
    is deliberately monotonic and is never restored: reusing the same captured instance still fails.
    A resumed state has no initial cell snapshot and is returned unchanged. A foreign-context state
    is returned without restoring either graph and remains foreign for the guarded runner. *)

val run_validated_state_capturing :
  ctx -> validated_state -> (validated_capture, Runtime_err.t) result
(** [run_validated_state_capturing ctx state] runs a sealed state without rescanning immutable
    syntax when [ctx] is its validating context. Cross-context use returns E0907; memo/native
    results remain guarded and runtime failures are returned. *)

val resume_validated_state :
  ctx -> validated_captured_kont -> Value.t -> (validated_state, Runtime_err.t) result
(** [resume_validated_state ctx kont value] validates [value] and seals delivery to [kont]. Recovery
    markers, malformed values, and a context other than the capturing context are returned as
    runtime errors. *)

val resume_state : Value.frame list -> Value.t -> state
(** [resume_state kont value] constructs a guarded state that delivers [value] to [kont]. *)

val apply_state : ctx -> Value.t -> Value.t list -> state
(** [apply_state ctx fn args] constructs the initial state for a direct uncurried call. Invalid
    callable shape or arity raises the evaluator's internal runtime exception; runners return it. *)

val expr_state : Kernel.expr -> state
(** [expr_state expression] constructs an empty-scope initial state for [expression]. *)

val call : ctx -> Value.t -> Value.t list -> (Value.t, Runtime_err.t) result
(** [call ctx fn args] validates and invokes an already evaluated value. Arity, type, effect, and
    callback failures are returned as runtime errors. *)
