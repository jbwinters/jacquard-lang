# Governed Membranes GM.17A governance-explanation evidence

Status: release-hardening implementation overlay on exact integrated base
`58c80271e380892817a75bd5ef1fdc8f97e8b7ef`.

## Context

GM.14 made governance runs and action journals independently verifiable, and
GM.16 made the static Workspace membrane composition reviewable. A production
operator still had to join several verified records by hand to answer the
ordinary question “why was this exact proposal allowed, denied, or attempted?”
That made it too easy for a review UI or script to select an unrelated artifact,
repeat a stale policy verdict, or label an action with a driver that was never
committed.

GM.17A adds one bounded offline explanation command over the existing canonical
reconciliation package. It changes no language syntax, kernel form, effect or
operation identity, policy or Decision encoding, Audit v2 bytes, action-journal
bytes, driver implementation, evaluator, native compiler, or GM.14/GM.16
success-report contract.

## Public command and verification boundary

```text
jac governance explain PROPOSAL_ID
  --bundle RECONCILIATION_BUNDLE
  [--prelude DIR]
  [--store DIR]
  [--output-format text|json-v1]
  [--diagnostic-format text|json-v1]
```

`PROPOSAL_ID` is exactly 64 lowercase hexadecimal HASH_V0 digits. The command
uses the same bounded, race-detecting regular-file reader and canonical
one-form-plus-LF parser as `governance reconcile`. It then performs the complete
GM.14A run-bundle and GM.14B action-journal verification before selecting any
Proposal or writing success output. Parse, integrity, linkage, selection,
policy, or driver failure leaves stdout empty. Success output and diagnostics
choose their formats independently.

The reconciliation verifier exposes an abstract verified value so the trusted
projection can reuse the already verified canonical form. Existing
`verify_form`, `verify_string`, and `verify_file` results are mapped from the
same detailed verifier and retain their prior bytes and gap semantics.

## Exact proposal-scoped projection

After full verification, the command requires exactly one artifact with the
requested Proposal identity. It projects and reports:

- the reconstructed canonical `governance-proposal-v0`, rendering, summary,
  preview, and Proposal ID;
- the exact linked `governance-call-v0`, qualified Workspace operation name and
  operation ID, and raw authority envelope;
- the exact linked `bound-policy-v0` and policy ID;
- the exact assessment and assessment ID;
- the stable recomputed live-policy rule and the equal recorded verdict;
- the exact Approved, Denied, or Escalated Decision;
- relevant Evaluated, Consented, and optional Completed Audit entries in their
  original verified chain order, including record digests; and
- the exact matching attempt, canonical driver, receipt, and external-receipt
  digest state when such committed evidence exists.

Proposal/Call authority is checked again at the projection boundary. The full
run verifier has already rejected missing links, ambiguous Ask/consent links,
unrelated artifacts, wrong subject identities, parent-lineage errors, wrong
published Audit heads, and any package that does not account for every supplied
artifact.

## Stable live rules and action states

The report recomputes the live verdict from the exact `live-policy-v0` and
assessment rather than trusting the Audit verdict label. The stable rule IDs
are:

| rule ID | verdict condition |
|---|---|
| `live.forbidden` | risk is `forbidden`; `block` |
| `live.below-confidence-ask` | confidence is below minimum and risk is at or below ask; `ask` |
| `live.below-confidence-block` | confidence is below minimum and risk is above ask; `block` |
| `live.at-or-below-auto` | confidence meets minimum and risk is at or below auto; `allow` |
| `live.at-or-below-ask` | confidence meets minimum and risk is at or below ask; `ask` |
| `live.above-ask` | confidence meets minimum and risk is above ask; `block` |

An attempted action is accepted only for an Approved Decision, the `live`
branch, the selected consent record's exact digest, the selected Call, and the
frozen canonical Workspace leaf driver for that operation. Operation hashes,
names, and driver hashes come from the immutable shipped Workspace pin set, not
from mutable store lookup. The complete reconciliation verifier rejects wrong
authorization or branch linkage before projection. At the projection boundary,
wrong operation, operation-name drift, or a noncanonical driver fails E1533.

