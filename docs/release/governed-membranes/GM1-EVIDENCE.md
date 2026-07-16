# Governed Membranes GM.1 Evidence

Status: reconstructible GM.1 overlay on dependency-integration commit
`95b2be5` (validated ET.6 plus GM.0).

GM.1 implements the versioned ring-3 governance values and pure policies from
the ratified membrane charter. It preserves the released ET.2 `Risk`,
`Verdict`, `Decision`, and `Audit` identities and the ET.6 `Proposal` and
`Approval` interfaces. Names that would collide with those frozen declarations
use a distinct `governance-*` carrier family.

## Contract

- `GovernanceVersion` currently has the single `GovernanceV0` constructor.
- `ToolError`, `GovernanceAuthority`, `GovernanceCall`,
  `GovernanceAssessment`, `GovernanceOutcomeSummary`, live/dry/stored policies,
  and `BoundPolicy a` are ordinary ring-3 values.
- Pure smart constructors return `Result` and reject NaN, infinities,
  out-of-range confidence, reversed policy thresholds, malformed operation
  names, unordered/duplicate authority, empty resource scope, and resource
  authority lacking its effect authority.
- Call identity is HASH_V0 over the versioned semantic subject and excludes
  display operation name, summary, and carried ID. Policy, assessment, and
  outcome identities use one deterministic versioned Code encoding each.
- `governance.make-call` accepts only a qualified operation name. The trusted
  pure resolver builtin locates the exact operation member of the currently
  resolved Store effect declaration and derives its hash. Validation repeats
  the lookup, so nonexistent or forged operation IDs fail through `Result`.
- `DryPolicy.min-confidence` remains validated and identity-bearing as required
  by the GM.0 schema, but it is not a dry verdict gate. Every non-Forbidden risk
  Simulates when a simulator exists; `NoSimulation` means only that it does not.
- `governance.validate-call` and `governance.validate-bound-{live,dry}-policy`
  recompute carried hashes and fail closed on forged values. Jacquard's kernel
  has no module-private constructor facility, so these verifiers are the
  required backstop at trust boundaries.
- Stable summaries omit Code arguments, preconditions, evidence, authority
  configuration, digests, error details, and `Secret`; no generic governance
  `Show` dictionary is published.

## Executable evidence

The ten-case `governance-core` suite pins the schemas and frozen ET.6
identities; table-tests confidence and policy bounds, operation names, and
authority envelopes; checks exact Call and BoundPolicy forgery refusal; covers
live and dry verdict laws; and checks safe summaries. Two QCheck laws contribute
110 generated cases for confidence acceptance and display-summary-independent
Call identity, and an 80-case property covers every dry risk/threshold branch.
Malformed-name and unresolved-operation tables are stored under
`corpus/governance/`.

The prelude hash golden contains every GM.1 declaration and derived identity.
The ring manifest assigns every new name to ring 3. Approval, taxonomy, and ring
suites are run together with GM.1 to demonstrate compatibility.

## Reproduction

```sh
eval "$(opam env)"
mkdir -p "$PWD/.scratch/tmp"
export TMPDIR="$PWD/.scratch/tmp"
opam exec -- dune build --root . @all
opam exec -- dune runtest --root . --force
opam exec -- dune build --root . @fmt
opam exec -- dune build --root . @doc
sha256sum -c docs/release/governed-membranes/GM1-MANIFEST.sha256
```

The GM.1 checkout contains 610 compiled Alcotest/QCheck cases and 32 cram
transcript files. Historical ET.2, ET.3, and ET.6 evidence packs remain
unchanged; this file and its manifest are a successor overlay.
