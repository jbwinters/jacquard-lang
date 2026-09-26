(** The project frontend (PKG.1; design: docs/designs/project-structure.md §4–§7, §10).

    The only way project commands prepare code. A project's library units are composed as one
    program ({!Surface_parse.compose_units}), lowered once, and checked against the prelude; the
    checked library is then frozen, and each entry's units are composed and lowered separately over
    it. Nothing is rewritten: identities are exactly those of concatenating the same files.

    This slice covers a project without dependencies. Failure modes (domain [Project]):
    - E1703: a unit exceeds its byte budget;
    - E1706: a library name violates the namespace contract;
    - E1715: a top-level expression in a library unit;
    - E1716: a name defined in two different units;
    - E1718: an entry the manifest does not declare;
    - E1722: a unit path escapes the project directory;
    - E1723: a unit is missing or not a regular file;
    - E1724: two units' canonical paths differ only by case;
    - E1730 / W1700: an entry's declared grants differ from its checked authority;
    - E1731: a library constructor collides with a visible constructor of another type;
    - E1732: the library references a name only an entry defines;
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