Denied and Escalated Decisions with no action evidence render `not-attempted`.
An Approved Decision with neither attempt nor completion also renders
`not-attempted`; the command does not turn authorization into execution. An
approved live completion without one unique matching attempt is a provenance
gap and fails E1533. Accepted attempts use one of four exact states:
`attempt-outcome-unknown`, `completed-without-receipt`,
`receipt-pending-completion`, or `reconciled-completed`.

## Success schemas and review-facts handoff

Text output is `governance-explain-v1`; compact JSON uses
`jacquard-governance-explain-report-v1`. Both are produced from one typed report
and carry the same semantic fields in deterministic order. JSON additionally
nests the A-available dynamic facts under
`jacquard-governance-review-facts-v1`: Proposal subject/rendering/summary/preview,
Call and operation, authority, policy, assessment, rule and verdict, Decision,
and committed action/driver state. This nested object is the stable handoff for
later review classification. It contains no placeholder for GM.17B static
simulator or provenance facts that are not available from this bundle.

The report states four explicit evidence limits: a committed driver is not
proof that it ran; an external-receipt digest is not proof that the receipt is
true; a resource scope is not a type-system proof; and missing completion is
not rollback.

## Diagnostics and hostile evidence

- E1530 rejects malformed Proposal text before bundle projection.
- E1531 rejects an absent requested Proposal after the package has been fully
  verified.
- E1532 rejects a recorded verdict that differs from the recomputed stable
  live rule.
- E1533 rejects unsupported Workspace operations, operation-name drift,
  noncanonical drivers, and approved completion without a unique attempt.

Before those projection-specific checks, the inherited E1300--E1515 run-bundle
and reconciliation diagnostics reject malformed or altered carriers, ambiguous
artifact/evaluation evidence, wrong authorization or branch linkage,
incompatible non-action evidence, repeated attempts or receipts, and other
integrity or linkage failures. In particular, repeated journal evidence is
rejected as E1513 and authorization/branch mismatch as E1515; it is not
relabeled E1533 by the explanation layer.

`test/test_governance_explain.ml` covers the canonical approved chain, Denied
and Escalated non-action, deterministic text/JSON rendering, the nested review
facts schema, wrong rule, wrong driver, absent selection, malformed ID,
completion-without-attempt, journal tampering, and preservation of the existing
reconciliation result. `test/cli/governance-explain.t` pins the public approved
and denied fixtures, exact operation/rule/driver facts, text/JSON agreement,
repeat-byte determinism, independent diagnostic formatting, empty failure
stdout, missing selection, wrong driver, and tamper refusal.

The GM.17A overlay adds four compiled Alcotest cases and one cram transcript to
the exact base inventory. No documentation example, corpus golden, surface
carrier, prelude declaration, or frozen evidence manifest is changed.

## Claim boundary

GM.17A proves that one report is a deterministic projection of one exact
Proposal and its linked facts in a completely verified reconciliation package.
It proves equality to the canonical committed Workspace driver identity when
an attempt exists. It does not prove execution, driver correctness, provider
identity, receipt truth, external freshness, resource isolation, rollback,
retry safety, or publisher authenticity. It does not execute Jacquard code or
add authority.

## Reproduction

```sh
eval "$(opam env)"
mkdir -p "$PWD/.scratch/tmp"
GM17A_TMP="$(mktemp -d "$PWD/.scratch/tmp/gm17a.XXXXXX")"
export TMPDIR="$GM17A_TMP"
opam exec -- dune build --root "$PWD" @all
cd test && ../_build/default/test/test_jacquard.exe test \
  governance-explain --compact --color=never
cd ..
opam exec -- dune build --root "$PWD" @test/cli/runtest
opam exec -- dune runtest --root "$PWD" --force
opam exec -- dune build --root "$PWD" @test/cli/gm12b-evidence --force
opam exec -- dune build --root "$PWD" @fmt
opam exec -- dune build --root "$PWD" @doc
scripts/release/reproduce-0.1.sh
sha256sum -c docs/release/governed-membranes/GM17A-MANIFEST.sha256
```
