# Governed Membranes GM.14A/GM.14B Evidence

Status: additive GM.14B overlay on exact integrated GM.14A base
`23949d0934840e6ad9542023ce9ba2dda4a9f2e6`.

## Context

`governance verify-log` proves that ordered Audit records reconstruct an
independently published head. The records intentionally contain hashes rather
than the complete Call, policy, assessment, and Proposal values. A reviewer
who receives only that log therefore cannot prove that those hashes name the
artifacts they were shown, that a consent matches the earlier `Ask`, or that a
transformed Call names a real parent.

GM.14A makes that review boundary portable. It adds one versioned package and
one offline verifier without changing the language, HASH_V0, Audit v2, any
Governance v0 subject encoding, or the existing `verify-log` command.

## Bundle contract

One `governance-run-bundle-v1` contains these fixed sections in order:

```text
(governance-run-bundle-v1
  (published-head-v1 #H)
  (audit-records-v1 RECORD...)
  (governance-call-artifacts-v1 CALL...)
  (bound-policy-artifacts-v1 POLICY...)
  (governance-assessment-artifacts-v1 ASSESSMENT...)
  (governance-proposal-artifacts-v1 PROPOSAL...))
```

The file is exactly one compact canonical line followed by LF. The Call,
BoundPolicy, and Proposal wrappers carry the full review fields plus their
existing identities. Identity is recomputed from the unchanged v0 semantic
subject, not from the additive wrapper. Assessment identity remains the hash
of its unchanged canonical value.

The verifier also resolves each effect-qualified operation through the chosen
prelude/store. A grammatical but misleading operation name cannot be paired
with a different operation hash.

## Verified relationships

`jacquard governance verify-run BUNDLE` fails closed unless:

- the embedded `audit-chain-v2` records pass the unchanged E13xx verifier and
  reconstruct the carried published head;
- every Call, policy, assessment, and Proposal is canonical and has a unique
  recomputed identity;
- every `Evaluated` entry resolves its exact Call, policy, and embedded
  assessment;
- every `Consented` entry resolves its Proposal and Decision, matches one
  earlier unconsented `Ask` for the same Call/policy/assessment tuple, uses a
  live policy, and repeats the Call's exact authority;
- every `Completed` entry resolves a Call with an earlier evaluation;
- each transformed Call has a present, non-self, acyclic parent chain; and
- every supplied artifact is used by the Audit chain.

Failures use E1500--E1507. Diagnostics name the artifact or Audit-entry index;
embedded Audit failures retain their stable E13xx code.

## Evidence and slice boundary

The focused unit suite covers a valid four-entry run with one transformed
Call, canonical byte refusal, forged identities, a resolved-operation
mismatch, duplicate and missing artifacts, Audit digest mutation, Proposal
authority disagreement, missing ancestry, unused artifacts, nonblocking
refusal of FIFO and character-device input, the 16 MiB file boundary, and a
valid 3,000-Call parent chain. Artifact linkage uses hash-keyed indexes and
usage arrays; the parent walk is a memoized three-color traversal. The cram
transcript exercises the public command on a committed canonical fixture and
pins both forged-Proposal and missing-LF failures.

This slice exceeds the usual 1,200-line architecture checkpoint because the
untrusted-input parser, all four unchanged identity validators, cross-artifact
linker, lineage walk, CLI, and adversarial tests form one refusal boundary.
Splitting them would publish either an accepted bundle with incomplete checks
or a verifier with no complete public evidence path. It remains one semantic
contract and does not cross into execution.

GM.14A alone does not authenticate a publisher, record driver attempts or
receipts, prove an external action occurred, infer rollback from a missing
completion, or reconcile idempotency keys. In particular, the existing outcome
detail in its fixture remains inert test data, not a verified receipt claim.

## GM.14B action reconciliation

GM.14B adds one package around the unchanged run bundle:

