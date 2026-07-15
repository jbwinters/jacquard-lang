# Governed Membranes GM.6 Evidence

Status: reconstructible GM.6 overlay on integration commit `060e9d6`.

GM.6 releases the simulation-only governance gate and D69's ordered Audit v2
carrier. It composes exact `BoundPolicy DryPolicy`, `Judge`, and `Audit`
boundaries without adding live authority. The historical ET.2/ET.3 v1 evidence
packs remain valid descriptions of their checkouts; this overlay explicitly
supersedes their current Audit and chain identities.

## Contract

- `AuditEntry` is exactly the incompatible v2 schema. Every `Evaluated`,
  `Consented`, and `Completed` entry carries `GovernanceVersion` and a
  nonnegative `Int sequence`; `audit.entry-code` emits only `audit-entry-v2`.
- One `governance.with-sequence` owner installs and discharges `State` for a
  whole stream. Public rows and signatures are unchanged, but the handler's
  private payload refines the counter to `(run-id: Hash, counter: Int)`.
  A trusted deterministic per-evaluator generator gives every invocation a
  fresh ID, and `next`/`accept` reject mismatched owners before reading or
  advancing. The constructor, generator, and validator are absent from public
  name and exact-hash lookup, remain hidden after Store reopen, and are absent
  from `rings.manifest`.
- Reading a sequence does not advance it. The owner advances only after
  `Audit.record` resumes, so a refused write leaves the position unchanged.
  `audit-chain-v2` accepts only exact sequences `0, 1, 2, ...` and rejects
  duplicate, skipped, decreasing, or negative values with E1308.
- `governance.gate-dry` accepts a shared token, exact bound dry policy,
  validated call, pure simulator thunk, and pure outcome summarizer. It returns
  `DryDisposition a`, never accepts or exports `Resume`, and has the exact
  closed outward row `{State, Judge, Audit}`.
- Malformed directly represented Call or BoundPolicy inputs return unaudited
  `InvalidDecision` before Judge, Audit, simulation, summarization, Approval,
  or world authority. This defensive path has no trustworthy IDs to record.
- After valid preconditions, Audit is fail-closed. Refusing `Evaluated`
  prevents simulation and summarization and preserves sequence zero. Refusing
  `Completed` happens after simulation, prevents the disposition from reaching
  the facade continuation, and preserves sequence one.

## Executable evidence

`test/test_governance_gate.ml` pins the full elaborated gate and owner
signatures. It rejects token and hidden-generator access by source name, exact
derived hash, and hash rebinding; unchecked evaluation also fails closed.
Reopened-store tests prove those names and hashes stay hidden while the
already-resolved owner still works. Owner-law tests cover normal same-owner
advancement, direct token return, sequential and nested cross-owner reuse,
manual `state.run` reuse, and independent nested counters.

The 60-cell risk/confidence/simulator matrix installs actual root handlers for
`Fs.write` and `Approval.ask`; both counters remain zero. Valid cells return
exact v2 audit entries at positions zero and one. Dedicated probes pin
pre-audit and completion-audit refusal ordering and state preservation.
Malformed Call and BoundPolicy probes pin unaudited `InvalidDecision` and zero
Judge, Audit, simulator, summarizer, Approval, and live calls.

`test/cli/governance-gate-dry-laws.jqd` exhaustively crosses four risks, five
assessment confidences, five dry-policy thresholds, and three simulator states.
Warp verifies all 300 cases, including exact disposition class, v2 versions,
sequence positions, audit order, and execution of the facade-local once
continuation. `test/test_audit_chain.ml` separately mutates duplicate, skipped,
and decreasing sequences through both verification and `append_file`; every
append mismatch returns exact E1308 and byte-compares the file before and after
to prove that no bytes were written. `corpus/golden/audit-chain-v2.golden` and
its head pin the v2 wire and domain; historical v1 goldens remain as evidence
fixtures.

## Reproduction

```sh
eval "$(opam env)"
mkdir -p "$PWD/.scratch/tmp"
export TMPDIR="$PWD/.scratch/tmp"
opam exec -- dune build --root "$PWD" @all
cd test && opam exec -- ../_build/default/test/test_jacquard.exe test \
  'governance-gate|governance-core|judge|audit|audit-chain|warp'
cd ..
opam exec -- dune exec --root "$PWD" jacquard -- test \
  test/cli/governance-gate-dry-laws.jqd --exhaustive --budget 1000 --no-cache
opam exec -- dune runtest --root "$PWD" --force
opam exec -- dune build --root "$PWD" @fmt
opam exec -- dune build --root "$PWD" @doc
sha256sum -c docs/release/governed-membranes/GM6-MANIFEST.sha256
```

The GM.6 checkout contains 631 compiled Alcotest/QCheck cases and 32 cram
transcript files. The exact overlay manifest is relative to `060e9d6`; earlier
governed-membrane and effect-taxonomy evidence packs remain historical.
