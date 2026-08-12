(** Deterministic input derivation for relational execution lanes. *)

val schedule_seeds : root_seed:int -> count:int -> int list
(** [schedule_seeds ~root_seed ~count] returns exactly [count] pairwise-distinct scheduler seeds
    when [count] is positive. The first seed is [root_seed]; later seeds are successive distinct
    SplitMix64 outputs derived from that root. A non-positive [count] returns the empty list. The
    derivation is deterministic on Jacquard's supported 64-bit OCaml runtime and does not mutate
    caller-visible state. *)
