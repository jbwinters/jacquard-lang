# Effect Taxonomy ET.6 Evidence

Status: reconstructible ET.6 overlay on validated pre-ET.6 commit `950fab6`.

ET.6 promotes Approval from its reserved first-release schema to the shipped
ring-3 prelude interface. The frozen `DefEffect` identity is
`362425a29077a7efbcc37047182e579f46199a50473045eb4126a917dfc2a196`;
its sole operation is once `approval.ask : (Proposal) -> Decision`.

The released `Proposal` carrier separates the semantic call subject from the
exact review-artifact identity. `approval.make-proposal` requires the call
subject, policy hash, assessment hash, exact ordered authority, reviewed Code
rendering, summary, and optional typed preview. It computes the carried
proposal identity from the single typed `proposal-v1` Code encoding. The fixed
representative proposal hashes to
`6077e8595a8a9c8ae142789cf66c55672c30a7687388c8d41f763fc0ec74dada`.

## Validation and compatibility contract

- `code.hash : (Code) ->{} Hash` applies HASH_V0 to the same canonical compact,
  metadata-erased Code bytes used by `code.render`; Approval does not introduce
  a second serializer.
- `approval.validate-proposal` recomputes the exact review hash and rejects a
  forged carrier. A hash-less constructor attempt is rejected by the checker.
- `approval.validate-decision` accepts Approved, Denied, and Escalate only when
  their embedded proposal hash matches the exact validated proposal.
- `approval.before-action` forces its action thunk only after both validations,
  so a stale Decision cannot perform the guarded action.
- Metadata-only changes to a Call retain its semantic subject and Proposal
  identity. Changes to call subject, policy, assessment, authority, rendering,
  summary, or preview each invalidate the Proposal identity.
- The ET.2 Decision wire tags and type identity remain unchanged, and the Audit
  effect identity remains
  `2c148fbc2e26bdc6f01279a8bf176f54d5798536e1f96805aa4f7c7a57e67632`.
- ET.6 ships the Approval boundary and validation helpers. Canonical Approval
  handlers remain ET.7 scope; dry-run examples return Escalate and never
  fabricate Approved.

## Executable evidence

The seven-case `approval` suite pins the released effect identity and once
mode, the exact proposal encoding and hash golden, sensitivity of every review
field, metadata stability, forged and hash-less refusal, all three exact
Decision variants, stale-decision no-action state evidence, and a 100-case
metadata mutation property.

Native gauntlet g37 computes the same fixed Proposal identity and exercises
stale-decision refusal before action. It is registered in the differential
mapping and transcript, so interpreter and native execution must remain
byte-identical. The native `code.hash` intrinsic hashes the ported canonical
inline printer bytes with SHA-256 and uses the existing opaque Hash carrier.
The generated once-hostile lane invokes operation values through explicit
kind-directed operation references, avoiding the intentional `Ask` verdict/
`ask` operation name collision, and now covers all 15 reviewed once operations
with identical interpreter/native E0816 rejection.

The stdlib policy doctest constructs the Proposal through
`approval.make-proposal`, derives its exact hash with `approval.proposal-id`,
and demonstrates an Escalate-only dry-run handler. The taxonomy fixture reuses
the released Authority, Proposal, and Approval declarations rather than
publishing test-local twins.

## Reproduction

```sh
eval "$(opam env)"
mkdir -p "$PWD/.scratch/tmp"
export TMPDIR="$PWD/.scratch/tmp"
opam exec -- dune build --root . @all
opam exec -- dune runtest --root . --force
opam exec -- dune build --root . @fmt
opam exec -- dune build --root . @doc
runtime/check.sh
JACQUARD=_build/default/bin/main.exe JACQUARD_PRELUDE=prelude \
  JACQUARD_RUNTIME=runtime CC=clang \
  scripts/native-diff.sh test/native-gauntlet/g37-approval-binding.jqd
sha256sum -c docs/release/effect-taxonomy/ET6-MANIFEST.sha256
```

The ET.6 checkout contains 600 compiled Alcotest/QCheck cases and 32 cram
transcript files. The ET.2 and ET.3 evidence packs remain historical and
unchanged; ET.6 publishes a separate successor overlay.
