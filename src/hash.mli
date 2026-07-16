(** Validated content hashes using the repository's named HASH_V0 algorithm. *)

type t
(** A HASH_V0 digest. The representation is abstract so library clients cannot construct values with
    malformed raw-byte lengths. *)

val algorithm : string
val digest_size : int

val of_string : string -> t
(** [of_string bytes] hashes [bytes] with HASH_V0. *)

val to_raw : t -> string
(** [to_raw hash] returns exactly [digest_size] raw digest bytes. *)

val to_hex : t -> string
(** [to_hex hash] returns the canonical lowercase hexadecimal spelling. *)

val of_hex : string -> t option
(** [of_hex spelling] accepts a full lowercase or uppercase hexadecimal digest and rejects malformed
    length or characters. *)

val of_canonical_hex : string -> t option
(** [of_canonical_hex spelling] accepts only the unique lowercase public HASH_V0 spelling. *)

val equal : t -> t -> bool
val compare : t -> t -> int
val pp : Format.formatter -> t -> unit
