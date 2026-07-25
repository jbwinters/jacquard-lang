# Effect Taxonomy ET.8 Evidence

Status: historical ET.8 publication record. Its retained manifest is immutable
and is verified at the publication commit registered in
`scripts/release/historical-publications.tsv`.

ET.8 closes the taxonomy slice without changing a prelude declaration,
operation schema, canonical interface hash, or runtime behavior. At the ET.8
publication point, the inventory contained 25 blessed names: 15 released
identities and 10 reserved/unimplemented schemas. The exact released hashes
were recorded in `docs/effect-review.md` and checked against the taxonomy TSV,
Markdown table, effect registry, and loaded prelude.

## Current successor status

The current v1 successor has 18 implemented effects. In particular,
`Workspace`, `Judge`, and `Channel` are implemented. `Async` remains
taxonomy-reserved with a published identity and interpreted scheduler. The
seven remaining reserved names—`Choose`, `Env`, `Pg`, `Blob`, `Serve`,
`Crypto`, and `Log`—are unimplemented.

This successor status does not rewrite what ET.8 published. The historical
manifest continues to attest the original bytes at its registered publication
commit, while this prose tells readers what is true in the current tree.

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
- At the ET.8 publication point, `Choose`, `Env`, `Pg`, `Blob`, `Serve`,
  `Crypto`, `Log`, `Judge`, `Async`, and `Channel` formed the ten-item
  reserved/unimplemented set. That historical status made no handler, root
  grant, product-availability claim, or roadmap commitment.

The ET.8 canonical handler inventory covered all 15 effects released at that
publication point. Its executable checks required every named Jacquard handler
to resolve in the loaded prelude and required the eight documented root
boundaries to equal
`Prelude.grantable_names`: Clock, Console, Dist, Eval, Fs, Infer, Net, and
Secret. Approval, Audit, and Secret retain their separately evidenced boundary
contracts; ET.8 does not add a membrane, object-capability sandbox, continuous
distribution support, verified model truth, or automatic consent.

## Historical machine and CLI evidence

At ET.8, the `effect-taxonomy` suite failed if any of these projections
drifted:

- the TSV and Markdown name, tier, parameters, mode, risk, ring, status,
  operation, meaning, and exact released-hash fields;
- the TSV and `Effect_registry` metadata;
- every released operation's exact parameter and result type structure against
  the loaded prelude declaration, after resolving referenced type names to
  identities and requiring their deterministic canonical prelude names;
- released declaration identities, type-parameter lists, operation names and
  modes, and rings;
- the then-exact 15-item handler/boundary inventory and 10-item reserved set;
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

ET.8 added that regression to the existing `effect-taxonomy` suite without
adding a cram file. Its candidate inventory was 631 compiled Alcotest/QCheck
cases and 35 cram transcript files.

## Reproduction

From a current successor checkout, verify ET.8 and the other retained
publication manifests with the historical-publication gate:

```sh
scripts/release/check-historical-manifests.sh \
  --commit "$(git rev-parse HEAD)" \
  --require-history
```

That gate reconstructs the registered publication tree before checking
`ET8-MANIFEST.sha256`. Do not regenerate the retained manifest from current
successor files: a direct `sha256sum -c` in today's checkout would compare
different publication states.

The ET.2 through ET.7 evidence packs remain historical and unchanged. The ET.8
manifest attests only its registered historical publication.
