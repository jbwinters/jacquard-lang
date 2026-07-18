(** Canonical metadata for the blessed effect taxonomy.

    Runtime classification is keyed only by a resolved [Hash.t]. Names in this module are
    presentation metadata and never authorize or bless an effect. Reserved interfaces remain in the
    versioned catalogs but cannot enter a registry until their first real declaration hash is
    frozen. *)

type tier = Control | Uncertainty | Meta | World | Model | Governance | Concurrency
type risk = No_risk | Low | Medium | High | Special
type namespace = Official

type interface =
  | Released of { version : string; hash : Hash.t }
  | Reserved of { first_version : string }

type metadata = {
  display_name : string;
  index_name : string;
  namespace : namespace;
  tier : tier;
  default_risk : risk;
  reviewer_meaning : string;
  interface : interface;
}

type t

type registration_error =
  | Missing_resolved_identity of string
  | Reserved_catalog_name of string
  | Duplicate_identity of Hash.t
  | Duplicate_display_name of string
  | Duplicate_index_name of string

val empty : t
(** The empty resolved-identity registry. *)

val register : t -> metadata -> (t, registration_error) result
(** [register registry metadata] adds one released interface. It rejects reserved entries and any
    attempt to retag their frozen names as released, plus any duplicate identity, blessed display
    name, or official index name, without changing [registry]. *)

val catalog_v1 : metadata list
(** The frozen v1 snapshot: all 26 original ratified entries. *)

val catalog_v2 : metadata list
(** The additive v2 snapshot: the exact v1 prefix followed by [GovernanceApprovalV1]. *)

val catalog : metadata list
(** The current taxonomy snapshot, presently {!catalog_v2}. *)

val canonical_v1 : t
(** The resolved identities from the frozen v1 snapshot. *)

val canonical_v2 : t
(** The resolved identities from the additive v2 snapshot. *)

val canonical : t
(** The current canonical registry, presently {!canonical_v2}. *)

val entries : t -> metadata list
(** [entries registry] returns its entries in stable display-name order. *)

val find : t -> Hash.t -> metadata option
(** [find registry identity] classifies only by exact resolved identity. *)

val find_canonical : Hash.t -> metadata option
(** [find_canonical identity] is [find canonical identity]. *)

val canonical_order : Hash.t -> int option
(** [canonical_order identity] is {!canonical_order_v2}. *)

val canonical_order_v1 : Hash.t -> int option
(** [canonical_order_v1 identity] returns its zero-based position in the frozen v1 snapshot. *)

val canonical_order_v2 : Hash.t -> int option
(** [canonical_order_v2 identity] returns its zero-based position in the additive v2 snapshot.
    Reserved rows retain their positions but never match. *)

type style = Plain | Ansi

val tier_name : tier -> string
(** [tier_name tier] returns the frozen lowercase taxonomy spelling. *)

val risk_name : risk -> string
(** [risk_name risk] returns the frozen lowercase taxonomy spelling. *)

val interface_hash : metadata -> Hash.t option
(** [interface_hash metadata] returns a real released identity, never a fabricated reserved hash. *)

val render_metadata : ?style:style -> metadata -> string
(** [render_metadata metadata] renders the stable blessed name, tier/risk, and reviewer meaning.
    [Plain] is deterministic and is the default; [Ansi] colors only the blessed risk token. *)

val qualify_user_hint : name_hint:string -> Hash.t -> string
(** [qualify_user_hint ~name_hint identity] preserves a canonical [pk:] package hint. When package
    metadata is unavailable, it returns the honest deterministic fallback
    [unpackaged:<hash-prefix>/<name>] rather than inventing a publisher. *)

val render_resolved : ?style:style -> name_hint:string -> Hash.t -> string
(** [render_resolved ~name_hint identity] renders blessed metadata only for an exact registry hit.
    Unknown effects retain [name_hint], include their full identity, and are always uncolored and
    unrated. *)

val render_manifest_requirement : ?style:style -> name_hint:string -> Hash.t -> string
(** Like {!render_resolved}, but uses the lowercase official index name for a blessed effect so CLI
    grant spelling remains evident. *)

val registration_error_to_string : registration_error -> string
(** [registration_error_to_string error] renders a deterministic developer-facing explanation. *)
