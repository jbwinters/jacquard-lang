(** Internal C4-preparatory host-readiness lifecycle seam.

    This module is deliberately not a Jacquard effect handler, CLI surface, scheduler policy, or
    portability promise. It owns duplicated Unix descriptors only while a task is suspended, and
    uses the existing runtime capability and scheduler task identity. Callers retain ownership of
    the descriptor supplied to {!register}; the duplicated registration descriptor is released
    exactly once on wake, cancellation, or {!shutdown}. This is an OCaml runtime-preparatory API,
    not a Jacquard language or CLI interface. It is currently exported by the wrapped library for
    focused lifecycle tests; that export is not a supported host-I/O product contract. It installs
    no language effect and cannot add, remove, or launder a Jacquard capability row. A future
    handler must still bind this lifecycle to {!Structured_scope}, charge every child world effect
    to its parent row, and define its public platform and trace contracts. *)

type registration = { id : int; task : Concurrency_contract.task_id }
(** A deterministic readiness decision. [id] is local to one registry and [task] is the existing
    scheduler identity. It is a replay token, not an unforgeable capability: an equivalent fresh
    scheduler run deliberately accepts the same task identity and local registration ordinal. *)

type ('resume, 'value) t
(** A registry owned by exactly one scheduler core. *)

type wake_result = { awakened : Scheduler_core.handle list; cleanup_diagnostics : Diag.t list }
(** A completed scheduler handoff. [cleanup_diagnostics] reports descriptor-retirement failures
    without hiding tasks that already became runnable. Callers must enqueue every [awakened] handle
    before surfacing those diagnostics. *)

type poll_result = {
  awakened : Scheduler_core.handle list;
  decisions : registration list;
  cleanup_diagnostics : Diag.t list;
}
(** The ordered result of one non-blocking live poll. Decisions are in registration order, never
    host select-set order. Cleanup diagnostics never suppress already-completed wakeups. *)

type descriptor_ops = {
  duplicate : Unix.file_descr -> Unix.file_descr;
  close : Unix.file_descr -> unit;
  poll_readable : Unix.file_descr list -> Unix.file_descr list;
}
(** Injectable descriptor boundary for hermetic lifecycle tests. Production {!create} uses
    close-on-exec duplication, [Unix.close], and one zero-time [Unix.select] read poll. *)

val create :
  ?descriptor_ops:descriptor_ops -> ('resume, 'value) Scheduler_core.t -> ('resume, 'value) t
(** [create scheduler] transfers responsibility for closing [scheduler] to a new empty opt-in
    registry. The caller must route readiness cancellation through the registry and must not close
    or mutate the scheduler behind it. Creation does not change scheduler policy or inspect
    descriptors. [descriptor_ops] exists only to prove descriptor ownership and replay isolation;
    callers constructing production registries should omit it. *)

val register :
  ('resume, 'value) t ->
  task:Scheduler_core.handle ->
  descriptor:Unix.file_descr ->
  resume:'resume ->
  (registration, Diag.t list) result
(** [register registry ~task ~descriptor ~resume] duplicates [descriptor], transfers [resume] from
    its checked-out task into an internal readiness suspension, and returns the recorded decision.
    Duplication or lifecycle refusal returns E0908 without suspending the task or taking ownership
    of the caller's descriptor. A task can hold at most one registration because it is suspended. *)

val poll_live : ('resume, 'value) t -> (poll_result, Diag.t list) result
(** [poll_live registry] performs one non-blocking Unix read-readiness poll and wakes the matching
    suspended tasks in registration order. It is the only operation in this module that polls host
    descriptors. Closed registries return E0908. *)

val replay :
  ('resume, 'value) t -> registrations:registration list -> (wake_result, Diag.t list) result
(** [replay registry ~registrations] strictly consumes the supplied recorded decisions in order and
    wakes only their exact suspended tasks. It never polls, reads, or writes live descriptors;
    retirement may close the registry-owned duplicate as required by the lifecycle contract. Stale
    or duplicate decisions return E0908. Equivalent fresh scheduler runs may replay the same task
    identity and ordinal; callers must authenticate trace provenance outside this internal seam.
    Descriptor-retirement failures are returned in [cleanup_diagnostics] so they cannot discard
    handles whose scheduler transition already completed. *)

val cancel :
  ('resume, 'value) t ->
  Scheduler_core.handle ->
  drop:('resume -> unit) ->
  (wake_result, Diag.t list) result
(** [cancel registry task ~drop] requests and delivers routed-effect cancellation for [task]. A
    matching registration is deregistered and its duplicate closed before [drop] receives the task's
    transferred resume. Repeated cancellation is idempotent and never closes twice. With active
    registrations this is the required cancellation path: direct [Scheduler_core] cancellation is
    unsupported because it bypasses descriptor teardown. Descriptor-retirement failures are returned
    alongside, rather than instead of, already-awakened handles. *)

val reconcile : ('resume, 'value) t -> (unit, Diag.t list) result
(** [reconcile registry] defensively retires registrations whose tasks no longer have their exact
    readiness suspension because of an unsupported direct scheduler transition. It never polls.
    Direct callers remain responsible for dropping any resume transferred by that lower-level
    transition. *)

val shutdown : ('resume, 'value) t -> drop:('resume -> unit) -> (unit, Diag.t list) result
(** [shutdown registry ~drop] releases every remaining duplicated descriptor and closes the owned
    scheduler core, transferring each remaining resume once to [drop]. Repeated shutdown is a no-op.
    Cleanup continues after a descriptor-close failure and reports E0908 deterministically. *)

val registration_count : ('resume, 'value) t -> int
(** [registration_count] returns the number of currently owned duplicated descriptors. *)
