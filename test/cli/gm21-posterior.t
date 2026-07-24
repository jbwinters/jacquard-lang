GM.21 is an additive exact posterior-aware Judge adapter. Its historical
overlay binds the implementation, public carriers, focused laws, documentation,
and evidence without changing the historical GM.22 release manifest. SC.17
owns full reconstruction now that its safety correction supersedes two shared
integration files.

  $ (cd ../.. && test "$(sha256sum docs/release/governed-membranes/GM21-MANIFEST.sha256 | awk '{print $1}')" = 19603651590eb6de890a7e3597b009403f03234d6d5f022b076497d8a638e45f)
  $ (cd ../.. && test "$(sha256sum scripts/release/check-gm21-manifest.sh | awk '{print $1}')" = 14fcc2ec9274d1dde793ef534591c4d757934089d0510424e52187e9b0fd5a82)
  $ echo "GM.21 historical attestation anchors are byte-consistent"
  GM.21 historical attestation anchors are byte-consistent

The public handler retains the unchanged outer Judge and Throw effects. Replay
is pure after its exact model and evidence artifacts are supplied.

  $ export JACQUARD_PRELUDE=$PWD/../../prelude
  $ jac check ../../prelude/30-posterior-risk-handler.jqd --print-sigs
  posterior.replay-exact-v1 : (PosteriorRiskModelRefV1, PosteriorExactConfigV1, Code, GovernanceCall, GovernanceAssessment, PosteriorRuleV1, GovernanceAssessment) ->{} Result Text GovernanceAssessment
  judge.posterior-exact-v1 : forall a | e. (() ->{Judge, Throw | e} a, PosteriorRiskModelRefV1, PosteriorExactConfigV1, Code, PosteriorRuleV1) ->{Judge, Throw | e} a
