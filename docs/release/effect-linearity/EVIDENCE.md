# Effect Linearity EL.2 + EL.4 Integration Evidence

Status: successor-milestone evidence for the static affine `Resume` discipline and explicit
surface operation modes.

- Reconstruction base: `23e3b5647fa9a9676990db9cf44350e66bf374a7`
- Evidence overlay: [MANIFEST.sha256](MANIFEST.sha256)
- Historical surface evidence: [surface-syntax/DECISION.md](../surface-syntax/DECISION.md)

## Scope

This overlay covers the integrated EL.2 and EL.4 successors on top of the
completed EL.0 runtime backstop and EL.1 operation-mode encoding. It is the
exact tracked-file difference from the EL.1 base, excluding only this
manifest's impossible self-hash. It includes the affine implementation,
diagnostics, goldens, checker/type tests, explicit `.jac` operation-mode
parser/printer/lowering changes, surface twins and formatter tests, and all
release-document changes. It also keeps the historical SS.21/SS.22 manifest
separate and immutable.

The analyzer uses a constant-size abstract flow state: whether an unused path
exists and one witness that a consumed path exists. Sequential composition
rejects when both sides have a consumption witness; alternative branches merge
those existential facts. This preserves zero-or-one use per path and two-span
E0816 diagnostics without enumerating branch products. A 40-branch regression
would require roughly `2^40` states under concrete path-list enumeration.
Contextual helper analysis is also summarized once per callable parameter. A
25-helper regression transfers through duplicate exclusive arms at every level;
without summaries its recurrence is `T(n)=2T(n-1)`, while the implemented walk
is linear in the helper chain plus its syntax.

Escape checking precedes ordinary inference, but duplicate checking follows a
successful inference and clause-result unification. E0817 therefore remains a
purpose-built diagnostic for laundering or capture, while wrong Resume arity or
argument types retain E0803/E0801 and cannot count toward E0816. The escape-only
prepass also defers a Resume argument beyond a known local or stored lambda's
fixed arity so the malformed call receives E0803. The standalone full affine API
retains E0817 for that unsafe transfer when no inference pass follows it. Direct
escapes such as passing a Resume to itself or to a non-callable value still
receive E0817 before inference, and in-range transfers still share one affine
budget. This precedence also applies to recursive helpers: too-few and
out-of-range calls retain E0803, including a Resume at index two of a binary
local or stored helper, while any genuine in-range transfer receives E0817 even
when another argument makes the call too large. Standalone affine checking keeps
the conservative E0817 fallback for an out-of-range recursive transfer.

Stored declarations retain canonical object spans rather than original author
spans. Contextual E0817 failures therefore anchor at the author-visible
`Resume` transfer site. E0816 witnesses instead use distinct, durable logical
locations of the form `<stored:name@member-hash>:line:col`; these are honestly
canonical-helper occurrences, not original source positions. Regressions prove
that both witnesses differ and no diagnostic exposes transient `objects/*.jqd`
paths.

## Reconstruction

From the successor checkout, create the isolated base-plus-overlay copy under
the repository-local scratch directory:

```sh
base=23e3b5647fa9a9676990db9cf44350e66bf374a7
dest="$PWD/.scratch/el2-evidence-copy"
manifest=docs/release/effect-linearity/MANIFEST.sha256
rm -rf "$dest"
mkdir -p "$dest"
git archive "$base" | tar -x -C "$dest"
mkdir -p "$dest/$(dirname "$manifest")"
cp -p "$manifest" "$dest/$manifest"
awk '!/^#/ && NF == 2 {print $2}' "$manifest" |
while IFS= read -r file_path; do
  mkdir -p "$dest/$(dirname "$file_path")"
  cp -p "$file_path" "$dest/$file_path"
done
```

The manifest is copied separately because it excludes itself to avoid an
impossible self-hash. The overlay contains no untracked proposal drafts and
does not borrow other files from the successor checkout.

## Verification

Run in both the successor checkout and the reconstructed copy:

```sh
eval "$(opam env)"
mkdir -p "$PWD/.scratch/tmp"
export TMPDIR="$PWD/.scratch/tmp"
export DUNE_ROOT="$PWD"
scripts/release/check-effect-linearity-manifest.sh
opam exec -- dune build @all
opam exec -- dune runtest --force
opam exec -- dune fmt
opam exec -- dune build @doc
runtime/check.sh
```

Expected deterministic results:

- the effect-linearity manifest checker validates every named byte sequence;
- `dune build @all` and `dune build @doc` exit zero;
- the forced suite passes all 564 compiled Alcotest/QCheck cases and 32 cram transcripts;
- formatting exits zero without changing tracked source;
- the native runtime check includes and passes `fatal once-resume-twice`.

These are executable prototype tests, not a formal proof of affine typing.
