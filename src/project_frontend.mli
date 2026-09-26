(** The project frontend (PKG.1; design: docs/designs/project-structure.md §4–§7, §10).

    The only way project commands prepare code. A project's library units are composed as one
    program ({!Surface_parse.compose_units}), lowered once, and checked against the prelude; the
    checked library is then frozen, and each entry's units are composed and lowered separately over
    it. Nothing is rewritten: identities are exactly those of concatenating the same files.

    Failure modes (domain [Project]):
    - E1703: a unit exceeds its byte budget;
    - E1705 / E1709: a name or identity another project keeps private;
    - E1706: a library name violates the namespace contract;
    - E1707 / E1714: namespaces that overlap, or one namespace at two context identities;
    - E1708: a depended-on project without a namespace;
    - E1710 / E1712: a root or transitive pin that does not match;
    - E1711: an unpinned dependency;
    - E1713: a dependency cycle;
    - E1715: a top-level expression in a library unit;
    - E1716: a name defined in two different units;
    - E1718: an entry the manifest does not declare;
    - E1722: a unit path escapes the project directory;
    - E1723: a unit is missing or not a regular file;
    - E1724: two units' canonical paths differ only by case;
    - E1730 / W1700: an entry's declared grants differ from its checked authority;
    - E1731: a library constructor collides with a visible constructor of another type;
    - E1732: the library references a name only an entry defines;
    - E1717: an export selector naming nothing the project defines;
    - E1733: a file changed while pinning;
    - E1734: two unit entries resolve to the same file. *)

type project = {
  dir : string;  (** the project directory, canonical (symlinks resolved) *)
  manifest_file : string;
  manifest : Project_manifest.t;
}

val max_unit_bytes : int
(** Per-unit source budget (4 MiB). *)

val load : string -> (project, Diag.t list) result
(** [load manifest_file] reads and validates the manifest and every unit path it names: each library
    unit and each entry's units must be contained regular files, and within one composition (the
    library, or the library followed by one entry) no two units may be the same file or differ only
    by case. Every violation is reported. *)

val find_entry : project -> string -> (Project_manifest.entry, Diag.t list) result
(** E1718 when the manifest declares no entry of that name. *)

val find_entry_of_kind :
  project -> string -> Project_manifest.entry_kind -> (Project_manifest.entry, Diag.t list) result
(** {!find_entry}, and E1718 when the entry is of the other kind. *)

type session
(** A store holding the prelude and the checked, frozen library, with its evaluation context and
    checker. A session is owned by one command; entry code installed into it is visible to later
    code in the same session only. *)

val store : session -> Store.t
val eval_ctx : session -> Eval.ctx
val checker : session -> Check.ctx

val library_declarations : session -> int
(** The number of library declarations installed. *)

type node
(** A project and its dependencies, loaded and validated but not yet composed. *)

val open_graph :
  ?on_lint:(Diag.t -> unit) ->
  ?on_warning:(Diag.t -> unit) ->
  ?pinning:bool ->
  prelude_dir:string ->
  root:string ->
  string ->
  (session * node, Diag.t list) result
