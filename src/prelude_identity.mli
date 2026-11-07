(** Frozen prelude identities (TYPE.1, docs/designs/abstract-types.md §2.3 "Builtins use frozen
    identities"). A builtin that constructs, recognises, calls, registers or types a prelude
    declaration resolves it here, so a source that rebinds the name (a single file, or a root
    without a namespace) can never substitute its own declaration. *)

val binding_lines : Store.t -> string list
(** [binding_lines store] is the store's public bindings as sorted [NAME KIND HEX] lines: the format
    of [corpus/golden/prelude-bindings.golden], from which the pins are generated. *)

val lookup_kind : Store.t -> string -> Resolve.nkind -> Resolve.entry option
(** [lookup_kind store name kind] is the prelude declaration [name] of [kind] by its pinned
    identity: the one the prelude binds publicly to [name] and [kind]. It fails closed: when [name]
    and [kind] are pinned but the store does not hold that identity (a stale golden, or a store
    whose prelude differs), the result is [None], never the store's binding for the name. Only a
    name the prelude does not define falls back to {!Store.lookup_kind}. *)

val pinned : Store.t -> string -> Resolve.nkind -> Hash.t option
(** [pinned store name kind] is the pinned prelude identity of [name] and [kind] when [store] holds
    it, and [None] otherwise: unlike {!lookup_kind} it never falls back to the name, so a caller
    that needs the standard prelude declaration can refuse a store that lacks it. *)

val pinned_identity : string -> Resolve.nkind -> Hash.t option
(** [pinned_identity name kind] is the identity pinned for [name] and [kind] by this build, whatever
    any store holds; [None] when the prelude does not define it. For diagnostics. *)
