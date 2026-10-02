(** Scoped effect instance tokens (TS.2, design docs/designs/scoped-effect-instances.md §10 A2.1).

    This module is private to the Jacquard runtime. A token is the runtime value of a capability:
    each checked scope mints one, and the scope's handler serves exactly the operations whose
    capability carries it. Tokens have no rendering, serialization or structural equality. *)

type t
(** An opaque token, unique within the process. *)

val fresh : unit -> t
(** [fresh ()] mints a token distinct from every token minted before it, across evaluator contexts,
    runs and domains. *)

val same : t -> t -> bool
(** [same left right] holds when both are the same minted token. *)
