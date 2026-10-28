(** MODEL.1 evaluation history, snapshots, and explanations (docs/designs/model-dependencies.md
    §3.5).

    Under a cache directory, each document has an append-only history per result: a
    [jacquard-model-history-v1] record is appended whenever a result is evaluated under a key that
    differs from its latest record's. Each record names the dependency record, the named bindings
    with snapshot references, the source digest and interface identity, and the outcome. Snapshots
    retain assumption text, inline literals, input bytes and the policy, content-addressed by their
    HASH_V0, so a past evaluation can be explained after the document changes. *)

val document_identity : string -> Hash.t
(** [document_identity file] is HASH_V0 of the document's canonical absolute path, so documents
    sharing a cache directory never share histories. *)

type binding = { kind : string; name : string; snapshot : Hash.t option }

type record = {
  time : string;  (** UTC, [YYYY-MM-DDTHH:MM:SSZ] *)
  entry_name : string;
  key : Hash.t;
  previous : Hash.t option;  (** the key of the record before this one *)
  outcome : string;  (** the status and outcome tag, as [model eval] reported them *)
  source : Hash.t;  (** provenance: the source digest *)
  interface : Hash.t;  (** provenance: the source's interface-v1 identity *)
  policy_snapshot : Hash.t;
  bindings : binding list;
  dependency : Model_doc.dependency;
}

val serialize_record : record -> string

val parse_history : string -> (record list, string) result
(** [parse_history bytes] reads a whole history file, oldest record first; any malformed or
    noncanonical record, a record whose key is not its dependency record's, or whose bindings do not
    match its arguments, refuses the file. *)

val append :
  cache:string ->
  document:Hash.t ->
  Model_doc.prepared ->
  Model_doc.resolved ->
  outcome:string ->
  (string option, string) result
(** [append ~cache ~document prepared resolved ~outcome] writes the result's snapshots (owner-only,
    atomically, when absent) and appends a record when the result has no history or its latest
    record has another key, holding an exclusive lock on a sibling [.lock] file across the read, the
    decision and the write. A history with a damaged frame keeps every record before it, is
    rewritten atomically, and the result carries a note saying so; a history that cannot be read at
    all is left untouched and refused. *)

(** {1 Explanations} *)

type change = {
  component : string;
      (** ["entry"], ["signature"], ["labels"], ["prelude"], ["core"], ["driver"], ["fuel"],
          ["policy"], ["arguments"], or an argument kind *)
  subject : string option;  (** the entry, assumption, input or term name *)
  before : string option;
  after : string option;
}

type freshness =
  | Current
  | Unknown of string list
      (** the key is unchanged, but these dependencies' snapshots are gone, so the result is never
          assumed current *)
  | Stale of change list  (** every differing key component *)
  | Never_evaluated
  | Unavailable of string  (** the history cannot be read; never guessed *)

type explanation = {
  result : string;
  evaluated_at : string option;  (** the latest record's time *)
  freshness : freshness;
  transition : (string * change list) option;
      (** the latest record against its predecessor: the latest record's time and its changes *)
}

val explain : cache:string -> document:Hash.t -> Model_doc.prepared -> explanation list
(** [explain ~cache ~document prepared] compares each result's current dependency record, computed
    without evaluating, with its latest record, and that record with its predecessor. An assumption
    or input renders from its snapshots; a missing snapshot renders as ["(unavailable)"]. *)

val render_text : explanation -> string list

val to_json : explanation list -> string
(** The [jacquard-model-explain-v1] JSON object [{format, results}], on one line. *)
