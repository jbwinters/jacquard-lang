(** Trusted GM.21 bridge between hash-resolved risk models and the unchanged v0 Judge/gate.

    The exact path resolves and typechecks a stored [(GovernanceCall) ->{Dist} Risk] term, runs
    bounded exhaustive inference, and emits identity-bound v1 evidence. The sampled path emits a
    distinct non-authorizing carrier and cannot project an assessment. *)

val exact_semantics_code : Form.t
(** Canonical descriptor whose HASH_V0 identity selects the exact v1 enumeration semantics. *)

val approximate_semantics_code : Form.t
(** Canonical descriptor for the non-authorizing seeded likelihood-weighting semantics. *)

type exact_replay = {
  call_id : Hash.t;
  posterior_id : Hash.t;
  projection_id : Hash.t;
  assessment_id : Hash.t;
  assessment_code : Form.t;
}
(** Canonical identities and effective v0 assessment reproduced by one exact offline replay. *)

val replay_exact :
  Eval.ctx ->
  builtin_signatures:(Hash.t * Types.scheme) list ->
  model_ref:Value.t ->
  config:Value.t ->
  source_evidence:Value.t ->
  call:Value.t ->
  baseline:Value.t ->
  rule:Value.t ->
  (exact_replay, string) result
(** [replay_exact ctx ~builtin_signatures ~model_ref ~config ~source_evidence ~call ~baseline ~rule]
    resolves and rechecks the exact model, reruns bounded exhaustive inference, revalidates every
    exact carrier identity, and projects one independently produced baseline assessment. Expected
    validation and replay failures are returned as stable explanatory strings. *)

val run_exact_builtin :
  Eval.ctx ->
  builtin_signatures:(Hash.t * Types.scheme) list ->
  Value.t list ->
  (Value.t, Runtime_err.t) result
(** Native implementation of [posterior.run-exact-v1]. Expected validation and inference failures
    are returned as the language's [Result Text ExactPosteriorRiskResultV1]. *)

val project_exact_builtin : Eval.ctx -> Value.t list -> (Value.t, Runtime_err.t) result
(** Native implementation of [posterior.project-exact-v1]. It revalidates all carried exact
    identities, conservatively joins risk, and preserves baseline confidence and reasons. *)

val sample_evidence_builtin :
  Eval.ctx ->
  builtin_signatures:(Hash.t * Types.scheme) list ->
  Value.t list ->
  (Value.t, Runtime_err.t) result
(** Native implementation of [posterior.sample-evidence-v1]. It returns only the visibly
    non-authorizing approximate evidence carrier. *)
