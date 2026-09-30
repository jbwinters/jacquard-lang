(** Typed observation of facts at the evaluator root (RF.3, docs/observation-boundary.md).

    The evaluator produces one ordered event stream per observed extent. Versioned projections, such
    as [run-transcript-v1], are built from these events; the events themselves are not a persisted
    format. Schedule choices, host-owned facts and governance events are separate carriers and are
    never produced here. *)

type event =
  | Operation of { operation : Hash.t; name : string; arguments : Value.t list }
      (** An operation crossed every language handler and reached the root, before any root handler
          ran or a driver captured it. [name] is display-only; [operation] is its identity. *)
  | Output of { operation : Hash.t; bytes : string }
      (** A trusted root adapter accepted [bytes] for [operation] (today only Console print). *)
  | Result of { operation : Hash.t; result : (Value.t, Runtime_err.t) result }
      (** A granted root handler for [operation] returned. An operation captured by a driver instead
          of dispatched has no [Result]. *)

val operation : event -> Hash.t
(** [operation event] is the operation identity every event carries. *)
