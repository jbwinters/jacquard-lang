# Effect Linearity EL.2-EL.4 Integration Evidence

Status: successor-milestone evidence for the static affine `Resume` discipline, its bounded
immediate-transformer rule, frozen stdlib modes, and explicit surface operation modes.

- Reconstruction base: `23e3b5647fa9a9676990db9cf44350e66bf374a7`
- Evidence overlay: [MANIFEST.sha256](MANIFEST.sha256)
- Historical surface evidence: [surface-syntax/DECISION.md](../surface-syntax/DECISION.md)

## Scope

This overlay covers the integrated EL.2, EL.3, and EL.4 successors on top of the
completed EL.0 runtime backstop and EL.1 operation-mode encoding. It is the
exact tracked-file difference from the EL.1 base, excluding only this
manifest's impossible self-hash. It includes the affine implementation,
diagnostics, goldens, checker/type tests, explicit `.jac` operation-mode
parser/printer/lowering changes, frozen prelude assignments and hostile
operation inventory, surface twins and formatter tests, and all
release-document changes. It also keeps the historical SS.21/SS.22 manifest
separate and immutable.

The analyzer uses a bounded abstract flow state: whether an unused path exists,
one consumed-path witness, and at most one symbolic arm partition for an
immutable match scrutinee. Aligned sequential matches over the same variable or
resolved reference compose their arms pointwise. Thus complementary consuming
arms are accepted because no feasible execution consumes twice, while a
repeated consuming arm still supplies two-span E0816 witnesses. Unrelated or
unstable control flow keeps the conservative existential composition. The
partition never forms a Cartesian product: a 40-branch regression would require
roughly `2^40` states under concrete path-list enumeration but remains bounded
here.
Contextual helper analysis is also summarized once per callable parameter. A
25-helper regression transfers through duplicate exclusive arms at every level;
without summaries its recurrence is `T(n)=2T(n-1)`, while the implemented walk
is linear in the helper chain plus its syntax.

The sole affine-closure exception is established syntactically before
inference. A `Handle` must be the literal function child of one `App`, and all
arguments must be effect-free syntactic values. In that context only, a direct
operation-clause lambda is treated as constructed and called once; its body is
then checked by the same affine walk. Each call of its captured Resume must be
the direct function child of one nested application with syntactic-value
arguments, immediately eliminating
an answer that may carry a later Once token. Tests pin a positive two-Once
composition and reject binding and duplicating the first answer or evaluating
a Multi effect in the eliminating arguments, closing the
composition hole where the second token could otherwise be called twice. Tests
also pin the canonical function-of-state
handler and reject a handler result that is bound, returned, stored, passed,
aliased or applied twice, an effectful argument, a further lambda/quote/data or
nested-clause capture, and two consumptions inside the transformer. For calls
whose arguments all satisfy the immediate-transformer syntactic-value boundary,
malformed outer and resumption calls still receive E0803, and ordinary argument
mismatch still receives E0801. An effectful or otherwise non-value argument
intentionally prevents the exception from applying, so its captured `Resume`
receives E0817 even when the outer call is also malformed. Existing State and
Check programs remain accepted.

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

## D44 frozen prelude modes

`prelude/operation-modes.manifest` reviews all 21 operations without driving
implementation behavior. The completeness test parses every `DefEffect` in
every loaded `prelude/*.jqd` source and compares its complete qualified-name and
mode inventory to the manifest; it has no effect-name allowlist. Fourteen are
Once: Eval, Abort, Throw, Emit, Console, Clock, Net, Fs, Infer, and Audit operations.
Seven are Multi: State and Warp Check's pure continuation-capture operations,
Dist's two search operations, and Fault's world-exploration operation. The test
inventory must match the prelude exactly, so a new operation cannot inherit a
mode by name or omission without failing review. Future resource, governance,
Async, and Channel operations are required to be Once; future Choose/search
operations are Multi.

