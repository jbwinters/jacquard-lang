(** API.1 interface manifests: the versioned, portable description of what a checked source or a
    store exposes, binding each export name to its exact semantic identity, its checked signature,
    its external call labels, and its visibility.

    A manifest is derived from semantic artifacts, never authored: {!of_side} reads a checked store,
    and {!Frontend.check} seals one into every checked artifact. It is the durable API carrier that
    [HASH_V0] deliberately omits: labels live in [call-abi-v1] companions and field schemas, and
    [jac export] emits positional [.jqd] only, so a manifest is the separate artifact that lets a
    consumer validate an import, compare two versions, or elaborate a named call without inferring
    labels from alpha-renamable binders. [HASH_V0], the kernel, the store format, and [.jqd] are
    unchanged by this module. *)

(** {1 Content} *)

type visibility = Public | Hidden

type export = {
  name : string;  (** The exported name, as the store index spells it. *)
  kind : Resolve.nkind;
  hash : Hash.t;  (** The exact identity: a member, constructor, operation, type, or effect hash. *)
  owner : Hash.t;  (** The declaration hash that owns [hash]. *)
  signature : string option;
      (** The checked scheme of a term, constructor, or operation, rendered with every referenced
          identity spelled as its full hash, so the text is independent of names. *)
  mode : Kernel.op_mode option;  (** An operation's continuation mode. *)
  arity : int option;  (** A type's or effect's number of type parameters. *)
  labels : string option list option;
      (** The external call labels: a term's or operation's [call-abi-v1] companion, or a
          constructor's field labels. [None] means positional-only (no companion). *)
}

type t = {
  source : Hash.t option;  (** HASH_V0 of the exact source bytes, when derived from a source. *)
  prelude : (string * string) list option;
      (** The prelude identity the artifacts were checked against. *)
  exports : export list;  (** Sorted by name, then kind. *)
  hidden : (Hash.t * Hash.t) list;
      (** [(member, owner)] for derived members of exported declarations that are not exported (an
          abstract type's private constructor, a scheduler-private carrier), sorted. *)
}

val version : string
(** ["interface-v1"], the manifest format this module reads and writes. *)

val kind_rank : Resolve.nkind -> int
(** The tie-break order of kinds sharing a name: term, con, op, type, effect. *)

val find : t -> string -> Resolve.nkind -> export option

val member_visibility : t -> Hash.t -> visibility option
(** [member_visibility t hash] is [Some Public] for an exported identity, [Some Hidden] for a
    recorded hidden member, and [None] when the manifest does not describe [hash]. *)

(** {1 Producing} *)

val of_side : ?source:Hash.t -> Check.ctx -> Diff.side -> (t, Diag.t list) result
(** [of_side checker side] describes every binding [side] exposes that [side.store] publicly binds
    to the same identity, reading signatures through [checker] (which must be a checker over
    [side.store]) and labels from the store's companions and constructor schemas. Hidden members are
    the derived identities of exported declarations that the store does not bind: a member hidden
    after installation, or one the store never publishes. Checker failures on an exported identity
    are returned. *)

(** {1 Serialization and identity} *)

val serialize : t -> string
(** The deterministic [.jqd]-carrier rendering: one form per line, exports in {!t} order. Equal
    manifests serialize byte-identically. *)

val parse : file:string -> string -> (t, Diag.t list) result
(** [parse ~file text] reads a serialized manifest. A malformed or unsupported carrier is E0613; the
    version line must come first. *)

val identity : t -> Hash.t
(** [HASH_V0] of the serialized exports and hidden members alone: the public API's content identity.
    The source digest and prelude lines are provenance and do not enter it, so a reformatted or
    binder-renamed source has the same interface identity. *)

val diagnostic : ?span:Span.t -> code:string -> string -> Diag.t
(** [diagnostic ~code cause] is the module's E0613 (malformed manifest) or E0614 (store does not
    provide the interface) diagnostic with its summary and next step. *)

(** {1 Import validation} *)

type mismatch =
  | Prelude_changed
  | Missing of export  (** The store binds no such (name, kind). *)
  | Rebound of export * Hash.t  (** The store binds the name to another identity. *)
  | Companion_missing of export
      (** The manifest records call labels the store does not carry; labels are never inferred. *)
  | Companion_mismatch of export * string option list
  | Declaration_mismatch of export * string
      (** The store's declaration contradicts a recorded contract: owner, operation mode, type or
          effect arity, or constructor field labels; the text names what is declared. *)
  | Exposed of Hash.t  (** A hidden member is publicly bound in the store. *)

val verify : t -> Store.t -> (unit, mismatch list) result
(** [verify t store] succeeds only when [store] provides exactly the interface [t] describes: the
    same prelude identity when both record one, every export bound to its identity with an equal
    companion and a declaration that agrees with its recorded owner, mode, arity, and field labels,
    and every hidden member unbound. Signatures are not re-derived: an identity fixes its signature
    relative to the prelude, and both are verified, whereas re-checking in a store whose names were
    rebound (a source that redefines [Int]) would report spurious differences. Every mismatch is
    reported, in manifest order. *)

val describe_mismatch : mismatch -> string

(** {1 API comparison} *)

type change =
  | Added
  | Removed
  | Renamed_from of string  (** The same identity was exported under another name. *)
  | Identity_changed of Hash.t * Hash.t
  | Signature_changed_to of string option * string option
  | Labels_changed of string option list option * string option list option
  | Mode_changed of Kernel.op_mode option * Kernel.op_mode option
  | Arity_changed of int option * int option
  | Became_hidden  (** The identity is still owned but no longer exported. *)
  | Became_public  (** A previously hidden member is now exported. *)

type report = { compatible : bool; entries : (export * change list) list }
(** [compatible] holds when every change is additive: only [Added] and [Became_public]. *)

val diff : old:t -> new_:t -> report
(** [diff ~old ~new_] compares exports by (name, kind), then matches removed and added identities to
    report renames and visibility changes. Entries follow the new manifest's order, then removals.
*)

val render_report : report -> string option
(** One line per entry; [None] when nothing changed. *)
