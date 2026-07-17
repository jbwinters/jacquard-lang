(** Unforgeable authority for the runtime's private Task bridge. *)

type t

val runtime : t
(** The single runtime-owned authority. This module is private to the library. *)
