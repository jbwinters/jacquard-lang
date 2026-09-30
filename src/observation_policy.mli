(** Versioned observation policies (OBS.1, docs/observation-policies.md).

    A policy names what an observation transcript records and compares: whether the result value is
    compared, which root operations are observed (by operation identity, never display name), which
    of their arguments, results and output are compared, the per-field byte limit, and optionally
    the interface identity the program must have. A field that is not compared is excluded before
    anything is recorded, persisted or rendered: exclusion is the only redaction, and no hash of an
    excluded value is kept.

    A policy has one canonical byte encoding ([observation-policy-v1]) and its identity is a hash of
    those bytes, so a comparison artifact or cache key that names a policy names exactly one
    selection. *)

val format_version : int
(** The only policy format this implementation reads or writes. *)

(** Which arguments of an operation are compared. *)
type arguments =
  | All_arguments
  | No_arguments
  | Selected_arguments of int list
      (** zero-based positions, strictly ascending; a position the call does not have is recorded as
          missing *)

(** Whether a field is compared, or excluded before recording. *)
type field = Compare | Ignore

type rule = { arguments : arguments; result : field; output : field }
(** What is recorded for one observed operation. [result] is the value or failure its root handler
    returned; [output] is the bytes a trusted adapter accepted for it (Console print). *)

type t
(** A validated policy in canonical form. *)

val make :
  result:field ->
  field_bytes:int ->
  unlisted:rule option ->
  interface:Hash.t option ->
  (Hash.t * rule) list ->
  (t, Diag.t list) result
(** [make ~result ~field_bytes ~unlisted ~interface operations] builds a policy. [result] selects
    whether each run's result value is compared (data-v1 value equality, which unlike
    [run-transcript-v1] qualifies constructors by identity). [operations] maps operation identities
    to rules; an operation not listed follows [unlisted] ([None]: not recorded at all).
    [field_bytes] bounds every recorded field; longer fields are truncated. [interface], when
    present, pins the interface-v1 identity the observed program must have. Refused with E1005: a
    repeated operation, a non-positive [field_bytes], or argument positions that are negative,
    repeated or not ascending. *)

val default : t
(** The default policy: results compared; every operation observed with all its arguments and its
    output, its result ignored; 4096 bytes per field; no interface pin. *)

val result : t -> field
val field_bytes : t -> int
val interface : t -> Hash.t option

val rule_for : t -> Hash.t -> rule option
(** [rule_for policy operation] is the rule for [operation]: its listed rule, else the unlisted
    rule, else [None] (the operation is not recorded). *)

val operations : t -> (Hash.t * rule) list
(** The listed operations in canonical (identity) order. *)

val serialize : t -> string
(** [serialize policy] is the canonical [observation-policy-v1] encoding. *)

val parse : string -> (t, Diag.t list) result
(** [parse bytes] accepts exactly canonical [observation-policy-v1] bytes. Unknown versions or
    clauses, reordered or misspelled fields, noncanonical numbers or hashes, unsorted operations and
    trailing bytes are refused with E1005; no input bytes are copied into a diagnostic. *)

val identity : t -> Hash.t
(** [identity policy] is the hash of its canonical bytes under the [observation-policy-v1] domain.
*)

val validate_operations : t -> is_operation:(Hash.t -> bool) -> (unit, Diag.t list) result
(** [validate_operations policy ~is_operation] refuses (E1005) a policy that lists an identity that
    is not an operation of the program, so a policy cannot silently drift to observing nothing after
    an operation's identity changes. *)

val check_interface : t -> identity:Hash.t -> (unit, Diag.t list) result
(** [check_interface policy ~identity] refuses (E1005) a policy pinned to a different interface-v1
    identity than the program's; an unpinned policy accepts any interface. *)
