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

Bootstrap `.jqd` remains permanently supported as the kernel/debug format of
record, quote-literal notation, and a test and tooling carrier. It is not
deprecated. The surface gate does not change the 27-form kernel, `HASH_V0`,
store format, evaluator, native semantics, or authority model.

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
| D36 | partial | [declaration tests](../../../test/test_surface_decls.ml), [trivia tests](../../../test/test_surface_trivia.ml), and [printing tests](../../../test/test_surface_print.ml) pin labeled field parsing, metadata, trivia, and rendering. [CLI evidence](../../../test/cli/surface.t) pins `pair.left` as absent with `E0301`; lowering does not generate accessor definitions, and missing/duplicate/type-inconsistent labels and explicit-term collisions are not validated. Labeled patterns remain deferred. | [D36 acceptance criteria](FOLLOWUPS.md#d36-generated-constructor-accessors) |
| D37 | shipped | [lexer tests](../../../test/test_surface_lex.ml) and [parser tests](../../../test/test_surface_parse.ml) pin dotted names as atomic and preserve namespace puns. | none |
| D38 | adjusted | The promised variadic `text.join` is absent; interpolation remains outside v0. | [D38 acceptance criteria](FOLLOWUPS.md#d38-variadic-text-join) |
| D39 | adjusted | The `gt?`/`gte?`/`lt?`/`lte?` family and `real.*` migration are absent; executable docs use current prelude names. | [D39 acceptance criteria](FOLLOWUPS.md#d39-comparison-naming) |
| D40 | shipped | [declaration tests](../../../test/test_surface_decls.ml) pin lowering order. [CLI evidence](../../../test/cli/surface.t) executes multiple bare expressions interleaved with declarations in document order and pins stdout `40\n41\n42\n` with exit 0. | none |

## Evidence Inventories

The release-doc validator derives these counts and exact member sets from the
compiled Alcotest list and repository sources.

| inventory | count | exact members or source |
|---|---:|---|
| tests | 549 | compiled `test_jacquard.exe list` inventory |
| doctests | 20 | `readme-multishot`, `tutorial-literal`, `tutorial-application`, `tutorial-identity`, `tutorial-factorial`, `tutorial-bool-match`, `tutorial-nonexhaustive`, `tutorial-safe-div`, `tutorial-read-only`, `stdlib-core-declarations`, `stdlib-control-effects`, `stdlib-dist-declarations`, `stdlib-multi-effect-signature`, `stdlib-pipe-transformation`, `stdlib-handler-policy`, `stdlib-nested-tuple-destructure`, `warp-check-effect`, `warp-test-types`, `warp-fault-effect`, `warp-hermetic-case` |
| twins | 22 | `app-add.jac`, `case-fold-constructor.jac`, `dotted-names.jac`, `eval-gated.jac`, `even-odd.jac`, `fact.jac`, `handler-policy.jac`, `identity.jac`, `let-shadow.jac`, `lit-int.jac`, `lit-real.jac`, `lit-text.jac`, `match-bool.jac`, `multi-effect-signature.jac`, `nested-tuple-destructure.jac`, `pipe-transformation.jac`, `prelude-map.jac`, `quote-lit.jac`, `safe-div.jac`, `surface-ref-v0.jac`, `to-option.jac`, `tuple-unit.jac` |
| demos | 12 | `agent-dream.jac`, `ambiguity-pipeline.jac`, `clarifying-question.jac`, `m1-choose.jac`, `m1-fact.jac`, `m1-gated.jac`, `m3-two-coins.jac`, `repair.jac`, `surface-expression.jac`, `surface-fact.jac`, `synthesis.jac`, `word-count.jac` |

The doctest lane audits the named fences against byte-identical fixtures and
expected stdout, stderr, and exits. Its extraction contract is in
[the doctest README](../../../test/docs-doctest/README.md). Demo claims are
distributed across [demos.t](../../../test/cli/demos.t),
[infer.t](../../../test/cli/infer.t), [repair.t](../../../test/cli/repair.t),
and [surface.t](../../../test/cli/surface.t); their union is exactly the demo
inventory above, including `repair.jac`.

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

D38 and D39 are SS.22 standard-library work. Tier-F linearity modes and
resource-scoped row display remain unscheduled headroom with no syntax,
semantics, or compatibility promise. Their separate acceptance gates are the
[Tier-F linearity criteria](FOLLOWUPS.md#tier-f-linearity-modes) and
[Tier-F resource-row criteria](FOLLOWUPS.md#tier-f-resource-scoped-rows).

## Reproduction Context

The immutable context is base commit
`07bf8aa71d197603c3830bd595ef7dd1e33e6bee` plus the files and SHA-256 values
in [MANIFEST.sha256](MANIFEST.sha256). The manifest excludes itself, avoiding a
self-reference, and includes only tracked files reconstructible from that base
and the SS.21 evidence overlay. Run
`scripts/release/check-surface-syntax-manifest.sh` from the repository root to
validate every listed byte sequence.

The following manager-only preservation audit is optional and never gates
`dune runtest`. The seven proposal drafts are intentionally untracked and
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
`TMPDIR=/home/josh/dev/friendmachine/research/weft-lang/.scratch/tmp`. Each row
runs from the repository root unless its command starts with `cd`.

- Final gate start UTC: `2026-07-11T17:47:30Z`
- Optional local transcript: `.scratch/ss21-final-gate/transcript.log` (untracked,
  not required or expected in a clone)

The following outcomes are declared before the gate starts. The gate runs in
table order and stops at the first mismatch. It also requires every task-file
mtime and SHA-256 value to predate and remain unchanged after the declared
start.

| command | deterministic expected result |
|---|---|
| `opam exec -- dune build @all` | exit 0 |
| `opam exec -- dune runtest --force` | exit 0; compiled Alcotest inventory is exactly 549 cases |
| `opam exec -- dune fmt` | exit 0; no task-file byte changes |
| `cd _build/default/test && ./test_jacquard.exe test surface-twins --compact --color=never` | exit 0; exactly 5 selected cases pass over 22 twin pairs |
| `opam exec -- dune runtest test/docs-doctest --force` | exit 0; exactly 20 named doctests pass |
| `JACQUARD_PRELUDE=$PWD/prelude opam exec -- dune exec jac -- run demos/m1-fact.jac` | exit 0; stdout is exactly `120` |
| `opam exec -- dune build @doc` | exit 0 |
| `git -c core.whitespace=trailing-space,space-before-tab diff --check` | exit 0 |
| `scripts/release/check-surface-syntax-manifest.sh` | exit 0; exactly seven reconstructible overlay hashes match |
| `clean-copy scripts/release/check-surface-syntax-manifest.sh` | exit 0; seven overlay hashes match and all seven protected drafts are absent |
| `clean-copy opam exec -- dune runtest --force` | exit 0; the isolated base-plus-overlay copy passes all 549 cases |

## Next Milestone

The exact next milestone is **SS.22, prelude naming and text building**: ship
and test D38 `text.join`, then ship and migrate the D39 predicate and `real.*`
names without changing the surface grammar. D36 accessor generation and Tier-F
headroom require their own later acceptance gates.
