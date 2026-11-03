(** Opaque host representation for confidential bytes. *)

type t
(** A secret payload. Its representation is deliberately hidden from OCaml clients. *)

val of_string : string -> t
(** [of_string bytes] crosses the trusted provider boundary and copies [bytes] into an opaque
    payload. *)

val expose : t -> string
(** [expose secret] crosses the trusted explicit-exposure boundary. Generic rendering must never
    call this function. *)

val length : t -> int
(** [length secret] is the number of bytes [secret] holds, without exposing them (for accounting).
*)