The pure State/Check exceptions preserve D43 rather than weaken it. Stateful
world fixtures (`infer.scripted`, record/replay, scripted Net/Console, and the
in-memory filesystem) retain their original function-of-state transformers and
public signatures. D43 recognizes only the canonical immediate affine shape:
the enclosing handler result is applied immediately to syntactic-value
arguments, a direct clause lambda captures its own resumption, and that lambda
is checked with the ordinary zero-or-one path rules. A captured-Resume call is
accepted only as the direct function child of a nested application whose
arguments are syntactic values; its answer
cannot be bound or duplicated and thereby launder a later Once token. Binding, returning,
storing, passing, aliasing, repeated application, effectful arguments, and any
further closure/quote/data/nested-clause escape remain E0817. A forced checker
sweep covers every exported prelude term; exact signature assertions cover all
seven transformers, and a behavior witness proves caller `State` remains
outward rather than being swallowed by the world fixture.

The stricter nested-application value boundary required two semantics-preserving
source rewrites: `net.record` now computes `next-log` before resuming, and
`fs.in-memory` computes `next-map` before its write resumption. Their public
signatures remain exactly pinned with the other five transformers. The
`net.record` interpreter witness still produces `"recorded"`; native retains
its pre-existing E1101 refusal because `code.of-text` is not implemented in
the backend. The `fs.in-memory` interpreter and native witnesses both produce
`"hello"`. The source-visible term hashes change deliberately while their
effect interface hashes remain unchanged:

| term | old member hash | new member hash |
|------|-----------------|-----------------|
| `net.record` | `212354fb4c453a8772c37feb097919897fdd4a01c577ce1762d5aa220a8c3f33` | `468cd3f499430c990615b6df71e4d7bc492f3051f780b1be4021a7ee20d95eac` |
| `fs.in-memory` | `946c74fc381164f0dc412d96bc309d74c61749326c398649021b990edbd82d25` | `af906d2328c5b721f658811cce936fa29d8a3f374fe80b6c99248b4b9c002c82` |

State branch independence is pinned in the interpreter and native differential
lanes by placing `state.run` inside Multi `fault.all`. Each branch starts from
state `0` and adds its own delta (`1` or `2`), yielding
`cons((1, 1), cons((2, 2), nil))`; leaked state from the first branch would make
the second pair `(3, 3)`.

The effect declaration hash is the interface hash: it covers the full ordered
operation signatures and their modes; operation member hashes are derived from
that declaration hash plus ordinal. The changes are deliberate and breaking.
The Once effect interface hashes changed as follows:

| effect | old interface hash | new interface hash |
|--------|--------------------|--------------------|
| Eval | `7ef0e79b8fd906810488ac738f16254ae4ae4a9acff7041fee02b6a116373a99` | `94f82f3c17d019d6ca5092b24f19d51ad40720d0accbc4c50641ade0ca056c24` |
| Abort | `5c83f89e3a66457f49b5639fcc382c212cf479790f516fd794a884f82fa87c21` | `bfdfaeee39c6f5290ebea28e805bdeb92f448f1a1e0b9c47f3c70c53975b4375` |
| Throw | `861c7c495261a6bf97335b1ca9c707dfe57286309877b8b172772f5e83cb7891` | `f236e77750a9c066fdff9220b81ab1ba6b6a5dd5226ab63dfd112f4b14aa504e` |
| Emit | `40c908a3bccd7b4832f0433748b6791c4535f097e117e11b0cb496ff623d6bad` | `28afafc8cbec5108fa6103e4670269080373bc0d9a07b1f0f257861ef4b948f6` |
| Console | `9d0a0d8c678083420cbed11188059e2b51540c4a10d88c34330a72ec5efc28be` | `73e8a208eb7fadc43e3bd7aef1474884cf99ce86f8108ddf0e3baff0a74b3fc9` |
| Clock | `5f5989fbfbfa171543a12f8ab9dcef3254db75f5b832078c23e1928014165ee3` | `9041c22386c41541b6b6818bcb26f1aeb02ae8f0dce3fedbf5f411e4bff9eecb` |
| Net | `a899c312c4e2d35bfce3bd596a409b1c3d16ed5321b4eb1c9fa3a40fd0c8ceab` | `be1aad7345c6215f227e63df6c7d05874a464f207599d4f5b85de8b0a6675b45` |
| Fs | `0c249f38f2da1e429dcc7cf1d391210208dc8fc72a22502927fe1ee7fd7b23d9` | `8ec13169c7181851364e55353232af8e3c7f5ee4a010fa3067fcf2058dd5ed84` |
| Infer | `f96558a9caeaf52169cb76a5484468ccb92f576108e8fb11e66dc42f53276ffe` | `324b8f59279db3cabbfaaba430168717057cea8fc1435a11a1a9106e3e6fb4d8` |