(** [open_graph ~prelude_dir ~root manifest_file] loads the project and its dependency graph (E1707,
    E1708, E1711, E1713), opens a fresh store at [root], and composes every library dependency-first
    into it, each resolved in its own view: its own bindings, its direct dependencies' export
    projections, and the prelude. Names other projects keep private are E1705, such identities
    E1709; export selectors must name the project's own bindings (E1717); one namespace at two
    context identities is E1714. Every pin is then compared with the computed context identity:
    E1710 for the root's edges and E1712 for transitive ones. With [pinning], the root's own edges
    may be unpinned and are not compared. Warnings are reported for the root's library only. *)

val interface : session -> Interface.t
(** The root library's [interface-v1], over its export projection: exported selectors are public,
    and every other member of an exported declaration (an abstract type's constructors) is hidden.
*)

val context_record : session -> Form.t
(** The root library's [project-context-v1] record: its interface identity, the call-ABI companions
    of its export closure, the prelude, the Core version, and its dependencies' pins. *)

val context_identity : session -> Hash.t
(** [HASH_V0] of the printed {!context_record}; what a dependent's [(pin …)] names. *)

type pin_plan = {
  alias : string;
  old_pin : Hash.t option;
  new_pin : Hash.t;
  changes : string option;  (** components and interface report when the pin moves *)
}

val plan_pins : session -> node -> only:string list -> (pin_plan list, Diag.t list) result
(** The root's direct dependencies (only those in [only], when non-empty) with their current and
    computed pins. *)

val write_pins : session -> node -> pin_plan list -> (unit, Diag.t list) result
(** Records every dependency's context record and interface under the root's [.jacquard/], then
    rewrites the root manifest atomically with the planned pins. Every manifest and unit read while
    composing is rechecked first; any change is E1733 and nothing is written. Dependency manifests
    are never edited. *)

val open_library :
  ?on_lint:(Diag.t -> unit) ->
  ?on_warning:(Diag.t -> unit) ->
  prelude_dir:string ->
  root:string ->
  project ->
  (session, Diag.t list) result
(** [open_library ~prelude_dir ~root project] opens a fresh store at [root] (which must not exist or
    be empty), loads the prelude, and composes, checks, and installs the library. The library rules
    (E1715, E1716), the namespace contract (E1706), and constructor collisions (E1731) are checked
    before anything is resolved; an unresolved library name that an entry defines is E1732. Surface
    lint warnings go to [on_lint]; resolver and checker warnings to [on_warning]. *)

val entry_tops :
  ?on_lint:(Diag.t -> unit) ->
  session ->
  Project_manifest.entry ->
  (Kernel.top list, Diag.t list) result
(** [entry_tops session entry] composes and lowers the entry's units over the frozen library. The
    tops are unresolved, in composition order; a caller walks them ({!Frontend.walk_tops}) against
    the session store. *)

val walk_entry :
  ?on_resolved:(Kernel.top -> Diag.t list -> (unit, Diag.t list) result) ->
  ?on_installed:(Kernel.decl -> Canon.decl_hashes -> (unit, Diag.t list) result) ->
  session ->
  Kernel.top list ->
  (unit, Diag.t list) result
(** [walk_entry session tops] resolves and installs an entry's tops ({!Frontend.walk_tops}) in the
    root project's view: the entry's own bindings, the library, the direct dependencies' export
    projections, and the prelude. An identity another project keeps private is E1709 and such a name
    E1705. From then on, [eval-code] payloads in the session resolve through the same gate. *)

type authority = {
  required : Hash.t list;  (** effects the entry's checked code needs, sorted *)
  owned_tests : Warp.discovered list;  (** for a test entry, the Warp tests its units bind *)
}

val check_entry :
  ?on_lint:(Diag.t -> unit) ->
  ?on_warning:(Diag.t -> unit) ->
  session ->
  Project_manifest.entry ->
  (authority, Diag.t list) result
(** [check_entry session entry] resolves, checks, and installs every top of the entry in the session
    store, without running anything, and returns its checked authority: for a [run] entry the
    effects its top-level expressions require; for a [test] entry the world authority Warp requires
    when the entry owns a world test, and nothing otherwise. *)

val owned_tests : session -> Hash.t list -> Warp.discovered list
(** [owned_tests session hashes] is Warp's discovery restricted to tests whose identity is among
    [hashes], the members an entry's units installed. *)

val compare_grants : strict:bool -> session -> Project_manifest.entry -> authority -> Diag.t list
(** [compare_grants ~strict session entry authority] compares the entry's declared [(grants …)],
    normalized as [--allow] normalizes them ([console] also covers [ConsoleInput]), with its checked
    authority: one W1700 (or E1730 when [strict]) for each required effect not declared and each
    declared grant the entry does not use. A manifest never grants authority. *)

(** {1 Bundling} *)

val project : session -> project

val is_prelude_object : session -> Hash.t -> bool
(** Whether a declaration was installed by the prelude, which a bundle never carries. *)

val root_exports : session -> ((string * Resolve.nkind) * Hash.t) list
(** The root library's export projection. *)

val graph_contexts : session -> (Hash.t * Form.t * Interface.t) list
(** Every composed project's context identity, record, and interface, sorted by identity. *)

val graph_dirs : session -> string list
(** The canonical directory of every project in the graph, the root included. *)

type bundled_entry =
  | Steps of Hash.t list  (** a run entry's generated thunks, in source order *)
  | Roots of (string * string * Hash.t) list  (** a test entry's (kind, display, identity) *)

val bundle_entry : session -> Project_manifest.entry -> (bundled_entry, Diag.t list) result
(** [bundle_entry session entry] checks the entry ({!check_entry}) and installs its bundle roots: a
    run entry's top-level expressions become generated terms [entry.NAME.step-1],
    [entry.NAME.step-2], ..., each a checked zero-argument thunk; a test entry's owned Warp tests
    become typed roots. *)

val library_bindings : session -> ((string * Resolve.nkind) * Hash.t) list
(** Every (name, kind) the root library binds, with its identity, sorted. *)
