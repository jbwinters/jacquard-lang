# Governed Membranes GM.9 Evidence

Status: reconstructible GM.9 overlay on the GM.2 plus GM.5 integration commit
`62bac22`.

GM.9 releases the reference `Workspace` facade schemas and the pure call and
outcome normalization boundary. It deliberately stops before dry/live
membrane handlers, simulation, raw drivers, or gate execution.

## Typed facade and inspectable specs

The ring-3 `Workspace` interface is once and has frozen identity:

```text
d5831f495fdb26e05d53d886786f07230f7bb808ac4933ab32e0a9238c89f9d0
```

Its exact operations use existing stdlib carriers:

```text
workspace.read-file  : (Path) -> Result ToolError Text
workspace.write-file : (Path, Text) -> Result ToolError ()
workspace.fetch      : (Request) -> Result ToolError Response
```

`Path = PathValue(Text)` is the frozen facade carrier.
`WorkspaceOperation` is closed over these three members.
`workspace.operation-spec` returns an ordinary
`WorkspaceOperationSpec` value containing the operation tag, exact resolved
operation ID, canonical name, authority, preconditions, and safe secret
references. Read and write expose exactly `Effect(Fs-id)`. Fetch exposes the
strict taxonomy-order `Effect(Net-id), Effect(Secret-id)` envelope and the single
`SecretRef("workspace", None)`. The implementation has no `Secret` parameter,
generic inspection, universal string `Tool.call`, opaque `Host`, handler, or
raw-effect action.

## Pure identity boundary

The three typed normalizers recompute their own exact operation spec and use
`governance.make-call` with canonical operation-specific argument Code and the
frozen empty `quote {()}` precondition. `PathValue` and URLs remain readable;
write contents and request bodies enter arguments only as HASH_V0 digests.
Fetch also encodes the safe SecretRef. Human summaries are deterministic and
do not expose bodies. No public generic `workspace.call` or
`workspace.call-from-spec` accepts a caller-supplied spec.

Representative Call HASH_V0 goldens are:

- read `README.md`:
  `0eea80c98650bcc25c4a323464c8b112c48b991455d2c31f8dd0e8a99c6268c1`;
- write `generated.conf` with `enabled=true`:
  `08fb6f035d7077df0d24fbc4449caae6e8631a8092b1455435e42c59d1bbe571`;
- fetch `https://example.test/artifact` with the fixed request body:
  `c38951269a7804fdf267e6100815198698366eac27f32ecec037055f107c1a0d`.

The focused laws prove deterministic reruns retain the same Call ID, while
operation, path, write contents, URL, and request body are identity-sensitive.
They also destructure a canonical typed Workspace Call and operation spec,
reconstruct it directly through `governance.make-call`, and prove that changing
only the presentation summary leaves its Call ID unchanged. Meaningful Path
argument Code, exact public inferred schemes, and the absence/type refusal of
generic forged-spec call paths are pinned as well. The prelude hash golden pins
every facade, spec, normalizer, and summarizer identity.

## Safe typed outcomes

`workspace.summarize-read`, `workspace.summarize-write`, and
`workspace.summarize-fetch` accept their distinct `Result ToolError` result
types and return versioned `GovernanceOutcomeSummary` values. Success payloads
affect only the digest; safe detail contains a codepoint count, completion
label, or HTTP status. Error detail is reduced to the closed ToolError label,
so hostile driver detail is absent. All three inferred arrows are pure.

## Taxonomy and executable evidence

This successor overlay also corrects GM.1 authority validation: blessed
effects use the frozen taxonomy row order rather than rendered-Code/hash
lexical order, while duplicate rejection, strict Resource refinement, and a
deterministic fallback for non-taxonomy identities remain intact. The GM.2
canonical Call and Proposal wire encodings are unchanged; only dependent
prelude term identities move. Historical predecessor manifests remain
immutable, and the complete GM.9 manifest records the successor deltas.

The pure `governance.effect-order-key-v0` marker has interpreter and native
implementations with the same complete 26-row catalog positions, including all
nine reserved gaps; all seventeen released identities sort before the
deterministic unknown-hash fallback. Native differential twin g38 reaches
`governance.validate-authority` itself and byte-compares accepted Net→Secret,
unknown fallback, and ordered Resource envelopes with reversed, duplicate,
scope-order, and configuration-order refusals. Resource comparison is
field-structured—effect, kind, D3 bytewise scope, then configuration hash—and
the interpreter/native cases pin the prefix/delimiter scopes `a`, `a:`, and
`a::` in both directions. The typed registry test asserts all 26 catalog rows
against their TSV positions rather than sampling names.

Workspace remains a world facade, not a root grant. E0814 therefore directs a
caller to handle `Workspace` and says that it is not root-grantable, distinctly
from the existing pure-effect remediation. `--allow workspace` still refuses
with E0703 and the root grant policy is unchanged.

The machine TSV, Markdown table, typed registry, prelude declaration, ring
assignment, and operation-mode manifest agree on Workspace's name, once mode,
high default review risk, schemas, and interface hash.
`test/test_workspace.ml` pins the exact operation inventory and identities,
complete inspectable specs, safe canonical arguments, all three Call hashes,
identity stability/sensitivity, pure inferred arrows, and secret-safe outcome
rendering. Existing governance-core, prelude, rings, and taxonomy suites
provide compatibility checks.

## Reproduction

```sh
eval "$(opam env)"
mkdir -p "$PWD/.scratch/tmp"
export TMPDIR="$PWD/.scratch/tmp"
opam exec -- dune build --root "$PWD" @all
cd test && ../_build/default/test/test_jacquard.exe test \
  'workspace|governance-core|effect-taxonomy|rings|prelude' --compact --color=never
cd ..
opam exec -- dune runtest --root "$PWD" --force
scripts/native-diff.sh
opam exec -- dune build --root "$PWD" @fmt
opam exec -- dune build --root "$PWD" @doc
sha256sum -c docs/release/governed-membranes/GM9-MANIFEST.sha256
```

The integrated GM.9 + SC.4-SC.6 + DX.5/DX.7 checkout contains 675 compiled
Alcotest/QCheck cases and 36
cram transcript files, 25 documentation examples across 8 documents, and 44
interpreter/native gauntlet twins. The complete native walk reports 69 identical
programs, eight manifested refusals, and zero failures. Historical GM.1, GM.2,
and GM.5 evidence remains unchanged; this file and exact manifest are a
successor overlay.