Multi remains encoded by absence. These retained identities are asserted
directly, not merely inferred from an unchanged source spelling:

| effect | retained interface hash | retained operation member hashes |
|--------|-------------------------|----------------------------------|
| State | `44a2946788e38fb6a734449880cce3d499aa5e2f876c5d9119773533b3d621a9` | `get=436ac521990b98f781d2b940ae7411d495bcabbabfd5212d71f6a3803d11e4af`; `put=5c6c06f1338db14e6651a830a3598cf369da2a2ec53a17b091116da3b6640e70` |
| Dist | `5a31778adb668e471820541428a4d809f40206b231b2f9d40aeb36d5684415f0` | `sample=6a5da9e5bd03d63ee37665097c6cb472fde25578e7d8dbabf388a9f3a46a8a76`; `observe=5d699ff1e147617ccc1c12bfa921370432618a63fa3cdf5ccdd330f83e446872` |
| Check | `d0fd20ea4725129d5b5de718e7332164ca504247793c21454533cbcf81112336` | `check=4e4065ee81b87920edd760a835a52be10b105f25f3a6a41a6a3bbbc8930126d5`; `fail=32a7abbad63368d57a2d08265658ac27bff7bfd6f4f25377b9006d3402adc944` |
| Fault | `0b7297f7a38573108de121c794c6be6471d9c43bd4749d435a3cd247e7d5f008` | `flaky=d28d10d5ddd39a0d9f456a22007acc6d84ffd3497000d5cefbda3ef159b54416` |

E1236 is the user migration diagnostic: `.jac` omission is rejected with
guidance to choose Once unless deliberate search, capture, or reuse requires Multi.
Bootstrap `.jqd` absence cannot receive a sound targeted warning because it is
both the permanent legacy encoding and the only valid Multi encoding; warning
there would flag reviewed Dist/Fault and permanent fixtures with no explicit
bootstrap Multi spelling available.

The generated hostile lane creates one type-correct double-resume handler per
Once operation. `jacquard run` and `jacquard build` reject all 14 with identical
E0816 diagnostics. A direct interpreter capture matrix then proves each exact
operation produces E0906 on an unchecked second resume, while the existing C
runtime parity probe pins byte-identical dynamic E0906 behavior.

The composition regression distinguishes a Multi branch outside a freshly
entered Once handler (legal, with a fresh token in every branch) from a Multi
perform inside an already-captured Once clause (the second branch must receive
E0906). Native lowering now reserves its tokenless tail-resumptive fast path for
Multi clauses; every Once clause materializes a shared `JQ_RESUME`, so cloning
an enclosing Multi continuation cannot clone the Once used-bit. Both cases are
byte-identical between interpreter and native execution.

`jacquard tiers` exposes the same distinction rather than treating syntactic
shape as lowering: the current prelude pin reports six tail-resumptive source
shapes, one `tokenless-tail-multi` lowering, and 33 `materialized-resume`
lowerings. The detailed table includes each clause's declared mode.

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
- the forced suite passes all 634 compiled Alcotest/QCheck cases and 33 cram transcripts,
  including 14 generated Once-operation parity cases;
- the clang native differential reports 69 byte-identical programs, 8 manifested
  refusals, and 0 failures;
- formatting exits zero without changing tracked source;
- the native runtime check includes and passes `fatal once-resume-twice`.

These are executable prototype tests, not a formal proof of affine typing.
