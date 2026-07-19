# Governed Membranes GM.14A Evidence

Status: additive GM.14A overlay on exact integrated GM.10 base
`814cada8731a7bc23e893d8a1af2811754ce7e6a`.

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

GM.14A does not authenticate a publisher, create or consume an approval queue,
record driver attempts or receipts, prove an external action occurred, infer
rollback from a missing completion, or reconcile idempotency keys. Those are
separate successor contracts. In particular, the existing outcome detail in
the fixture is inert test data, not a verified receipt claim.

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

The integrated GM.14A checkout contains 733 compiled Alcotest/QCheck cases,
42 cram transcript files, and 27 documentation examples across 8 documents.
