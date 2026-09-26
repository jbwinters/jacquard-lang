(** Reading and verifying project bundles (PKG.1; design: docs/designs/project-structure.md §9,
    "Import and run"). A bundle is trusted for identity traversal only after every check passes. *)

val version : string

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
  identity : Hash.t;  (** [HASH_V0] of the printed [bundle-v1] record *)
  manifest : Project_manifest.t;
  context : Hash.t;  (** the project's own context identity *)
  entries : entry list;
  contexts : (Hash.t * Form.t * Interface.t) list;
      (** every verified context record with its derived interface *)
  objects : (Kernel.decl * Canon.decl_hashes) list;
}

val verify : store:Store.t -> checker:Check.ctx -> string -> (verified, Diag.t list) result
(** [verify ~store ~checker path] installs the bundle's objects into [store], which must already
    hold the running prelude, and trusts them only after verifying, in order: the prelude and Core
    match this tool (E1720); every file is a regular file within the byte budgets; every object
    hashes to its file name (E1726); the closure of every object and root is complete (E1728); the
    whole closure type-checks; the companions agree with the objects; every recorded interface
    export is owned by its recorded declaration (E1727); each interface re-derives from the checked
    objects and each context recomputes, dependencies before their consumers (E1729); and the
    manifest matches the record's semantic digest (E1729). Unreadable or malformed bundles are
    E1735. A failure can leave objects in [store]; a caller discards the store. *)

type t = { bundle : verified; store : Store.t; ctx : Eval.ctx; checker : Check.ctx }

val load : prelude_dir:string -> root:string -> string -> (t, Diag.t list) result
(** [load ~prelude_dir ~root path] opens a fresh session at [root] and {!verify}s the bundle into
    it. *)
