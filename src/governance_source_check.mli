(** Static source verification for the canonical [workspace-v0] governance profile.

    This boundary consumes resolved, typechecked declarations from an isolated analysis store. It
    never evaluates a Jacquard expression, installs a handler, or derives runtime governance value
    identities. *)

type identity = { name : string; hash : Hash.t; introduced_row : string list }

type operation = {
  name : string;
  hash : Hash.t;
  authority : string list;
  normalizer : Hash.t;
  summarizer : Hash.t;
}

type report = {
  facade : identity;
  live : identity;
  dry : identity;
  live_policy_binder : Hash.t;
  dry_policy_binder : Hash.t;
  layers : identity list;
  operations : operation list;
}

val version : string
(** The exact source-check report version. *)

val schema : string
(** The exact JSON success-report schema. *)

val verify : Store.t -> Check.ctx -> Kernel.decl list -> (report, Diag.t list) result
(** [verify store checker declarations] verifies one unambiguous canonical Workspace source root and
    the complete shipped profile behind it. [declarations] must already have been resolved, stored,
    and typechecked in [store] using [checker], whose primitive signatures must have been frozen
    before the source was inserted. Traversal stops only at exact pinned membrane boundaries.
    Missing, ambiguous, unsupported, or residual-authority roots return E1413; the outward root row
    must exactly match the fixed live or dry profile because the v1 report has no residual-authority
    field. Malformed profile facts return their existing E1400--E1412 meanings. The function does
    not mutate [store]. *)

val render_text : report -> string
(** Render the deterministic human report, including the runtime-artifact verification handoff. *)

val render_json_v1 : report -> string
(** Render one compact canonical JSON object. The returned string has no trailing newline. *)

val sort_diagnostics : Diag.t list -> Diag.t list
(** Sort diagnostics by source location, code, then cause. *)
