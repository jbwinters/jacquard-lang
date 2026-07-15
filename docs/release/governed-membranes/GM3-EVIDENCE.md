# Governed Membranes GM.3 Evidence

Status: reconstructible GM.3 policy overlay on validated GM.2 plus ET.3
integration commit `3e78a95`.

GM.3 completes the pure policy layer frozen by charter §6 and decisions D65,
D66, and D72. It is additive: the LivePolicy, DryPolicy, StoredPolicy, and
BoundPolicy carriers from GM.1 and the GovernanceProposal carrier from GM.2 are
unchanged. The implementation adds no kernel form, runtime serializer, native
intrinsic, world effect, Approval path, or live fallback.

## Validated policy boundaries

`prelude/23-governance-policy.jqd` adds validators that reapply the safe
LivePolicy and DryPolicy constructors to directly represented values. Live
construction rejects `auto-up-to > ask-up-to`; both policy types reject NaN,
infinity, and confidence outside inclusive `[0,1]`.

Safe StoredPolicy constructors accept only validated policies. Its canonical
Code is tagged `stored-live-policy-v0` or `stored-dry-policy-v0` and delegates
the nested bytes to the frozen GM.1 policy encoders. The representative policy
hashes are:

```text
LivePolicy(Low, High, 0.75)  90b89e26cc677201a904cc1757be0b78814aea45d13cbcd3fd66c9be56927e52
DryPolicy(0.75)              60c734f066602ee2c7846ed4b4ead349bd3820077508a6de771b2a6cfe9396a1
StoredPolicy.Live            a36470e6ca6572907676552bf34ff9f6b014477b72c9b5db7404614aaaeb3de0
StoredPolicy.DryRun          036336921aef6c48b284574788a8e509fe67d7ce31356f73ea815597ffc77be0
```

`governance.bind-stored-policy` derives the stored identity;
`governance.validate-bound-stored-policy` recomputes it. The live, dry, and
stored validators all reject a forged carried hash through `Result`. The bound
execution functions convert malformed policy/hash pairs and invalid observed
live confidence to `InvalidDecision` before evaluating a verdict.

## Total verdict laws

`governance.live-policy-verdict` requires a validated `BoundPolicy LivePolicy`
and finite observed confidence in `[0,1]`. Forbidden always returns Block.
Below `min-confidence`, no risk returns Allow: risks at or below `ask-up-to`
return Ask and higher risks return Block. At or above the inclusive threshold,
risks at or below `auto-up-to` return Allow, risks through `ask-up-to` return
Ask, and higher risks return Block.

`governance.dry-policy-verdict` requires a validated `BoundPolicy DryPolicy`.
Forbidden always returns Block. Every other risk returns Simulate iff the
caller has a pure simulator; otherwise it returns NoSimulation. No dry path can
return Allow or Ask. The frozen DryPolicy confidence field remains validated
and identity-bearing but does not gate simulation.

## Executable evidence

The existing fourteen-case `governance-core` suite now includes:

- all sixteen `(auto-up-to, ask-up-to)` pairs, with all six reversed pairs
  refused and all ten ordered pairs evaluated across four risks and observed
  confidence values `0.0`, `0.5`, `0.75`, and `1.0` (160 live verdicts);
- three valid dry confidence thresholds across four risks and both simulator
  states (24 dry verdicts);
- exact LivePolicy, DryPolicy, and both StoredPolicy Code/hash goldens;
- safe direct-value and stored-value validation plus forged live, dry, and
  stored BoundPolicy refusal;
- NaN, infinity, below-zero, above-one, and inclusive endpoint checks; and
- 80 generated numeric-boundary samples proving inclusive live comparison,
  under-confidence non-Allow behavior, and rejection outside `[0,1]`.

The full six-property QCheck lane remains 460 generated cases. The compiled
Alcotest/QCheck inventory remains 614 cases. Prelude golden and tier evidence
contain only the additive GM.3 terms, all assigned to ring 3.

The suite also pins these pre-existing type identities:

- LivePolicy: `313c11b97a460ed1c4b2fc3c215dc76e3af85378f9ec2146604094acf0fe9269`;
- DryPolicy: `465569b1f1b94025f3e40d3efe4fc99cd780e887fe1366da8b74011a810ffae1`;
- StoredPolicy: `f520783c93ebab3648d5996bc431c78e3a0e6e11135ec73424531e67fb7928f7`;
- BoundPolicy: `71eba002ffd98c2be9d0bf74e9bce53275ba87c763367450f8bef74a439fbf82`;
- GovernanceProposal: `c3acd6332f0fdb23bcc800edd64a11192d2744cc824447fbbd7c8d6069f487b8`.

ET.2 Decision, ET.6 Proposal and Approval, `code.hash`, and GM.1 GovernanceCall
remain pinned by the same suite.

## Reproduction

```sh
eval "$(opam env)"
mkdir -p "$PWD/.scratch/tmp"
export TMPDIR="$PWD/.scratch/tmp"
opam exec -- dune build --root . @all
cd test && ../_build/default/test/test_jacquard.exe test \
  'governance-core|approval|effect-taxonomy|rings|prelude' --compact --color=never
cd ..
opam exec -- dune runtest --root . test/cli/tiers.t --force
opam exec -- dune build --root . @fmt
sha256sum -c docs/release/governed-membranes/GM3-MANIFEST.sha256
```

Historical ET.6, GM.1, and GM.2 evidence manifests remain unchanged. GM.3
publishes a separate complete overlay.
