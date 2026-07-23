(** Additive, presentation-only projection for the governed Workspace playground. *)

type authority =
  | Effect of { effect_id : Hash.t }
  | Resource of { effect_id : Hash.t; configuration_id : Hash.t; opaque_subject : string }
      (** Typed authority evidence. Resource scopes are deliberately represented only by a
          backend-made opaque subject, so this type cannot disclose a scope or other call content to
          a browser. *)

type stage =
  | Request
  | Assessment
  | Verdict
  | Consent
  | Activity
  | Outcome  (** The six fixed, ordered decision-chain stages. *)

type source =
  | Verified
  | Fixture
      (** [Fixture] values are illustrative examples only and never assert verification provenance.
      *)

type verdict = Allow | Ask | Block | Simulate  (** Closed presentation verdict vocabulary. *)

type consent =
  | Not_required
  | Approved
  | Denied
  | Escalated
  | Stale
  | Missing
      (** Closed presentation consent vocabulary. [Stale] and [Missing] are fixture-only until a
          verified explanation carrier publishes corresponding typed evidence. *)

type fixture_scenario =
  | Allow_fixture
  | Block_fixture
  | Stale_approval_fixture
  | Transformed_call_fixture
  | Missing_completion_fixture
  | Dry_simulation_fixture  (** Deterministic illustrative scenarios for the playground. *)

type t
(** A validated [workspace-v0] decision-chain presentation model. Verified values are constructed by
    {!of_explain} after checking the typed explanation's cross-artifact invariants. Illustrative
    values are constructed only by {!fixture} and carry explicit fixture provenance. *)

val schema : string
(** Exact presentation schema: [jacquard-governance-decision-chain-v1]. *)

val profile : string
(** Exact source profile accepted by this projection: [workspace-v0]. *)

val evidence_limits : string list
(** Exact inherited evidence limits from {!Governance_explain}; the projection adds no claims. *)

val of_explain : Governance_explain.report -> (t, Diag.t list) result
(** [of_explain report] builds the six-stage presentation model from one existing, typed, verified
    governance explanation. It never evaluates policy, recomputes a verdict, or exposes rendered
    subject content. Malformed carrier shapes, inconsistent identities, unsupported decision or
    attempted-action states, and audit ordering violations return [E1542]. *)

val fixture : fixture_scenario -> t
(** [fixture scenario] creates a deterministic typed illustrative chain. It never parses a client
    payload, verifies a package, or claims verifier provenance; its JSON has [source = "fixture"]
    and [illustrative = true]. *)

val render_json_v1 : t -> string
(** [render_json_v1 chain] returns one compact deterministic JSON object without a trailing newline.
    All form-derived subjects are opaque, ASCII backend labels; JSON escaping is performed by
    [Yojson]. *)

val project_json_v1 : Governance_explain.report -> (string, Diag.t list) result
(** Validate and render a decision-chain JSON document in one step. It has the same failures as
    {!of_explain}. *)
