(** Typed observation of facts at the evaluator root (RF.3, docs/observation-boundary.md).

    The evaluator produces one ordered event stream per observed extent. Versioned projections, such
    as [run-transcript-v1], are built from these events; the events themselves are not a persisted
    format. Schedule choices, host-owned facts and governance events are separate carriers and are
    never produced here.

    Observers never receive live runtime values. Arguments and results arrive as immutable data
    ({!value}): secrets, closures, continuations, handles and other executable or capability values
    appear only as {!Opaque} markers, so observing cannot reveal a secret, mutate program state,
    call code, or resume a continuation.

    Payloads are lazy. Forcing one walks the value and charges computation fuel to whichever
    invocation is active when it is forced: inside the callback that is the observed invocation; a
    consumer that keeps an event and forces it later pays from its own budget (or none). *)

(** Immutable, non-executable data view of a runtime value. *)
type value =
  | Int of int
  | Real of float
  | Text of string
  | Hash of Hash.t
  | Tuple of value list
  | Constructor of { identity : Hash.t; name : string; arguments : value list }
      (** a saturated constructor; [identity] is its constructor hash, [name] is display-only *)
  | Code of Form.t  (** a quoted code value; forms are immutable data *)
  | Opaque of string
      (** a value observation does not expose: ["secret"], ["closure"], ["resumption"], ["builtin"],
          ["operation"], ["constructor"], ["task"] or ["channel"] *)

type event =
  | Operation of { operation : Hash.t; name : string; arguments : value list Lazy.t }
      (** An operation crossed every language handler and reached the root, before any root handler
          ran or a driver captured it. [name] is display-only; [operation] is its identity. The
          arguments are projected only if forced; the projection walk draws on computation fuel. *)
  | Output of { operation : Hash.t; bytes : string }
      (** A trusted root adapter accepted [bytes] for [operation] (today only Console print). *)
  | Result of { operation : Hash.t; result : (value, Runtime_err.t) result Lazy.t }
      (** A granted root handler for [operation] returned, and every post-call check passed: its
          arguments, the result's fuel charge and the result's validation. The event carries what
          the program receives (a value or the handler's own failure). There is none for an
          operation a driver captured instead of dispatching, for a dispatch refused before the
          handler ran, or when a post-call check (including fuel exhaustion) fails. If the callback
          itself exhausts the budget (by forcing a large payload), the invocation ends with E0919
          after the event. *)

val of_value : Value.t -> value
(** [of_value v] projects a runtime value to its immutable data view, ticking computation fuel per
    node. *)

val render : value -> string
(** [render v] is the [Value.show] spelling of a data value, with opaque values as [<kind>]. It
    ticks computation fuel per node and per text and constructor-name byte. *)

val operation : event -> Hash.t
(** [operation event] is the operation identity every event carries. *)
