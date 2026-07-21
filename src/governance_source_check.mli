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

type topology =
  | Live
  | Dry
  | Forwarded_live of int
      (** The exact verified root topology. [Forwarded_live n] contains [n] forwarding layers before
          the canonical live leaf. *)

type verified_member = {
  member_name : string;
  member_hash : Hash.t;
  member_body : Kernel.expr;
  member_group : Hash.t list;
}
(** A source-owned term member and the source-order identity group used to resolve [GroupRef]. *)

type verified_source
(** An abstract, fully GM16-verified source handoff. Values retain the isolated store/checker,
    canonical root and payload thunk, exact topology, and source-owned member index. *)

val version : string
(** The exact source-check report version. *)

val schema : string
(** The exact JSON success-report schema. *)

val canonical_workspace_driver : operation:Hash.t -> (string * string * Hash.t) option
(** [canonical_workspace_driver ~operation] returns the exact released Workspace v0 leaf-driver
    operation name, driver name, and driver identity for one of the three pinned facade operations.
    It compares [operation] by HASH_V0 identity and never resolves a mutable name; non-Workspace
    identities return [None]. *)

val verify : Store.t -> Check.ctx -> Kernel.decl list -> (report, Diag.t list) result
(** [verify store checker declarations] verifies one unambiguous canonical Workspace source root and
    the complete shipped profile behind it. [declarations] must already have been resolved, stored,
    and typechecked in [store] using [checker], whose primitive signatures must have been frozen
    before the source was inserted. Traversal stops only at exact pinned membrane boundaries.
    Missing, ambiguous, unsupported, or residual-authority roots return E1413; the outward root row
    must exactly match the fixed live or dry profile because the v1 report has no residual-authority
    field. Malformed profile facts return their existing E1400--E1412 meanings. The function does
    not mutate [store]. *)

val verify_detailed :
  Store.t -> Check.ctx -> Kernel.decl list -> (verified_source, Diag.t list) result
(** [verify_detailed] performs the same verification as [verify] and returns the trusted source
    handoff required by additive static analyses. It has exactly the same diagnostics and does not
    evaluate source expressions. *)

val verified_report : verified_source -> report
(** Recover the frozen GM16 report. [verify] maps this accessor over [verify_detailed]. *)

val verified_root : verified_source -> string * Hash.t
(** Return the canonical source root's declared name and HASH_V0 identity. *)

val verified_topology : verified_source -> topology
(** Return the exact verified live, dry, or forwarding topology. *)

val verified_payload : verified_source -> Kernel.expr
(** Return the body of the root boundary's zero-argument payload thunk. *)

val verified_members : verified_source -> verified_member list
(** Return all source-owned members and their exact source-order group mappings. *)

val verified_store : verified_source -> Store.t
(** Return the isolated, pinned analysis store used for verification. *)

val verified_checker : verified_source -> Check.ctx
(** Return the checker paired with the isolated analysis store. *)

val render_text : report -> string
(** Render the deterministic human report, including the runtime-artifact verification handoff. *)

val render_json_v1 : report -> string
(** Render one compact canonical JSON object. The returned string has no trailing newline. *)

val sort_diagnostics : Diag.t list -> Diag.t list
(** Sort diagnostics by source location, code, then cause. *)
