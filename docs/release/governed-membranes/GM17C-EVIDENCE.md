# Governed Membranes GM.17C machine review-diff evidence

Status: release-hardening implementation overlay on exact integrated base
`b17c4297de46364034a7548f641ecdae6333c3cb`.

## Scope

GM.17C adds one pure public OCaml module, `Governance_review_diff`, for later
package tooling. It adds no CLI, package manager, registry, persisted snapshot,
JSON ingestion boundary, language form, runtime behavior, authority grant, or
safety decision. Existing `jac governance explain`, `jac why-effect`, and
`jac diff` bytes and schemas are unchanged.

The module projects typed dynamic facts directly from
`Governance_explain.report` and typed static facts directly from
`Governance_why_effect.report`. Their shared nested
`jacquard-governance-review-facts-v1` label does not make the families
interchangeable. A validated snapshot may contain either or both families; if
both are present, exact operation identity and any jointly available attempted
driver identity must agree.

The static projection retains the complete GM.17B source-root identity and
attribution chains. The public classification and report records are private:
callers may inspect fields but cannot forge schema, completeness, sort order,
or evidence-limit invariants.

## Classification contract

Static facade membership and collections normalize by exact HASH_V0 identity.
Conflicting duplicate labels or operation details fail E1540; reached detail
outside the complete facade set fails E1541. Exact operation identities, never
names, determine facade addition and removal. For a common operation with both
details, a strict driver-row superset is `driver-row-widened`, a strict subset
is `driver-row-narrowed`, and incomparable sets are `driver-row-changed`.
Policy, simulator, normalizer, driver, authority, label, summarizer, and other
semantic changes remain review-visible.

Source-root hash changes are `source-root-changed`. Attribution chains
canonicalize by ordered source-path identities, exact application member and
ordinal, operation identity, ordered forwarding layers, live leaf, driver, and
raw effect. Chain collection order is non-semantic; adding or removing a chain,
one versus two distinct application sites, or changing a path, ordinal, or
forwarding layer is `attribution-changed`. Display names never establish chain
identity. All retained chain identities participate in cross-field duplicate
label validation, and cross-endpoint name drift remains `label-changed`.
Compatible requested-effect hash comparisons likewise retain name drift as
`label-changed`.

`operation-rendering-only` requires only the summarizer identity to change
while the facade operation, authority, normalizer, simulator, driver, row, and
labels agree. `proposal-rendering-only` requires semantic equality of Call,
authority, bound policy, assessment, preview, evaluation, and Decision
kind/content; both endpoints must have no attempted action evidence. Decision
comparison recognizes only exact released `approved-v1`, `denied-v1`, and
`escalate-v1` shapes and ignores only the endpoint-specific hash in the first
carried `(hash #...)` Proposal slot. It compares every approver, reason, and
Approved evidence field exactly; arbitrary nested proposal-like hashes are
never rewritten.
Rendering-only is exclusive and review-required, not a harmlessness claim.

GM.17B reached detail is query-scoped even though `facade_operations` is
complete. A common facade operation missing detail on either endpoint produces
the stable `operation-not-reached` availability fact and `partial`
completeness, not a diagnostic. `no-change` is emitted only when every supplied
family comparison is available and equal. Empty attribution chains remain no
proof of runtime absence.

The deterministic `jacquard-governance-diff-report-v1` shape is `schema`,
`completeness`, sorted `changes`, sorted `unavailable`, and fixed evidence
limits. Kind rank, subject identity, and old/new identities determine ordering.
Synthetic comparison fingerprints use framed, versioned, semantic domains;
equal member vectors in authority, driver-row, and attribution aggregates do
not share a fingerprint. Producer-supplied HASH_V0 identities are unchanged.
Text and compact JSON render the same typed report. The report grants no
authority, proves no external execution, proves no runtime absence, and assigns
no safety verdict.

E1539 rejects mismatched producer-family comparisons, static authority queries,
or exact A/B operation/driver linkage. E1540 rejects conflicting facts for one
identity. E1541 rejects malformed internal invariants. Legitimate query
incompleteness is not an error.

## Evidence matrix

Five focused compiled Alcotest cases cover:

- facade addition and removal plus widened, narrowed, and incomparable rows;
- policy, simulator, normalizer, driver, positive operation/proposal
  rendering-only over exact released Decision carriers, and negative
  attempted/nested-evidence rendering-only classifications;
- source-root and attribution additions/removals, distinct application sites,
  paths, forwarding layers, chain-order invariance, name-only drift, partial
  unavailable detail, and fully available no-change;
- exact dynamic/static operation and attempted-driver linkage, mismatches,
  conflicting duplicates, malformed reached detail, and family mismatch; and
- identity-set and attribution-chain input shuffling, fixed ordering, combined
  dynamic/static field-level text/JSON parity, evidence limits, and repeated
  renderer bytes.

The overlay raises the compiled inventory from 794 to 799 cases. The 48 cram
transcripts and 27 executable documentation examples are unchanged.

## Durable limit

One query-scoped GM.17B report cannot prove complete package-wide driver or
simulator equivalence. Callers must retain `partial` and its unavailable facts
instead of upgrading absence of detail into equality.

## Reproduction environment debt

The compiled test harness creates temporary stores from process ID plus a
per-process counter and reopens an existing pathname. A long-lived persistent
TMPDIR can therefore collide with a stale store after PID reuse; a completed
prelude load has hidden private scheduler/governance names, so reopening that
store and loading the prelude again fails during later same-file resolution.
This is pre-existing test-harness environment debt, reproduced unchanged at
the exact GM.17C base. It is not caused by review-diff module initialization and
does not justify a prelude change. Evidence commands must use a newly created,
empty, repository-local TMPDIR for each run.

## Reproduction

```sh
eval "$(opam env)"
mkdir -p "$PWD/.scratch"
export TMPDIR="$(mktemp -d -p "$PWD/.scratch" gm17c-evidence-tmp.XXXXXX)"
opam exec -- dune build --root "$PWD" @all
opam exec -- dune exec --root "$PWD" test/governance_review_diff_focused.exe
opam exec -- dune runtest --root "$PWD" --force
opam exec -- dune build --root "$PWD" @fmt
opam exec -- dune build --root "$PWD" @doc
scripts/release/reproduce-0.1.sh
sha256sum -c docs/release/governed-membranes/GM17C-MANIFEST.sha256
```
