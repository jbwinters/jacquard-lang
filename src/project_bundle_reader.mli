(** Reading and verifying project bundles (PKG.1; design: docs/designs/project-structure.md §9,
    "Import and run"). A bundle is trusted for identity traversal only after every check passes. *)

val version : string
(** ["bundle-v2"], which records each carried context's namespace. *)

val legacy_version : string
(** ["bundle-v1"], still read when it carries no dependency context and no opaque declaration. *)

val snapshot_file : string -> string * string
(** [snapshot_file dir] is the bundle record file in [dir] and its format version. *)

val recorded_namespaces : string -> (string list, Diag.t list) result
(** [recorded_namespaces dir] reads the namespaces a bundle records, before verification, for
    graph-wide refusals; a [bundle-v1] bundle records none. *)

val reachable : Store.t -> Hash.t list -> (Hash.t, Kernel.decl) Hashtbl.t
(** Every declaration reachable from the roots, prelude ones included; quoted data is not code, so
    only live splices are followed. *)

val eval_identities : Store.t -> Hash.t list
(** The identities whose reference means dynamic evaluation: [eval-code] and [Eval]. *)

type entry =
  | Run_entry of { name : string; steps : Hash.t list; grants : string list }
      (** generated thunks, in source order *)
  | Test_entry of { name : string; roots : (string * string * Hash.t) list; grants : string list }
      (** (kind, display, identity) Warp roots *)

type verified = {
  path : string;
  identity : Hash.t;  (** [HASH_V0] of the printed bundle record *)
  manifest : Project_manifest.t;
  context : Hash.t;  (** the project's own context identity *)
  entries : entry list;
  contexts : (Hash.t * Form.t * Interface.t) list;
      (** every verified context record with its derived interface *)
  namespaces : (Hash.t * string) list;
      (** each context's recorded namespace; only the bundle's own root may lack one *)
  objects : (Kernel.decl * Canon.decl_hashes) list;
}

val verify :
  ?prelude:(Hash.t -> bool) ->
  store:Store.t ->
  checker:Check.ctx ->
  string ->
  (verified, Diag.t list) result
(** [verify ~store ~checker path] installs the bundle's objects into [store], which must already
    hold the running prelude, and trusts them only after verifying, in order: the prelude and Core
    match this tool (E1720); every file is a regular file within the byte budgets; every object
    hashes to its file name (E1726); the closure of every object and root is complete (E1728); the
    whole closure type-checks; the companions agree with the objects; every recorded interface
    export is owned by its recorded declaration (E1727); each interface re-derives from the checked
    objects and each context recomputes, dependencies before their consumers (E1729); and the
    manifest matches the record's semantic digest (E1729). Unreadable or malformed bundles are
    E1735.

    TYPE.1 adds these rules.
    - The closure must be self-contained: every reference, every recorded export and every export
      owner resolves to the bundle's own objects or to [prelude] (by default, whatever [store] held
      before), never to an earlier import (E1728).
    - No recorded export may be a sealed constructor (E1736).
    - Every carried context is a dependency of the bundle's own context (E1729).
    - Every carried dependency context records a namespace that prefixes its exports, kind by kind,
      and the root's recorded namespace is its manifest's (E1739).
    - Within the bundle, no namespace is recorded at two identities (E1714) and none is a
      boundary-prefix of another (E1707).
    - Each context's region, the closure of its own roots stopping at the exact identities other
      contexts export and at the prelude, constructs or matches only the sealed types its own
      context owns (E1738), and reaches through live references only types and effects in its
      namespace (E1739). A constructing term in no region is refused (E1738).

    Verification runs in a store transaction, so a refused bundle leaves none of its objects in
    [store]. *)

type t = { bundle : verified; store : Store.t; ctx : Eval.ctx; checker : Check.ctx }

val load : prelude_dir:string -> root:string -> string -> (t, Diag.t list) result
(** [load ~prelude_dir ~root path] opens a fresh session at [root], which must be absent or empty
    ([Invalid_argument] otherwise), and {!verify}s the bundle into it: the session's store holds
    exactly the prelude, which [verify]'s default prelude membership relies on. *)
