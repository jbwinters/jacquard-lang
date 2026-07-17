(** Opaque identity shared by one evaluator and every structured scope it schedules. *)

type t

val create : unit -> t
(** [create ()] returns a fresh owner token. Tokens never enter canonical identity, scheduler
    traces, or Jacquard values. *)

val equal : t -> t -> bool
(** [equal left right] holds only when both values are the same owner token. *)
