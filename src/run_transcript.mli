(** Immutable [run-transcript-v1] observations collected by an explicit interpreter hook. *)

val format_version : int
(** The only run-transcript format emitted by this implementation. *)

type event = { operation : Hash.t; output : string }
(** One operation that reached the evaluator root. [output] contains only bytes accepted by the
    trusted Console adapter; all other root operations have the empty string. *)

type observation = { value : string; trace : event list }
(** One successful top-level expression: [value] is exactly [Value.show result ^ "\\n"]. *)

type transcript
(** An ordered immutable sequence of successful expression observations. *)

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

val serialize : transcript -> string
(** [serialize transcript] emits the canonical byte-oriented [run-transcript-v1] encoding. *)

val serialize_recorder : recorder -> string
(** [serialize_recorder recorder] snapshots and serializes completed observations. It raises the
    internal [Bug_run_transcript] invariant exception while an expression is active. *)
