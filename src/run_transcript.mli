(** Immutable [run-transcript-v1] observations collected by an explicit interpreter hook. *)

val format_version : int
(** The only run-transcript format emitted by this implementation. *)

type event = { operation : Hash.t; output : string }
(** One operation that reached the evaluator root. Nonempty [output] is structurally valid only for
    the frozen Console.print operation; recorder-produced bytes are exactly those accepted by its
    trusted adapter. All other root operations have the empty string. *)

type observation = { value : string; trace : event list }
(** One successful top-level expression: [value] is exactly [Value.show result ^ "\\n"]. *)

type transcript
(** An ordered immutable sequence of successful expression observations. *)

(** A logical first-divergence position. Indices are zero-based and paths are ordered first by
    observation, then by value, then by trace event. *)
type position =
  | Observation_position of int
  | Value_position of int
  | Trace_position of { observation_index : int; trace_index : int }

(** Stable semantic classification of a completed-run difference. *)
type divergence_kind = Value_divergence | Trace_divergence | Length_divergence

(** One structured side of a divergence. Raw values and Console outputs remain available so a caller
    can redact them before rendering; [Missing_side] marks a strict prefix. *)
type side =
  | Value_side of string
  | Trace_side of event
  | Observation_side of observation
  | Missing_side

type divergence = { position : position; kind : divergence_kind; left : side; right : side }
(** The first logical difference between two canonical transcripts. *)

(** Complete comparison result for two successfully decoded transcripts. *)
type verdict = Equal | Divergence of divergence

type recorder
(** A mutable, non-reentrant builder for one {!type-transcript}. *)

val create : unit -> recorder
(** [create ()] returns an empty recorder. *)

val record_expression :
  recorder -> Eval.ctx -> (unit -> (Value.t, 'error) result) -> (Value.t, 'error) result
(** [record_expression recorder ctx run] executes [run] under a scoped root observer and returns its
    result unchanged. Only [Ok value] commits one immutable observation; [Error _] and raised
    exceptions leave the transcript unchanged. Re-entering a recorder or receiving output for a
    different root operation raises [Bug_run_transcript]. *)

val transcript : recorder -> transcript
(** [transcript recorder] snapshots the completed observations in evaluation order. It raises
    [Bug_run_transcript] while an expression is actively being recorded. *)

val observations : transcript -> observation list
(** [observations transcript] returns its observations in canonical order. *)

val parse : string -> (transcript, Diag.t list) result
(** [parse bytes] accepts exactly canonical [run-transcript-v1] bytes. It rejects unknown versions,
    misspelled or reordered fields, noncanonical unsigned decimals or hashes, noncontiguous indices,
    incorrect counts, output attributed to a non-Console operation, truncated payloads, values
    without their required final LF, and trailing bytes with E1004. Malformed input never raises and
    no input payload is copied into a diagnostic. *)

val compare : transcript -> transcript -> verdict
(** [compare left right] returns the first logical divergence in observation/value/trace order.
    Within an event the operation identity precedes its output. It is pure and total, and returns
    [Equal] exactly when [serialize left] and [serialize right] are byte-equal. *)

val position_path : position -> string
(** [position_path position] returns the stable [observation[I]]-style path used by the renderer. *)

val divergence_kind_name : divergence_kind -> string
(** [divergence_kind_name kind] returns [value-divergence], [trace-divergence], or
    [length-divergence]. *)

val render : divergence -> string
(** [render divergence] emits the canonical three-line semantic-diff frame. Arbitrary payload bytes
    use escaped string syntax, trace events use stable hash/output rows, missing sides render as
    [<missing>], and observation-prefix rows use one compact observation summary without recursively
    rendering its trace. The function adds no diagnostic header, labels, ANSI escapes, or terminal
    LF. *)

val render_redacted : redact:(string -> string) -> divergence -> string
(** [render_redacted ~redact divergence] has the same canonical frame as {!render}, but applies the
    caller's pure byte transformation to raw value and Console-output fields before escaping them.
    Paths, operation hashes, original byte counts, classifications, and missing-side markers remain
    unchanged. The callback must not raise; this function performs no persistence or logging. *)

val serialize : transcript -> string
(** [serialize transcript] emits the canonical byte-oriented [run-transcript-v1] encoding. *)

val serialize_recorder : recorder -> string
(** [serialize_recorder recorder] snapshots and serializes completed observations. It raises the
    internal [Bug_run_transcript] invariant exception while an expression is active. *)
