(** Pure machine-review classification over GM.17A dynamic facts and GM.17B static facts. *)

type identity = { name : string; hash : Hash.t }
(** An exact HASH_V0 identity with a non-authoritative display label. *)

type dynamic_facts
(** Proposal-scoped facts derived only from a verified {!Governance_explain.report}. *)

type static_facts
(** Query-scoped Workspace facts derived only from a verified {!Governance_why_effect.report}. *)

type snapshot
(** One comparison endpoint. A snapshot has at least one producer family and, when both families are
    present, their exact operation and attempted-driver identities agree. *)

type change_kind =
  | Facade_added
  | Facade_removed
  | Facade_changed
  | Source_root_changed
  | Driver_row_widened
  | Driver_row_narrowed
  | Driver_row_changed
  | Policy_changed
  | Simulator_changed
  | Normalizer_changed
  | Driver_changed
  | Authority_changed
  | Attribution_changed
  | Operation_rendering_only
  | Proposal_rendering_only
  | Label_changed
  | Call_changed
  | Assessment_changed
  | Preview_changed
  | Evaluation_changed
  | Decision_changed
  | Attempt_changed
  | Summarizer_changed
  | Proposal_rendering_changed
  | Other_semantic_change

type change = {
  kind : change_kind;
  subject : identity;
  old_identity : identity option;
  new_identity : identity option;
}
(** One review-required change. Rendering-only kinds are explicit and exclusive; they do not express
    a safety verdict. *)

type availability_side = Old | New | Both

type unavailable = { subject : identity; side : availability_side; reason : string }
(** Missing query-scoped detail. [reason] is currently exactly [operation-not-reached]. *)

type classification = private { changes : change list; unavailable : unavailable list }
(** A deterministically sorted family-local classification. *)

type completeness = Complete | Partial | No_change

type report = private {
  schema : string;
  completeness : completeness;
  changes : change list;
  unavailable : unavailable list;
  evidence_limits : string list;
}
(** The combined, deterministic machine-review report. It grants no authority, proves no execution
    or runtime absence, and assigns no safety verdict. *)

val schema : string
(** The exact report schema, [jacquard-governance-diff-report-v1]. *)

val dynamic_facts_of_explain : Governance_explain.report -> dynamic_facts
(** Projects the dynamic review-facts family without changing or reparsing GM.17A output. *)

val static_facts_of_why_effect : Governance_why_effect.report -> static_facts
(** Projects the complete typed static review-facts family without changing or reparsing GM.17B
    output, including source-root identity and attribution chains. Empty attribution chains remain
    unrelated to runtime absence. *)

val make_snapshot :
  dynamic:dynamic_facts option -> static:static_facts option -> (snapshot, Diag.t list) result
(** Builds one endpoint and validates cross-family exact identity linkage. A missing family is
    legal, but a snapshot with neither family, an operation mismatch, or an attempted-driver
    mismatch returns E1539. Conflicting duplicate facts return E1540 and malformed internal
    invariants return E1541. *)

val classify_dynamic :
  old_:dynamic_facts -> new_:dynamic_facts -> (classification, Diag.t list) result
(** Classifies one old/new GM.17A pair. Proposal rendering-only requires equality of Call,
    authority, policy, assessment, preview, evaluation, normalized Decision content and kind, and
    requires both sides to have no attempted action evidence. *)

val classify_static : old_:static_facts -> new_:static_facts -> (classification, Diag.t list) result
(** Classifies one old/new GM.17B pair. Facade membership and rows compare exact identity sets.
    Source root and attribution paths, application member/ordinal, forwarding layers, live leaf,
    driver, and raw effect remain review-visible; chain collection order and names are non-semantic.
    Common facade operations missing reached detail produce [operation-not-reached], not a
    diagnostic. Incompatible requested-effect queries return E1539. *)

val compare : old_:snapshot -> new_:snapshot -> (report, Diag.t list) result
(** Combines the same supplied producer families at both endpoints. A family present at only one
    endpoint returns E1539. [No_change] is returned only when every supplied comparison is available
    and equal; required unavailable detail makes the report [Partial]. *)

val change_kind_to_string : change_kind -> string
(** Returns the stable lowercase machine spelling for a change kind. *)

val completeness_to_string : completeness -> string
(** Returns [complete], [partial], or [no-change]. *)

val render_text : report -> string
(** Renders fixed-order deterministic text with a trailing newline. *)

val render_json_v1 : report -> string
(** Renders one compact deterministic JSON object without a trailing newline. *)
