# Surface Syntax Release Decision

- Decision date: 2026-07-11
- Base commit: `07bf8aa71d197603c3830bd595ef7dd1e33e6bee`
- Evidence overlay: [MANIFEST.sha256](MANIFEST.sha256)
- Release posture: post-0.1 successor research prototype

## Decision

Advertise `.jac` as the supported, user-facing authoring syntax for the
implemented v0 projection. Do not advertise it as production ready, frozen, or
independently semantic. The evidence covers the named parser, printer,
formatter, checker, CLI, corpus, documentation, and demo inventories. It does
not prove every possible kernel tree or freeze future surface revisions.

The SS.0-SS.22 implementation arc is complete at these evidence boundaries.
The EL.4 successor overlay additionally ships D41-D42 operation-mode syntax.
That completion does not promote partial D36, resource-scoped rows, or the
separately integrated affine-checker/stdlib work into this surface claim and
does not establish a freeze for the entire surface syntax.

Bootstrap `.jqd` remains permanently supported as the kernel/debug format of
record, quote-literal notation, and a test and tooling carrier. It is not
deprecated. The surface gate does not change the 27-form kernel, `HASH_V0`,
store format, evaluator, native semantics, or authority model. EL.1's
hash-stable operation-mode extension is the kernel input to this overlay:
legacy `Multi` remains absent and byte-identical, while explicit `Once` is
interface-visible.

## Law Status

Allowed law statuses at this gate are `bounded` and `pinned`.

| ID | status | evidence paths and boundary |
|---|---|---|
| L1 | bounded | [surface laws](../../../test/test_surface_laws.ml), [printer inventory](../../../test/test_surface_print.ml), [types](../../../test/test_surface_types.ml), and [handlers and quote](../../../test/test_surface_handlers_quote.ml) cover the valid corpus and kernel-form families, including `jqd` fallbacks; this is not a generated proof over every tree. |
| L2 | pinned | [surface laws](../../../test/test_surface_laws.ml), [trivia tests](../../../test/test_surface_trivia.ml), and [CLI formatting](../../../test/cli/surface.t) pin formatter idempotence for the formatter corpus and CLI lane. Damaged recovery trees replay their original bytes. |
| L3 | pinned | [twin harness](../../../test/test_surface_twins.ml), [demo transcript](../../../test/cli/demos.t), [inference transcript](../../../test/cli/infer.t), and [repair transcript](../../../test/cli/repair.t) pin identity for the complete inventories below; this is corpus evidence, not a second semantics. |
| L4 | pinned | [surface sugar](../../../test/test_surface_sugar.ml) and [control sugar](../../../test/test_surface_control_sugar.ml) pin exact local lowering and hash behavior for every shipped sugar. |
| L5 | pinned | [surface sugar](../../../test/test_surface_sugar.ml), [control sugar](../../../test/test_surface_control_sugar.ml), [handlers and quote](../../../test/test_surface_handlers_quote.ml), [checker diagnostics](../../../test/test_surface_check.ml), and [CLI diagnostics](../../../test/cli/surface.t) pin the named provenance and diagnostic matrix. |
| L6 | pinned | [trivia tests](../../../test/test_surface_trivia.ml), [type trivia](../../../test/test_surface_types.ml), [surface laws](../../../test/test_surface_laws.ml), and [CLI formatting](../../../test/cli/surface.t) pin comments, docs, order, ownership, metadata/hash inertia, and idempotence under the stated canonicalization contract. |
| L7 | pinned | [surface laws](../../../test/test_surface_laws.ml) mechanically require the one-page grammar to remain at most 100 nonblank lines and retain its reviewed digest. |

## Decision Conformance

Allowed decision statuses at this gate are `shipped`, `partial`, and
`adjusted`.

