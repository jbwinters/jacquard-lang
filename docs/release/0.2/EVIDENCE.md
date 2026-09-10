# Jacquard Core 0.2 Evidence

Status: release evidence for `jacquard-core-0.2.0-rc1` and, after promotion of
the same reviewed commit, `jacquard-core-0.2.0`.

Required lineage base: `c0f570501b751865c0c0584d9b15be08b6ec1cde`

Exact candidate commit: recorded by `scripts/release/reproduce-0.2.sh` in
`.scratch/release/0.2/commit.txt`.

Distribution version: `jacquard --version` and `jac --version` print `0.2.0`.
This distribution bump does not rename or revise `HASH_V0`, the 27-form
kernel, canonical store formats, trace schemas, or other independently
versioned semantic artifacts.

## Built Artifact

The release is the OCaml package and three packaged binary targets in this
repository:

- `linux-x86_64`;
- `macos-x86_64`;
- `macos-arm64`.

Each archive contains the `jacquard` executable and `jac` alias, prelude,
runnable demos, native C runtime, and licensing files. The checksum-verifying
installer defaults to the final `jacquard-core-0.2.0` tag. An RC installation
must select `JACQUARD_INSTALL_VERSION=jacquard-core-0.2.0-rc1` explicitly.

## Test Inventory

The candidate inventory is discovered by the checked-in test runner and file
tree, not estimated from task history:

- Alcotest/QCheck cases: `1016`
- Cram transcript files: `61`
- Documentation examples: `28` named examples across `8` documents

The development suite also includes corpus goldens, release-manifest checks,
native interpreter/compiler differential cases, leak and memory checks,
seeded fuzzing, and demo transcripts. GM.12B's separate workflow executes the
complete 50,000-case forwarding grid. The parser-depth guard rejects unsafe or
slow handling of the canonical depth-100,000 inputs.

## Evidence Lineage

0.2 is an additive roll-up. It does not rewrite earlier publications:

- `../0.1/` retains the historical core candidate boundary;
- `../surface-syntax/` and `../dx-jac-export/` cover public `.jac`, formatting,
  direct native build, export, and parser hardening;
- `../named-call-arguments/` covers the post-release direct named-call
  projection and its additive identity-bound store companion; it does not
  retroactively put named syntax in the frozen 0.2 binary artifacts;
- `../explicit-dictionaries/` covers explicit `Eq`, `Ord`, `Show`, and `Num`
  values;
- `../effect-linearity/` and `../effect-taxonomy/` cover affine `once`
  continuations and the Audit, Secret, and Approval boundaries;
- `../structured-concurrency/` covers the interpreted scoped Task and typed
  Channel runtime, including the SC.17 transitive-cancellation correction;
- `../relational-warp/` covers schedule, Secret, and grant-variation lanes;
- `../governed-membranes/` covers the frozen typed Workspace v0 governance
  reference boundary and its explicit security and product limits.

The 0.2 manifest hashes the complete change set from the required lineage base
except for the manifest itself. `scripts/release/check-0.2-manifest.sh`
requires that inventory to match the Git diff exactly and verifies every blob.

## Reproduction Gate

`scripts/release/reproduce-0.2.sh` checks the candidate commit rather than an
uncommitted worktree. It verifies all registered historical publications and
the 0.2 manifest, builds all code and documentation, runs the complete suite,
doctests, depth guard, GM.12B proof, both compiler lanes, installer smoke,
public demos, selected release crams, and the gauntlet. It finishes only after
formatting leaves the checkout clean and the version surface is exactly
`0.2.0`.

The native evidence is genuinely compiler-specific: both `CC=clang` and
`CC=gcc` flow into runtime memory checks, differential tests, leak checks, and
the seeded fuzz target.

## Claim Boundary

