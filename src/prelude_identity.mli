(** Frozen prelude identities (TYPE.1, docs/designs/abstract-types.md §2.3 "Builtins use frozen
    identities"). A builtin that constructs, recognises, calls, registers or types a prelude
    declaration resolves it here, so a source that rebinds the name (a single file, or a root
    without a namespace) can never substitute its own declaration. *)

val binding_lines : Store.t -> string list
(** [binding_lines store] is the store's public bindings as sorted [NAME KIND HEX] lines: the format
    of [corpus/golden/prelude-bindings.golden], from which the pins are generated. *)

val lookup_kind : Store.t -> string -> Resolve.nkind -> Resolve.entry option
(** [lookup_kind store name kind] is the prelude declaration [name] of [kind] by its pinned
    identity: the one the prelude binds publicly to [name] and [kind]. When the store does not hold
    that identity (a reduced test prelude, or a name the prelude does not define) it falls back to
    {!Store.lookup_kind}. *)
