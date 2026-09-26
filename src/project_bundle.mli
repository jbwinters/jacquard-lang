(** Project bundles (PKG.1; design: docs/designs/project-structure.md §9): the runnable, verifiable,
    importable form of a project.

    A bundle is a directory: [bundle-v1.jqd] (the root record, whose [HASH_V0] is the bundle
    identity), the canonical [project.jqd], [interfaces/] and [contexts/] for the project and every
    dependency (named by context identity), [companions.jqd] (the call-ABI companions of the
    closure), [provenance.jqd] (not part of any identity), and [objects/] (the persisted bytes of
    every non-prelude declaration reachable from a run step, a test root, or an export).

    Failure modes (domain [Project]): E1721 when dynamic evaluation is reachable from any root;
    E1725 when the output overlaps an input or already exists. *)

val version : string
(** ["bundle-v1"]. *)

type summary = { identity : Hash.t; objects : int; companions : int }

val write :
  prelude_dir:string -> root:string -> out:string -> string -> (summary, Diag.t list) result
(** [write ~prelude_dir ~root ~out manifest_file] composes the project
    ({!Project_frontend.open_graph} with a fresh store at [root]), generates each entry's roots
    ({!Project_frontend.bundle_entry}), and publishes the bundle at [out]: built in a sibling
    temporary directory, then renamed into place, so a failure leaves nothing at [out]. Bytes depend
    only on the inputs (and [SOURCE_DATE_EPOCH], recorded in the provenance when set). *)
