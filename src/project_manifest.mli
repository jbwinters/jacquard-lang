(** The local project manifest, [project.jqd] (PKG.1; design: docs/designs/project-structure.md §3).

    A manifest is a data value in the bootstrap carrier, head [project-v1]. It is read with the
    ordinary reader, validated against a strict schema, and never evaluated. Unknown fields outside
    [metadata] are refused rather than ignored, so a v1 tool fails closed on a newer manifest.

    Failure modes (all domain [Project]):
    - E1700: malformed manifest (not a form, wrong head, wrong field shape, invalid value);
    - E1701: an unknown field or sub-field;
    - E1702: a duplicate field, unit, export selector, dependency alias, entry key, grant, or
      metadata key;
    - E1703: a budget exceeded (manifest bytes, text length, or collection size);
    - E1704: [requires] not satisfied by the running Core ({!check_requires});
    - E1735: no [project.jqd] found, or it cannot be read ({!locate}, {!read}). *)

type kind = Term | Con | Op | Type | Effect

type selector = { kind : kind; name : string }
(** An export selector [(kind store-name)]; store spellings, so [(type rota-problem)]. *)

type source =
  | Path of string
  | Bundle of string
      (** Where a dependency comes from. [Path] is a project directory; [Bundle] a verified bundle.
      *)

type dep = { alias : string; source : source; pin : Hash.t option }
(** [pin] is [None] only in the authoring state accepted by [project pin]. *)

type entry_kind = Run | Test

type entry = {
  ekind : entry_kind;
  ename : string;
  eunits : string list;  (** in composition order *)
  grants : string list;  (** sorted, declared expectation only; never authority *)
  native : bool;  (** [run] entries only *)
}

type t = {
  name : string;  (** display text; not identity *)
  core : int * int;  (** [requires (core "MAJOR.MINOR")] *)
  namespace : string option;
  units : string list;  (** library units, in composition order *)
  exports : selector list;
  deps : dep list;
  entries : entry list;
  metadata : (string * string) list;  (** non-semantic; never affects checking or identity *)
}

val version : string
(** ["project-v1"]. *)

val max_bytes : int
(** Manifest size budget, checked before parsing (64 KiB). *)

val kind_name : kind -> string

val parse : file:string -> string -> (t, Diag.t list) result
(** [parse ~file src] validates [src] as a [project-v1] manifest. Every violation is reported, in
    source order where a span exists. *)

val check_requires : t -> core:string -> (unit, Diag.t list) result
(** [check_requires t ~core] accepts a running Core version ["MAJOR.MINOR[.PATCH...]"] of the same
    major and at least the required minor; otherwise E1704. *)

val to_form : t -> Form.t
(** The canonical form: fields in schema order, [exports], [deps], [entries], grants, and [metadata]
    sorted by key; unit lists keep their order. *)

val print : t -> string
(** The canonical spelling written by [jacquard project fmt]. *)

val semantic_projection : t -> Form.t
(** The canonical form without [name] and [metadata] (design §3). *)

val semantic_digest : t -> Hash.t
(** [HASH_V0] of the printed semantic projection; changes only when semantics do. *)

val document_digest : t -> Hash.t
(** [HASH_V0] of the full canonical spelling, for provenance. *)

val file_name : string
(** ["project.jqd"]. *)

val locate : ?project:string -> cwd:string -> ?home:string -> unit -> (string, Diag.t list) result
(** [locate ?project ~cwd ?home ()] is the manifest path. With [project], it is that directory's
    manifest. Otherwise it is the nearest [project.jqd] found searching upward from [cwd], stopping
    after the first directory that contains [.git], at [home], or at the filesystem root. E1735 if
    there is none. *)

val read : string -> (t, Diag.t list) result
(** [read path] reads at most {!max_bytes} + 1 bytes from a regular file and parses them. *)

val write_canonical : string -> t -> (unit, Diag.t list) result
(** [write_canonical path t] replaces [path] with {!print}[ t] atomically: a temporary file in the
    same directory, fsync, then rename. On failure the old file is untouched. *)
