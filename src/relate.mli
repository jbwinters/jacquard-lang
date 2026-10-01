(** Deterministic input derivation for relational execution lanes. *)

val schedule_seeds : root_seed:int -> count:int -> int list
(** [schedule_seeds ~root_seed ~count] returns exactly [count] pairwise-distinct scheduler seeds
    when [count] is positive. The first seed is [root_seed]; later seeds are successive distinct
    SplitMix64 outputs derived from that root. A non-positive [count] returns the empty list. The
    derivation is deterministic on Jacquard's supported 64-bit OCaml runtime and does not mutate
    caller-visible state. *)

val secret_payloads : root_seed:int -> string * string
(** [secret_payloads ~root_seed] returns two distinct, deterministic printable payloads derived from
    the first two SplitMix64 outputs rooted at [root_seed]. Both carry the stable
    [rw-secret-v0-<lane>-] prefix used by relational leak scans. *)

val redact : secrets:string list -> string -> string
(** [redact ~secrets bytes] replaces every exact occurrence of a nonempty forbidden byte string with
    [<secret redacted>]. It searches longer strings first at an overlapping position, handles
    repeated occurrences, and returns [bytes] unchanged when [secrets] has no nonempty member. It
    does not claim taint tracking, transformed-encoding detection, or secure memory erasure. *)

val redact_fragments : secrets:string list -> string -> string
(** [redact_fragments ~secrets bytes] is {!redact} for a field that may have been truncated: after
    replacing whole occurrences, it also replaces a trailing fragment of [bytes] that is a nonempty
    prefix of a forbidden string (what truncation leaves of a payload at the end). It may redact a
    harmless suffix that merely resembles a payload's start. *)
