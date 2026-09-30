(** Sealed payload for prelude callbacks whose arguments do not need host-mutation snapshots.

    This module is Dune-private. Public clients can observe a trusted builtin through [Value.t], but
    only code compiled inside the Jacquard library can create one. *)

type 'a t = { name : string; native : 'a list -> ('a, Runtime_err.t) result; deep : bool }

(** [make ?deep name native]: [deep] marks a native whose work is proportional to the expanded size
    of its arguments (rendering, hashing, or comparing a whole value or code form); computation fuel
    charges such a native for that size before it runs (RT.1). *)
let make ?(deep = false) name native = { name; native; deep }

let name builtin = builtin.name
let deep builtin = builtin.deep
let invoke builtin arguments = builtin.native arguments
