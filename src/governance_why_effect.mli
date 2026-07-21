(** Conservative, identity-based Workspace effect-chain attribution for fully GM16-verified source.
*)

type identity = { name : string; hash : Hash.t }

type chain = {
  source_path : identity list;
  operation : identity;
  forwarding_layers : identity list;
  live_leaf : identity;
  driver : identity;
  raw_effect : identity;
}

type operation_fact = {
  operation : identity;
  raw_authority : identity list;
  normalizer : identity;
  summarizer : identity;
  simulator : identity;
  driver : identity;
  driver_introduced_raw_row : identity list;
}

type report = {
  requested_effect : identity;
  source_root : identity;
  topology : string;
  facade : identity;
  facade_operations : identity list;
  reached_operations : operation_fact list;
  chains : chain list;
}

val schema : string
(** The exact outer JSON schema, [jacquard-why-effect-report-v1]. *)

val facts_schema : string
(** The exact nested review-facts schema, [jacquard-governance-review-facts-v1]. *)

val analyze :
  effect_name:string -> Governance_source_check.verified_source -> (report, Diag.t list) result
(** [analyze ~effect_name source] attributes exact Workspace v0 applications that can introduce the
    released [Fs], [Net], or [Secret] effect. [effect_name] is one of those exact display names or
    its exact released HASH_V0 identity. Source is never evaluated. The analysis refuses the
    complete report (E1534--E1538) when a reachable callable, handler, splice, group reference, or
    traversal budget prevents safe attribution. An empty [chains] list means no matching
    attributable Workspace application was found; it is not proof of runtime absence. *)

val render_text : report -> string
(** Render deterministic reviewer-oriented text with a trailing newline. *)

val render_json_v1 : report -> string
(** Render one compact deterministic JSON object without a trailing newline. *)

val sort_diagnostics : Diag.t list -> Diag.t list
(** Sort diagnostics using the frozen governance diagnostic order. *)