```text
(governance-reconciliation-bundle-v1
  (governance-run-bundle-v1 ...)
  (published-action-journal-head-v1 #H)
  (governance-action-journal-v1 RECORD...))
```

Each `governance-action-chain-v1` record commits the previous action-journal
head and exact entry bytes. Sequence starts at zero and is contiguous. The
fixed genesis and chain digest have their own domain strings; they reuse
HASH_V0 without changing any existing identity.

`action-attempted-v1` carries a recomputed semantic ID over the Call ID, exact
authorizing Audit-record digest, branch text, driver identity, and
idempotency-key digest. Only `Evaluated Allow` and `Consented Approved` records
under a verified LivePolicy are authorizations. The producer contract requires
the attempt to be durable before the driver boundary; this offline verifier
proves linkage, not producer timing or durability, and the entry is not proof
that the external effect happened. An action attempt must select `live`.

`action-receipt-v1` follows exactly one attempt and carries a recomputed ID over
that attempt, the exact canonical `GovernanceOutcomeSummary`, and an external
receipt digest. Raw provider receipt bytes remain outside the evidence package,
but low-entropy digest inputs remain vulnerable to equality disclosure and
offline guessing. A receipt reconciles with exactly one
`Completed` only when Call, branch, and canonical outcome all agree.

The verifier enforces the released policy matrix before deriving authority:
Live accepts `Allow`, `Ask`, or `Block`, while Dry accepts `Simulate` or
`Block`. Every live completion must follow one unique executable authorization.
V1 rejects repeated evaluation or live completion for one Call ID because the
frozen identity has no occurrence discriminator. Dry `Block` accepts only the
shipped `blocked` completion branch. Dry `Simulate` accepts `no-simulation`,
`simulated`, or `simulation-failed`. These remain legal no-action evidence;
unauthorized live completions are E1515 rather than silently omitted.

The public command reports six stable counts: no action legal, authorized but
not observed, attempted with unknown outcome, receipt pending completion,
reconciled completion, and completion without receipt. Every non-clean state
returns E1516 after printing the report. It never says that an absent receipt
means no effect, that a missing completion means rollback, or that retry is
safe. A second attempt under one authorization is a structural E1515 refusal.
The completion-without-receipt count includes every uniquely authorized live
completion lacking a receipt, even when no Attempted entry is available.

The focused suite covers all report states, exact Attempted and Receipt
identity, every invalid policy/verdict pair, unauthorized and repeated
attempts, receipt-before-attempt, wrong branch, unexplained and ambiguous live
completions, wrong head, skipped journal sequence, mismatched outcome,
canonical bytes, nonblocking FIFO and character-device refusal, the 16 MiB
bound, and a valid 1,000-action linear journal containing attempts, receipts,
and completions. Completion joins use hash indexes rather than pairwise scans.
The CLI transcript pins a clean package, an E1516 package with both a missing
attempt and completion receipt, journal-byte mutation, and missing LF.

This verifier proves internal integrity and linkage. It does not authenticate
the publisher, provider, or receipt; establish a trusted clock between the
Audit and action streams; invoke a driver; query a provider; schedule a retry;
repair Audit; compensate an action; consume an approval queue; or claim
rollback. Runtime-enforced fail-closed action-journal writes and idempotent
driver retry remain separate contracts.

## Reproduction

```sh
eval "$(opam env)"
mkdir -p "$PWD/.scratch/tmp"
export TMPDIR="$PWD/.scratch/tmp"
opam exec -- dune build --root "$PWD" @all
opam exec -- dune runtest --root "$PWD" --force
opam exec -- dune build --root "$PWD" @fmt
opam exec -- dune build --root "$PWD" @doc
scripts/release/reproduce-0.1.sh
sha256sum -c docs/release/governed-membranes/GM14-MANIFEST.sha256
```

The integrated GM.14B checkout contains 738 compiled Alcotest/QCheck cases,
43 cram transcript files, and 27 documentation examples across 8 documents.
