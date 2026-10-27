(** EXP.1 exploration-log-v1: an opt-in recording of one run's root-reaching operations and Dist
    choices with the source span of the application that performed each (docs/exploration-log.md).
*)

val format_version : int

exception Bound_reached of string
(** Raised from {!on_event} when the next step or byte would pass [--max-steps] (["steps"]) or
    [--max-bytes] (["bytes"]); the recording keeps what it had, including the step that reached the
    bound. *)

type kind = Operation_step | Choice_step | Observe_step

(** {1 Recording} *)

type t

val default_policy : Observation_policy.t
(** Every operation with all its arguments, its result and its output; 4096 bytes per field. *)

val create :
  policy:Observation_policy.t ->
  record_output:bool ->
  max_steps:int ->
  max_bytes:int ->
  sample:Hash.t option ->
  observe:Hash.t option ->
  expose:Hash.t option ->
  t
(** [create ...] starts an empty recorder. [sample] and [observe] are the prelude Dist operation
    identities (their steps are [choice] and [observe]); [expose] is [secret.expose], whose
    plaintext result is never recorded and is redacted from every later field and output. *)

val on_event : t -> Observation.event -> unit
(** [on_event t event] records a root event under the policy: an [Operation] starts a step (with its
    site and projected arguments), a [Result] and an [Output] attach to their step by correlation
    id. Projections draw on the observed invocation's fuel. Raises {!Bound_reached}. *)

(** {1 The log} *)

type entry = {
  e_index : int;
  e_kind : kind;
  e_operation : Hash.t;
  e_name : string;
  e_site : string option;  (** [file:line:col-line:col] *)
  e_arguments : (int * Observation_transcript.field) list;
  e_result : Observation_transcript.field option;
  e_output : Observation_transcript.field option;  (** output, limited like any field *)
}

type ending = Exit of int | Bounded of string

type log = {
  program : string;  (** the [program] line *)
  seed : int;
  grants : string;  (** the [--allow] names as given, comma-joined; a framed payload *)
  policy_identity : Hash.t;
  output_recorded : bool;
  entries : entry list;
  ending : ending;
}

val finish : t -> program:string -> seed:int -> grants:string -> exit_status:int -> log
(** [finish t ~program ~seed ~grants ~exit_status] is the recorded log; its ending is [Bounded] when
    a bound was reached, else [Exit exit_status]. *)

val serialize : log -> string
(** The canonical exploration-log-v1 bytes. *)

val parse : string -> (log, string) result
(** [parse bytes] accepts exactly canonical bytes ([serialize (parse bytes) = bytes]); another
    format version, trailing or missing bytes, a wrong step count, and non-canonical numbers or
    hashes are refused with a reason. *)

type reservation

val reserve : path:string -> (reservation, string) result
(** [reserve ~path] creates [path] empty with mode 0600 and never replaces an existing file; a
    recording reserves its log before the run and writes through the reservation afterwards. *)

val write_reserved : reservation -> string -> (unit, string) result
(** [write_reserved r contents] writes and syncs [contents] through the reserved descriptor and
    closes it. *)

val release : reservation -> unit
(** [release r] closes a reservation that will not be written (the empty file stays). *)
