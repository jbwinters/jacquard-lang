# Governed Membranes GM.2 Evidence

Status: reconstructible GM.2 successor overlay on validated GM.1 commit
`b5587ce`.

GM.2 completes the GM.0 two-level identity contract without changing the
released ET.6 `Proposal`/`Approval` declarations or any GM.1 declaration.
`code.hash : (Code) ->{} Hash` remains the single pure HASH_V0 boundary over
the canonical compact, metadata-erased Code bytes; GM.2 adds no kernel form,
runtime serializer, or native intrinsic.

## Canonical identities

The representative `fs.write` Call semantic Code renders exactly as the
versioned `governance-call-v0` tuple and hashes to:

```text
9426cb4c99c5120487c8c421f948c1de6b4425d2a859a6de2536bd85c6136a85
```

The representative successor review artifact commits `GovernanceV0`, that
Call ID, the validated live BoundPolicy ID, the GovernanceAssessment ID, the
Call's exact authority envelope, optional GovernanceOutcomeSummary preview,
reviewed rendering, and summary. Its `governance-proposal-v0` Code hashes to:

```text
88e2c60b4e97c732917fc99a3e7a05eb85e79295fcfed053cae3a5b5421fd26e
```

The carried Call and Proposal IDs are absent from their own hash inputs.
Call display name and summary are also absent from Call identity. Proposal
rendering and summary are exact review inputs.

## Safe construction and validation

`prelude/22-governance-identity.jqd` adds the distinct ring-3
`GovernanceProposal` carrier. `governance.make-proposal` accepts a validated
GovernanceCall, `BoundPolicy LivePolicy`, GovernanceAssessment, rendering,
summary, and optional GovernanceOutcomeSummary. It derives the three
constituent IDs and copies authority from the Call, so the smart path cannot
repeat or substitute those fields.

`governance.validate-proposal` checks authority and preview structure and
recomputes the carried proposal hash. The stronger
`governance.validate-proposal-artifacts` revalidates Call, BoundPolicy,
Assessment, and Proposal, then rejects a mismatched call ID, policy ID,
assessment ID, or authority envelope. Every failure is `Result` data.
Jacquard still lacks module-private constructors, so these verifier backstops
remain mandatory at trust boundaries.

The schema encoder reuses GM.1's version, authority-list, assessment, policy,
and outcome encoders and the existing ET.6 `code.hash` boundary. It does not
duplicate the canonical serializer. The golden tests also pin that these
pre-existing identities remain unchanged:

- ET.6 Proposal type:
  `5eff01f74c47214e9c4ebec752a75959ddb0bb4fb34a5cc5d5bb58c0e47dc9b7`;
- Approval effect:
  `362425a29077a7efbcc37047182e579f46199a50473045eb4126a917dfc2a196`;
- `code.hash` term:
  `83b76604ebb921438d4ff5ae92173fad8c1d527dc91ae1e39c419ad5310d0c44`;
- GM.1 GovernanceCall type:
  `20824137b34985dabf9e6bb0c20cf9987c1ca93b5cdd8d1da60cbc69550efc27`.

## Executable evidence

The fourteen-case `governance-core` suite pins both exact Code renderings and
HASH_V0 goldens, safe construction, forged carried-hash refusal, and
cross-artifact authority refusal. QCheck executes 460 generated cases across
these identity laws:

- Call formatting metadata and display summary are inert;
- operation, arguments, authority, and preconditions each change Call ID;
- formatting metadata in reviewed Code is inert;
- call, policy, assessment, authority, preview, semantic rendering, and
  summary each change Proposal ID;
- existing confidence and dry-policy laws remain green.

The prelude golden adds only the new file's declarations. Ring evidence places
every new name in ring 3. The compiled Alcotest/QCheck inventory is 614 cases;
ET.6 Approval, GM.1, taxonomy, ring, prelude-golden, and tier-focused checks
provide compatibility coverage.

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
sha256sum -c docs/release/governed-membranes/GM2-MANIFEST.sha256
```

Historical ET.6 and GM.1 evidence manifests remain unchanged. GM.2 publishes a
separate complete successor overlay.