Passing these gates establishes conformance to the tests and frozen contracts
identified in `CLAIMS.md`. It is not a formal soundness proof, security audit,
human readability study, production-readiness certification, or claim that
canonical hash equality means arbitrary behavioral equivalence. Read
`LIMITS.md` alongside every public claim.

The checked effect-payload successor adds 37 handler/transport cases and one
unifier isolation case, plus one CLI transcript, bringing the live inventory to
`969 / 60 / 28`. See [the containment contract](../../effect-payload-containment.md).
The historical publication manifests and their recorded source evidence remain
unchanged; these inventory numbers describe the current source checkout.

The serial host-session library adds 15 cases, bringing the current source
inventory to `984 / 60 / 28`. It covers typed responses, terminal mappings,
finish-once accounting, and bounded evidence. See
[the session contract](../../host-session-v0.md).



The native backend's eight-argument cap now applies only to the fixed calling
convention: a variadic intrinsic applied directly, which is what marked
interpolation lowers to, receives an array and a count, so an ordinary report
line with many segments compiles natively without changing the canonical
expansion or any hash. Pinned by the gauntlet twin `g43-variadic-join.jqd`
(both engines; the leak lane covers gcc) and the interpolation block of
`test/cli/native.t` (segments below, at, and above eight, the explicit
`text.join` twin's identical hash, empty/escaped/multibyte segments, effects
evaluated once in order, and the original rota report line); the inventory is
unchanged. Applying such a builtin as a value remains capped.

The opt-in serial host worker adds 23 cases and one CLI transcript, bringing
the current source inventory to `1007 / 61 / 28`. It covers the full
`stdio-u32-json-v0` lifetime against a reopened store: pure and effectful
invocations, every frozen host-failure and cancellation mapping, preflight
fatals, stale and malformed responses, carrier loss, the selected stderr
ceiling, descriptor ownership, and exit statuses. See
[the worker contract](../../host-worker-v0.md).

The HB.3 conformance kit adds 7 cases, bringing the current source inventory
to `1014 / 61 / 28`. It installs the kit fixtures with the published recipe,
binds every synthetic HB.1 vector identity to a real store member, replays all
21 vector transcripts and all 13 terminal mappings through the installed
worker with a deterministic fake host, and fails on any divergence that is not
an explicitly recorded pending decision. See
[the kit README](../../../spec/host-protocol-v0/kit/README.md).

Reopening a persistent store with the public prelude is idempotent: a store
records the prelude files it was loaded with, an identical prelude reloads as
a no-op, a different prelude is refused with E0705 before any change, and a
store made before manifests were recorded loads its prelude through a trusted
view in which hidden derived members outrank any same-named user binding while
user programs keep the public view. `jac store add` selects the parser by file
extension, so the advertised `.jac` installation command works, refuses a
file with a top-level expression before installing anything, and restores the
index and object set if any declaration is refused part-way through a file,
so a failed installation leaves the store exactly as it was. Pinned by the
reload case in `test/test_prelude.ml` (one more case, bringing the inventory
to `1015 / 61 / 28`) and the reopen, mismatch, and rollback blocks of
`test/cli/store.t`.

Named call arguments over list literals (APP.1) keep the call label on the
whole list argument and off the generated `cons`/`nil` nodes, so labeled
constructor and function calls with list literals resolve, reorder, nest, and
hash identically to their positional twins. Pinned by one more case in
`test/test_surface_named_calls.ml` (bringing the current source inventory to
`1016 / 61 / 28`) and the list block of `test/cli/named-args.t`, including a
repeated label over list arguments reported once as E0311.

The native runtime header now declares `jq_text_eq`, which emitted units call
for every literal Text pattern; before this repair any such program failed to
build. Pinned by the gauntlet twin `g42-text-literal-patterns.jqd`, which
`test/cli/native-effects.t` compares against the interpreter under clang and
the leak lane (`scripts/native-leak-check.sh`) builds and runs under gcc, and
by the text-pattern block of `test/cli/native.t` (clang); the inventory is
unchanged.
