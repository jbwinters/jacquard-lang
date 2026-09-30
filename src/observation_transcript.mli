(** Policy-bound observation transcripts (OBS.1, docs/observation-policies.md).

    An [observation-transcript-v1] records, for each observed run, its status and (if the policy
    compares results) its result value, then the root operations the policy observes, in order, with
    exactly the fields the policy compares. Fields the policy does not compare are never recorded,
    so they cannot reach serialized bytes or a rendered divergence. Secrets and executable values
    are never rendered: a field containing one is recorded as unsupported. The transcript carries
    its policy identity, and decoding or comparing under another policy is refused.

    [run-transcript-v1] ({!Run_transcript}) is unchanged and independent of this format. *)

val format_version : int

(** One recorded field. *)
type field =
  | Data of string  (** the canonical rendering ({!Observation.render}), within the byte limit *)
  | Truncated of { total : int; prefix : string }
      (** a rendering longer than the policy's limit: its first [field_bytes] bytes and its length
      *)
  | Unsupported of string
      (** a value containing an opaque part (["secret"], ["closure"], ...), which has no observable
          rendering; the kind of its first opaque part *)
  | Failure of string  (** a root handler's failure, by diagnostic code *)
  | Missing  (** the policy compares the field but the run produced none *)

type event = {
  operation : Hash.t;
  arguments : (int * field) list;  (** the compared positions, ascending *)
  result : field option;  (** [Some] exactly when the policy compares this operation's result *)
  output : field option;  (** [Some] exactly when the policy compares this operation's output *)
}

(** How a run ended. A failed or incomplete run keeps the events observed before it stopped. *)
type status =
  | Complete of field option  (** its result value, when the policy compares results *)
  | Failed of string  (** a runtime failure, by diagnostic code *)
  | Incomplete of string  (** the run was stopped by its fuel budget (E0919) *)

type run = { status : status; events : event list }
type transcript

val policy_identity : transcript -> Hash.t
val runs : transcript -> run list

type recorder

val create : Observation_policy.t -> recorder
(** [create policy] starts an empty, non-reentrant recorder under [policy]. *)

val record :
  recorder ->
  Eval.ctx ->
  (unit -> (Value.t, Runtime_err.t) result) ->
  (Value.t, Runtime_err.t) result
(** [record recorder ctx run] executes [run] under a scoped observer and returns its result
    unchanged. Every outcome adds one run: [Ok] is complete, fuel exhaustion is incomplete, any
    other [Error] is failed. A raised exception adds nothing and propagates. Arguments are projected
    inside the observer, so their walk draws on the observed invocation's fuel. *)

val transcript : recorder -> transcript

val serialize : transcript -> string
(** [serialize transcript] is the canonical [observation-transcript-v1] encoding. *)

val parse : policy:Observation_policy.t -> string -> (transcript, Diag.t list) result
(** [parse ~policy bytes] accepts exactly canonical bytes recorded under [policy]. A different
    policy identity, unknown versions, misspelled or reordered fields, fields the policy does not
    compare (or missing ones it does), noncanonical numbers or hashes, and trailing bytes are
    refused with E1006; no input bytes are copied into a diagnostic. *)

(** A path to a field, e.g. [run[0].event[2].argument[1]]. *)
type position =
  | Run_position of int
  | Status_position of int
  | Value_position of int
  | Event_position of { run : int; event : int }
  | Operation_position of { run : int; event : int }
  | Argument_position of { run : int; event : int; argument : int }
  | Result_position of { run : int; event : int }
  | Output_position of { run : int; event : int }

type side =
  | Field_side of field
  | Status_side of status
  | Operation_side of Hash.t
  | Missing_side  (** the other transcript has this run or event and this one does not *)

type difference = { position : position; left : side; right : side }

(** [Equal]: every compared field agrees. [Divergent]: the first field that certainly differs.
    [Inconclusive]: no field certainly differs, but at the first position shown two fields agree
    only on a truncated prefix or an opaque kind, so equality cannot be claimed. *)
type verdict = Equal | Divergent of difference | Inconclusive of difference

val compare : transcript -> transcript -> (verdict, Diag.t list) result
(** [compare left right] compares in run, status, value, event order; within an event: operation,
    arguments, result, output. Transcripts recorded under different policies are refused (E1006). *)

val position_path : position -> string

val render : difference -> string
(** [render difference] is a three-line frame (path, left, right). Only recorded fields can appear,
    so nothing the policy excluded is ever rendered. *)
