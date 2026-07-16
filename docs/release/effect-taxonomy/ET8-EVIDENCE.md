# Effect Taxonomy ET.8 Evidence

Status: pre-commit ET.8 candidate overlay on integration commit `3591bc0`.
The manifest makes the overlay reconstructible, but the final release
reproduction is intentionally pending until the overlay has its own commit
identity.

ET.8 closes the taxonomy slice without changing a prelude declaration,
operation schema, canonical interface hash, or runtime behavior. The frozen
inventory contains 25 blessed names: 15 released identities and 10
reserved/unimplemented schemas. The exact released hashes are recorded in
`docs/effect-review.md` and checked against the taxonomy TSV, Markdown table,
effect registry, and loaded prelude.

## Review contract

- Risk defaults are review-routing metadata, not permissions, safety claims,
  policy verdicts, or grants.
- `Dist` is authority-free but not uncertainty-free. Its support, weights,
  observations, handler, seed, and approximation still require review.
- `Infer` output, posterior weights, and governance confidence are evidence,
  not verified facts or consent. Only an exact hash-bound `Approval` decision
  can provide the consent represented by that protocol.
- Secret opacity is not taint tracking. `secret.expose` returns ordinary
  `Text`, which can subsequently be copied or leaked.
- `Choose`, `Env`, `Pg`, `Blob`, `Serve`, `Crypto`, `Log`, `Judge`, `Async`,
  and `Channel` are reserved and unimplemented. They have no released hash,
  handler, root grant, product-availability claim, or roadmap commitment.

The canonical handler inventory covers all 15 released effects. Executable
checks require every named Jacquard handler to resolve in the loaded prelude
and require the eight documented root boundaries to equal
`Prelude.grantable_names`: Clock, Console, Dist, Eval, Fs, Infer, Net, and
Secret. Approval, Audit, and Secret retain their separately evidenced boundary
contracts; ET.8 does not add a membrane, object-capability sandbox, continuous
distribution support, verified model truth, or automatic consent.

## Machine and CLI evidence

The existing `effect-taxonomy` suite now fails if any of these projections
drift:

- the TSV and Markdown name, tier, parameters, mode, risk, ring, status,
  operation, meaning, and exact released-hash fields;
- the TSV and `Effect_registry` metadata;
- every released operation's exact parameter and result type structure against
  the loaded prelude declaration, after resolving referenced type names to
  identities and requiring their deterministic canonical prelude names;
- released declaration identities, type-parameter lists, operation names and
  modes, and rings;
- the exact 15-item handler/boundary inventory and 10-item reserved set;
- the exact hash ledger and required risk, uncertainty, Secret, and non-goal
  wording in the review, taxonomy, stdlib, and tutorial documentation.

`test/cli/manifest.t` pins identity-confirmed metadata for official Net and the
full hash plus unrated status of a user effect also spelled `net`.
`test/cli/diff.t` pins both the blessed Fs-to-Net authority change and an
authority change between two exact identities of one user-defined `custom`
effect. These transcripts demonstrate that a familiar name cannot acquire
blessed metadata without the released identity.

The focused stale-hash regression changes Net's TSV parameter schema from
`Request` to `Text` while retaining the released hash and proves that exact
schema comparison rejects it. Coordinated TSV/Markdown drift can therefore no
longer pass merely because it leaves a stale hash field untouched.

ET.8 adds that regression to the existing `effect-taxonomy` suite without
adding a cram file. The candidate inventory is 611 compiled Alcotest/QCheck
cases and 35 cram transcript files.

## Reproduction

```sh
eval "$(opam env)"
mkdir -p "$PWD/.scratch/tmp"
export TMPDIR="$PWD/.scratch/tmp"
opam exec -- dune build @all
opam exec -- dune runtest --force
opam exec -- dune fmt
opam exec -- dune build @doc
ET8_COMMIT=$(git rev-parse HEAD)
JACQUARD_RELEASE_REF="$ET8_COMMIT" \
  JACQUARD_RELEASE_OUT="$PWD/.scratch/release/et8" \
  scripts/release/reproduce-0.1.sh
test "$(cat .scratch/release/et8/commit.txt)" = \
  "$(git rev-parse --short "$ET8_COMMIT")"
sha256sum -c docs/release/effect-taxonomy/ET8-MANIFEST.sha256
```

Run the release script only after committing the complete ET.8 overlay. A run
whose `commit.txt` still records the base `3591bc0` validates the base plus a
dirty working tree, not a release-addressable ET.8 artifact, and is not final
ET.8 reproduction evidence.

The ET.2 through ET.7 evidence packs remain historical and unchanged. The ET.8
manifest attests only this documentation-and-checking overlay on `3591bc0`.
