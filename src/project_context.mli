(** The [project-context-v1] record (PKG.1; design: docs/designs/project-structure.md §8): what a
    dependent's [(pin …)] commits to. *)

val form :
  Store.t ->
  interface:Interface.t ->
  exports:((string * Resolve.nkind) * Hash.t) list ->
  deps:(string * Hash.t) list ->
  Form.t
(** [form store ~interface ~exports ~deps] is the record for a library whose export projection is
    [exports]: [interface]'s identity, the call-ABI companions of the export closure in [store]
    (private ones included, sorted by identity, slots in ABI order), the store's prelude identity,
    the running Core version, and the dependency pins [deps] (alias, context identity), sorted. *)

val identity : Form.t -> Hash.t
(** [HASH_V0] of the printed record; its head is the domain tag. *)
