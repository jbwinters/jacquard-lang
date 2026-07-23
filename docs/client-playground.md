# Governance Decision-Chain Playground

The governance playground is a local, read-only explanation surface for the
frozen Workspace v0 profile. It renders one normalized decision-chain
document:

```text
request -> assessment -> verdict -> consent -> action or simulation -> outcome
```

Verified backend projections and explicitly illustrative fixtures use the same
presentation contract. Its purpose is to help a person inspect what the
document says Jacquard knows, what it does not know, and which committed
artifact supports each statement. It does not make a governance decision,
grant authority, record consent, execute an action, authenticate a document,
or verify evidence independently.

## Product boundary

The playground is a source-checkout research tool. It is not a hosted product,
an operator or approval console, an authentication boundary, or a production
security system. Task 160 authorizes a static local build and a CI-retained
build artifact; it does not authorize public deployment.

The supported surface is exactly Workspace v0. Arbitrary facades, raw effect
handlers, package workflows, persisted review sessions, registry integration,
and G5 posterior judgment are outside this version.

The application is offline by default:

- the development and preview servers bind to `127.0.0.1`;
- the application makes no outbound requests;
- there is no telemetry, analytics, cookie, service worker, remote font, CDN,
  or browser persistence;
- loaded data remains in memory and can be removed with the reset action.

Paths, summaries, identities, and configured resource evidence may be
sensitive. The viewer renders allowed values only as escaped text; escaping is
not redaction. The backend projection is designed to omit raw call content and
secret bytes, but the browser cannot recognize a secret placed inside an
otherwise allowed text field. Load only artifacts you are willing to keep in
the local browser process, and never put secret contents in fixtures.

## Trust boundary

The client accepts only the normalized
`jacquard-governance-decision-chain-v1` projection. It does not accept raw
`.jqd`, canonical forms, governance bundles, or unrelated JSON reports.

The OCaml backend derives the projection from typed, verified governance
reports using Jacquard's existing verifier, policy, identity, and canonical
hashing implementations. JavaScript validates the presentation schema and may
compare backend-supplied identity strings. It must not:

- evaluate policy or derive a verdict;
- derive authority or classify evidence;
- calculate canonical hashes;
- verify or join governance artifacts;
- interpret canonical subjects; or
- resolve an ambiguous record relationship.

The client therefore cannot upgrade an absent, partial, or ambiguous artifact
into stronger evidence. An artifact-backed stage links to a backend-supplied
full `HASH_V0` identity and artifact kind. When no committed artifact exists,
the interface says **No committed artifact** and does not manufacture an
identity.

## Projection contract

Every accepted document has the exact schema identifier
`jacquard-governance-decision-chain-v1` and profile `workspace-v0`. It contains
typed stages for request, assessment, verdict, consent, activity, and outcome,
plus:

- a source marker that distinguishes verified evidence from illustrative,
  backend-generated fixtures;
- backend-supplied full hashes and artifact kinds;
- typed authority entries rather than compact Jacquard text parsed by the
  client;
- an optional `parent_call_id` only for an already verified transformed call;
- exact evidence-limit strings;
- opaque canonical subjects rendered only as text; and
- no secret material.

Verdict states are exactly `Allow`, `Ask`, `Block`, and `Simulate`. Consent
states are exactly `Not required`, `Approved`, `Denied`, `Escalated`, `Stale`,
and `Missing`.

The four released live-attempt states remain exact data values:

- `attempt-outcome-unknown`
- `completed-without-receipt`
- `receipt-pending-completion`
- `reconciled-completed`

Unknown schema versions, profiles, states, artifact kinds, malformed hashes,
oversized documents, and fields outside the normalized schema fail closed.
That rejects explicit secret-bearing fields; it is not content inspection for
secrets hidden inside allowed text. Rejection is a client input error, not a
governance verdict.

Documents with `source: "fixture"` are explicitly illustrative in both data
and presentation. They exercise the complete rendering contract without
claiming that a verifier observed the represented event. Only
`source: "verified"` may describe a projection derived from a typed verified
report. The source field is document-supplied presentation provenance, not a
browser-authenticated claim; only the OCaml adapter establishes the verified
projection before serialization.

## Evidence language

The following labels are part of the presentation contract and are not
interchangeable:

- `Type-proven effect authority`
- `Configured resource evidence — not type-proven`
- `Simulation — not consent`
- `Approval bound to proposal`
- `Denial bound to proposal`
- `Escalation bound to proposal`
- `Consent rejected — stale approval`
- `No action attempted`
- `Attempt recorded — execution not proven`
- `Receipt digest recorded — receipt truth not proven`
- `Completion record present — rollback not proven`
- `Reconciled completion — provider truth not proven`
- `Transformed request — new call identity`
- `No simulator — no live fallback`
- `Outcome unknown — completion missing`

These distinctions are claim boundaries:

- configured resource evidence is not authority proven by a type row;
- simulation is not consent and does not prove simulator fidelity;
- an attempt record does not prove external execution;
- a receipt digest does not prove the truth of a provider receipt;
- a completion record does not prove rollback behavior;
- reconciliation does not prove provider truth;
- a transformed request has a new call identity; and
- missing completion leaves the outcome unknown.

## Accessible interaction

The chain is an ordered semantic list. Every stage has a heading, textual
state, keyboard focus target, and explicit evidence relationship. Status is
never communicated by color alone.

Full hashes remain available to inspect and copy. Evidence links move focus to
the corresponding artifact without changing the underlying data. All viewer
actions are keyboard-operable, visible focus is preserved, motion respects the
reduced-motion preference, and the layout remains distinguishable in
high-contrast modes.

The supported browser envelope is the pinned Chromium, Firefox, and WebKit
versions exercised in CI. Support is best-effort research-project support:
there is no service-level agreement, account system, incident-response
service, hosted availability promise, or migration promise beyond compatible
v1 documents.

## Verification contract

Checked-in examples are generated from typed OCaml values or verified reports,
not hand-authored client interpretations. They cover at least:

1. an allowed request;
2. a blocked request;
3. stale approval;
4. a transformed request with distinct parent and child call identities;
5. an attempted action with missing completion; and
6. a dry simulation.

The backend pins projection conformance and deterministic bytes. The client
pins schema rejection, snapshots, semantic non-confusion, hostile escaped
text, input-size limits, keyboard traversal, focus, accessibility, and the
absence of non-loopback network requests. CI runs frozen dependency
installation, linting, type checking, unit tests, browser tests, and a static
production build without deploying it.

## Running locally

From the repository root:

```sh
corepack enable
pnpm --dir playground/governance install --frozen-lockfile
pnpm --dir playground/governance run dev
```

Open the loopback address printed by Vite. The package's `README.md` documents
the exact fixture-generation, validation, browser-test, and production-build
commands.
