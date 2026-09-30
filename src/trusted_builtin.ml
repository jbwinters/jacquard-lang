(** Sealed payload for prelude callbacks whose arguments do not need host-mutation snapshots.

    This module is Dune-private. Public clients can observe a trusted builtin through [Value.t], but
    only code compiled inside the Jacquard library can create one. *)

type 'a t = { name : string; native : 'a list -> ('a, Runtime_err.t) result }

let make name native = { name; native }
let name builtin = builtin.name
let invoke builtin arguments = builtin.native arguments