| ID | status | evidence paths and boundary | follow-up |
|---|---|---|---|
| D34 | shipped | [scaffold](../../../test/test_surface_scaffold.ml), [patterns](../../../test/test_surface_patterns.ml), and [twins](../../../test/test_surface_twins.ml) pin shared case projection and escapes. | none |
| D35 | shipped | [handlers and quote](../../../test/test_surface_handlers_quote.ml) and [printing](../../../test/test_surface_print.ml) pin atomic handler bodies and mandatory blocks for non-atomic bodies. | none |
| D36 | partial | The labeled-field portion shipped in SS.8: [declaration tests](../../../test/test_surface_decls.ml), [trivia tests](../../../test/test_surface_trivia.ml), and [printing tests](../../../test/test_surface_print.ml) pin parsing, metadata, trivia, lowering, and rendering. [CLI evidence](../../../test/cli/surface.t) pins `pair.left` as absent with `E0301`; generated accessor definitions and label validation, including duplicate-label rejection, are deliberate follow-ups. Labeled patterns remain deferred. | [D36 acceptance criteria](FOLLOWUPS.md#d36-generated-constructor-accessors) |
| D37 | shipped | [lexer tests](../../../test/test_surface_lex.ml) and [parser tests](../../../test/test_surface_parse.ml) pin dotted names as atomic and preserve namespace puns. | none |
| D38 | shipped | SS.22 ships a new callable variadic `text.join` object with an unbounded language/interpreter contract and strict argument evidence in [prelude tests](../../../test/test_prelude.ml), [CLI/native/ASAN boundary evidence](../../../test/cli/ss22.t), and [executable stdlib documentation](../../stdlib.md). Deprecated migration-only `text.join-list` preserves the pre-SS.22 list-plus-separator object hash-for-hash. Native v1 variadic parity is limited to 0-8 arguments; 9 is E1101 under its global ABI ceiling. Interpolation remains absent. | none |
| D39 | shipped | SS.22 ships all four `int.*` and `real.*` predicates plus dotted real arithmetic, with NaN and boundary parity in [the native gauntlet](../../../test/native-gauntlet/g35-stdlib-ss22.jqd). The obsolete hyphenated public names are removed without aliases, while the five historical marker IDs and semantic hashes remain stable; the [identity map](../../../test/test_prelude.ml) and [hash-reference CLI/native test](../../../test/cli/ss22.t) prove old references still load, typecheck, interpret, and native-compile. | none |
| D40 | shipped | [declaration tests](../../../test/test_surface_decls.ml) pin lowering order. [CLI evidence](../../../test/cli/surface.t) executes multiple bare expressions interleaved with declarations in document order and pins stdout `40\n41\n42\n` with exit 0. | none |
| D41 | shipped | [declaration tests](../../../test/test_surface_decls.ml), [printing tests](../../../test/test_surface_print.ml), and [trivia tests](../../../test/test_surface_trivia.ml) pin per-operation `once`/`multi`, uniform effect-level shorthand, canonical emission, recovery, and formatter idempotence. | none |
| D42 | shipped | [declaration diagnostics](../../../test/test_surface_decls.ml) reject omission, duplication, conflicts, and partially annotated mixed effects with E1236; the [operation-mode twin](../../../corpus/valid/operation-modes.jac) pins resolved `.jac`/`.jqd` hash parity while bootstrap absence remains legacy `Multi`. | none |

### D39 Stable Identity

The old public names are absent from the name index. Each new public name points
to the same canonical member hash recorded before SS.22, backed by the same
historical marker ID; no alias or duplicate object is created.

| pre-SS.22 public name / marker ID | SS.22 public name | pre-SS.22 and SS.22 member hash |
|---|---|---|
| `add-real` | `real.add` | `d2c5dfae79852c3b7c2d8426df692b04fb8549fd4b400a3ee3c2be5f04a0f76e` |
| `sub-real` | `real.sub` | `eba25d96c355d541e1beab4c94bf2b2c4e0d39118e937024b6093a2d89295978` |
| `mul-real` | `real.mul` | `da578d1fb2e56f6670c2cfd6dff60e73c190e66895e30b7152d84713cd1e34bb` |
| `div-real` | `real.div` | `f31ba01c161dfff1da955403edc8ff03e7d23b92df9d8dd50a5e9bd82b4a0678` |
| `lt-real` | `real.lt?` | `01a2e8cf101a6e0ae1f64a6df1f12a19c8ba98b674407d5125721133f9b112fb` |

### D38 Join Identity And Churn

The historical object moved from public `text.join` to deprecated
`text.join-list` without changing marker `text.join`, canonical bytes, member
hash `b39cc4607d94b6fc777f781207fff5d9bf9dff9d96ff11361a69d4032a0a4bfd`,
checker type, interpreter behavior, or native behavior.
The public variadic `text.join` object has marker `text.join-variadic-v1` and
member hash `c6b3e1429d584f14e81f4b1dd46b314ae038170bafc8ac0abdfb0162ed54141d`;
no canonical identity is registered with two semantics. Because `show.for-list`
now resolves `text.join-list` to the same old hash and
names are metadata, its declaration and member hashes also remain unchanged.
The only new join hashes are the variadic declaration/member pair.

The regenerated prelude golden has zero semantic-hash removals attributable to
D38 or the D39 renames. Other additions are the three new real predicates and
the four-member integer predicate group; downstream hash changes are audited in
the golden diff.

## Evidence Inventories

The release-doc validator derives these counts and exact member sets from the
compiled Alcotest list and repository sources.

| inventory | count | exact members or source |
|---|---:|---|
| tests | 724 | compiled `test_jacquard.exe list` inventory |
| doctests | 27 | `concurrency-channel-contract`, `concurrency-channel-type-mismatch`, `concurrency-row-contract`, `concurrency-row-laundering`, `effect-taxonomy-schemas`, `governed-membrane-signatures`, `readme-multishot`, `stdlib-control-effects`, `stdlib-core-declarations`, `stdlib-dist-declarations`, `stdlib-handler-policy`, `stdlib-multi-effect-signature`, `stdlib-nested-tuple-destructure`, `stdlib-pipe-transformation`, `stdlib-text-join`, `tutorial-application`, `tutorial-bool-match`, `tutorial-factorial`, `tutorial-identity`, `tutorial-literal`, `tutorial-nonexhaustive`, `tutorial-read-only`, `tutorial-safe-div`, `warp-check-effect`, `warp-fault-effect`, `warp-hermetic-case`, `warp-test-types` |
| twins | 24 | `app-add.jac`, `case-fold-constructor.jac`, `dotted-names.jac`, `eval-gated.jac`, `even-odd.jac`, `fact.jac`, `handler-policy.jac`, `identity.jac`, `let-shadow.jac`, `lit-int.jac`, `lit-real.jac`, `lit-text.jac`, `match-bool.jac`, `multi-effect-signature.jac`, `nested-tuple-destructure.jac`, `operation-modes.jac`, `pipe-transformation.jac`, `prelude-map.jac`, `quote-lit.jac`, `safe-div.jac`, `stdlib-ss22.jac`, `surface-ref-v0.jac`, `to-option.jac`, `tuple-unit.jac` |
| demos | 13 | `agent-dream.jac`, `ambiguity-pipeline.jac`, `clarifying-question.jac`, `m1-choose.jac`, `m1-fact.jac`, `m1-gated.jac`, `m3-two-coins.jac`, `preflight.jac`, `repair.jac`, `surface-expression.jac`, `surface-fact.jac`, `synthesis.jac`, `word-count.jac` |

The doctest lane audits the named fences against byte-identical fixtures and
expected stdout, stderr, and exits. Its extraction contract is in
[the doctest README](../../../test/docs-doctest/README.md). Demo claims are
distributed across [demos.t](../../../test/cli/demos.t),
[infer.t](../../../test/cli/infer.t), [repair.t](../../../test/cli/repair.t),
[preflight.t](../../../test/cli/preflight.t), and
[surface.t](../../../test/cli/surface.t); their union is exactly the demo
inventory above, including `repair.jac` and `preflight.jac`.

### DX.1 successor overlay

DX.1 extends the reconstructible evidence overlay with directional effect-row
inclusion, constructive non-aliasing branch joins, handler subtraction through
typed wrappers, and the associated demos, diagnostics, and regression tests.
The current `tests` inventory above belongs to this successor overlay. It does
not rewrite the frozen RC1 inventory of 554 cases or backdate DX.1 into the
SS.21 and SS.22 timestamps and observed-command table below.

## Caveats

- The parser is delimiter-based and intentionally small. Labeled patterns,
  records, guards, imports, interpolation, and custom operators are absent.
- The printer can use an escaped name, hash/group reference, or `jqd { ... }`
  for kernel material without an unambiguous native rendering.
- Formatting preserves comments, docs, order, and ownership, but not arbitrary
  whitespace, semicolons, CRLF, tabs, or blank-line counts.
- Recovery does not carry a local type declaration into a later recovery
  island; the regression reports `E0301`. Effectful top-level definitions
  remain rejected with `E0815`.
- CLI auto-detection selects surface syntax only for `.jac`. Store add, replay,
  current Warp files, the prelude, and internal fixtures retain bootstrap
  routes.

## Deferred Scope

D38 and D39 completed as SS.22 standard-library work without grammar changes.
D36 generated accessors and label validation remain partial after SS.8 and the
completed SS.0-SS.22 arc. D41-D42 operation modes now occupy their reviewed
grammar headroom; resource-scoped row display remains unscheduled with no
syntax, semantics, or compatibility promise.
Their separate acceptance gates are the
[D36 accessor criteria](FOLLOWUPS.md#d36-generated-constructor-accessors),
[Tier-F linearity criteria](FOLLOWUPS.md#tier-f-linearity-modes) and
[Tier-F resource-row criteria](FOLLOWUPS.md#tier-f-resource-scoped-rows).

## Reproduction Context

The historical surface context is the immutable manifest committed at the
SS.22 boundary `52f36133b95349ae481f091e0043e71bc1452bc3`. Its entries describe the
reviewed base-plus-overlay state rooted at
`07bf8aa71d197603c3830bd595ef7dd1e33e6bee`; the manifest excludes itself to
avoid self-reference. The checker pins the historical manifest's own digest and,
when the Git object is available, hashes paths from that exact boundary tree. It
never compares those historical digests with a later successor checkout.
Successor milestones publish separate overlays; EL.2 and later integration do so under
`release/effect-linearity/`.

The following manager-only preservation audit is optional and never gates
`dune runtest`. The six remaining proposal drafts are intentionally untracked and
outside the mandatory manifest and Dune dependencies. Absent files are expected
in fresh clones; this command skips them and checks the baseline hash only when
a manager's local copy exists.

```sh
while read -r expected path; do
  if [ -e "$path" ]; then
    printf '%s  %s\n' "$expected" "$path" | sha256sum --check --strict -
  else
    printf 'SKIP %s (absent, as expected in a fresh clone)\n' "$path"
  fi
done <<'EOF'
5bf5cf0eb778bb2d864aba9be8628395f631fefe70f0cb7a6cbfb3774aebe20a  docs/client-playground.md
4f9f1ca28605b8dcef4db539da8459a5087b100c8086e891f35e5b8927bb23f8  docs/concurrency.md
738ea3936afd62a8d9a3b051cd79627ca626dd2c87ad888d4e0c9ff6cdf8e0a8  docs/effect-linearity.md
80165c66c9e33cc1bcd143361470263b358f0212cd3482bc2865ee332a610840  docs/effect-membranes.md
ab4b3ceb8dea0e0d263f5b0d2088b492916276e34d805bcf744dc59951870c29  docs/effect-taxonomy.md
cb46e75e6e634fdaaca316114db6ee9831218215dbe87b753ef3e2568b010ce8  docs/jacquard-package-cli.md
194538899e3a187dfce9d9570bb1c2fb65ecf4fe78561099960deda45b263c9c  docs/jacquard-registry-server.md
EOF
```

Environment: Linux x86_64, repository-local OCaml 5.1.1 opam switch, zsh, and
`TMPDIR=$PWD/.scratch/tmp`. Each row runs from the repository root unless its
command starts with `cd`.

- Historical SS.21 final gate start UTC: `2026-07-11T17:47:30Z`
- SS.22 successor verification completed UTC: `2026-07-11T19:23:22Z`
- Optional local transcript: `.scratch/ss21-final-gate/transcript.log` (untracked,
  not required or expected in a clone)

The following outcomes were observed in the current successor checkout.
Task Master files were not changed. The table updates evidence inventory and
stdlib/native results; it does not reopen or strengthen the SS.21 release
claim.

| command | deterministic expected result |
|---|---|
| `opam exec -- dune build @all` | exit 0 |
| `opam exec -- dune runtest --force` | exit 0; compiled Alcotest inventory is exactly 554 cases |
| `opam exec -- dune fmt` | exit 0; no task-file byte changes |
| `cd _build/default/test && ./test_jacquard.exe test surface-twins --compact --color=never` | exit 0; exactly 5 selected cases pass over 24 twin pairs |
| `opam exec -- dune runtest test/docs-doctest --force` | exit 0; exactly 27 named doctests pass |
| `JACQUARD_PRELUDE=$PWD/prelude opam exec -- dune exec jac -- run demos/basics/m1-fact.jac` | exit 0; stdout is exactly `120` |
| `opam exec -- dune build @doc` | exit 0 |
| `git -c core.whitespace=trailing-space,space-before-tab diff --check` | exit 0 |
| `scripts/release/check-surface-syntax-manifest.sh` | exit 0; the immutable manifest matches the exact SS.22 boundary tree |

## Next Milestone

Successor milestone **EL.4, explicit surface operation modes**, is complete at
the D41-D42 evidence boundary. This updates the grammar and evidence; it does
not freeze the surface or claim production stability. D36 accessor generation
and label validation plus resource-scoped-row headroom retain their own later
acceptance gates.
