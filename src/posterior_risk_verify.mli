(** Posterior-aware offline verification layered on the unchanged Governance run-bundle verifier. *)

type replay_artifacts = {
  model_ref : Value.t;
  config : Value.t;
  source_evidence : Value.t;
  call : Value.t;
  baseline : Value.t;
  rule : Value.t;
}
(** Runtime artifacts required to resolve and rerun one exact posterior assessment. The baseline
    must be an independently produced Governance v0 assessment. *)

type verdict =
  | Allow
  | Ask
  | Block
      (** Live-policy Governance v0 verdicts supported by this verifier. Dry policy is rejected
          because a run bundle does not bind the simulator-availability input needed to reproduce
          its verdict. *)

type report = {
  governance : Governance_run_bundle.report;
  entry_index : int;
  call_id : Hash.t;
  policy_id : Hash.t;
  posterior_id : Hash.t;
  projection_id : Hash.t;
  assessment_id : Hash.t;
  verdict : verdict;
}
(** Evidence from one bundle whose v0 structure, exact posterior replay, assessment, and live-policy
    verdict all verified. *)

val verify_form :
  ctx:Eval.ctx ->
  builtin_signatures:(Hash.t * Types.scheme) list ->
  file:string ->
  replay:replay_artifacts ->
  Form.t ->
  (report, Diag.t list) result
(** [verify_form ~ctx ~builtin_signatures ~file ~replay bundle] first runs
    {!Governance_run_bundle.verify_form} without changing its claim. It then resolves and reruns the
    exact posterior evidence, requires exactly one Evaluated entry for the replayed Call, requires
    byte-exact equality with its committed effective assessment, and recomputes the unchanged live
    Governance v0 verdict. Unsupported policy modes, ambiguous linkage, and every replay or identity
    drift fail closed with E1548 or E1549. *)
