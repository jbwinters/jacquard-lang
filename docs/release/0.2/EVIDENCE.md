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

- Alcotest/QCheck cases: `1159`
- Cram transcript files: `76`
- Documentation examples: `35` named examples across `8` documents

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

The native backend's eight-argument cap now applies only to the fixed calling
convention: a variadic intrinsic applied directly, which is what marked
interpolation lowers to, receives an array and a count, so an ordinary report
line with many segments compiles natively without changing the canonical
expansion or any hash. Pinned by the gauntlet twin `g43-variadic-join.jqd`
(both engines; the leak lane covers gcc) and the interpolation block of
`test/cli/native.t` (segments below, at, and above eight, the explicit
`text.join` twin's identical hash, empty/escaped/multibyte segments, effects
evaluated once in order, and the original rota report line); the inventory is
unchanged. Applying such a builtin as a value remains capped, and a direct
variadic application of more than 65535 arguments, beyond the runtime's 16-bit
count, is refused at build time with E1101 rather than truncated.

The native text primitives repair (APP.5) adds one kernel gauntlet twin and one
CLI transcript block, leaving the OCaml case count unchanged. `text.to-int`,
`text.to-real`, `text.from-real`, `text.contains?`, and `text.slice` now compile
natively with the interpreter's contracts: the reader's numeric atom grammar
(optional sign, leading zeros, `digits[.digits][e[+-]digits]`, the Scheme
non-finite spellings, 63-bit overflow to `none`), an always-contained empty
needle, codepoint-indexed clamped slices, and the printer's shortest round-trip
real spelling. The twin prints byte-identically under the interpreter, `clang`,
and `gcc`; see [the support matrix](../../native-intrinsics.md). The
`test/cli/native.t` block also reads numbers from real stdin in a surface
program without an application parser. One pinned refusal changed on purpose:
`test/cli/export.t`'s Preflight fixture is still refused by both carriers, now
for dynamic eval alone (E1102), because its `text.contains?` call compiles.

The numeric presentation and character-class additions (APP.6) add three
cases to `test/test_text.ml` and one gauntlet twin: `real.from-int`,
`text.from-real-fixed` (a fixed-decimal presentation separate from the
round-trip `text.from-real`, ties on the exact binary value, no negative
zero), the singleton ASCII classes, `text.ascii-digit-value`, and
`text.codepoint`, each with an interpreter and a native implementation that
print identically under clang and gcc, bringing the current source inventory
to `1019 / 61 / 28`. Ring 2 gains seven names; the ring-0 freeze is
untouched.

End-of-input-aware terminal input (APP.7) is additive: `read-line` still reads an
empty line and end of input alike as `""`, and `Console`, `print`, and
`read-line` keep their released identities (`test/cli/world.t` pins them). The
new `ConsoleInput` effect's `next-line : () -> Option Text` resumes with
`Some(line)` or, once standard input has ended, a sticky `None`; the `console`
root grant installs both effects' handlers in the interpreter, dry runs, relate
replays, and native binaries, and the manifest lists both. It is blessed as the
additive taxonomy v3 row (`spec/effect-taxonomy-v3.tsv`; v1 and v2 unchanged;
the native order-key table gains position 27). `console.scripted-input` is the
library's scripted boundary. Pinned by three Alcotest cases (`test/test_world.ml`
injected source and scripted handler, `test/test_effect_taxonomy.ml` v3
additivity), the world.t and native.t transcript blocks (immediate end, empty
line, whitespace, final line without newline, repeated end, quit, refusal
parity), and the `stdlib-console-input` documentation example, bringing the
current source inventory to `1022 / 61 / 29`. The APP.5 evidence note above
says one `native.t` block; that repair added two.

Declaration-error cascades are suppressed (APP.8). The `check` command's
recovery report now keeps every cleanly lowered type and effect declaration of
the file resolvable for later islands (constructors and operations included,
through a checker overlay that installs nothing in the store), and the names a
malformed declaration or a failed definition would have bound are treated as
consequences: a later reference to one of them is silent instead of a second
E0301 (and, as in strict checking, such a name shadows a same-named prelude
binding rather than resolving to it), while an independent error is still
reported in source order with exit status 1. The parenthesised-positional constructor diagnostic (E1225) names the
surface spelling and both accepted field syntaxes, the constructor-shadow
warning (W1201) names the constructor and both remedies, and recovery trees are
still refused by `fmt`, `hash`, and `run`. Pinned by the cascade blocks of
`test/cli/diagnostics.t` and two `test/test_surface_check.ml` cases (the former
"cross-island type dependency is explicitly unsupported" case is replaced by
its supported counterpart), bringing the current source inventory to
`1023 / 61 / 29`.

The match-scrutinee readability warning (APP.9) no longer counts the lines the
canonical formatter chose: W1203 now reports a scrutinee that contains a nested
`match`, `handle`, `if`, or block outside a function-literal argument, or that
combines more than twelve calls and constructions, on one line or many (a
function literal's body is weighed but is a value of its own, so ordinary
`async.scope(fn () -> ...)` and fold scrutinees stay quiet; single-expression
braces are transparent, exactly as they are to the formatter), so `fmt` never introduces
or removes it and `check` agrees before and after formatting. Pinned by the
scrutinee cases of `test/test_surface_check.ml` (a formatter-expanded call, the
picnic planner's expanded input tuple, a wide labeled constructor, an ordinary
report interpolation, the twelve/thirteen boundary, and a nested match on one
line and on four) and the B3 block of `test/cli/surface.t` (no warning for the
expanded call; a nested match warns under `fmt` and `check`, formatting is
stable, and the hash is unchanged); the inventory is unchanged.

Public documentation examples run through the supported toolchain (APP.10). The
existing doctest harness (`test/docs-doctest`) gains three things rather than a
second harness: `stdin=NAME.stdin` for interactive examples, `mode=build` (the
fixture is compiled with `jacquard build` into the predictable scratch
directory and the binary runs with the same grants), and `mode=commands` (a
copyable `sh` snippet runs under `sh -e` in a fresh directory with `jacquard`
on the PATH and the repository prelude selected, so setup instructions and
stale commands are caught by docs CI). The summary line records the
`jacquard --version` and prelude the examples ran against. New examples pin
the public Console/State capture pattern (already in `stdlib-console-input`),
the once-resumption restriction as an explicit negative example
(`stdlib-once-resumed-twice`), constructor fields and named arguments
(`stdlib-labeled-fields`), numeric input from real standard input
(`stdlib-numeric-input`), the same interactive loop built natively
(`stdlib-console-input-native`), and the multi-file store recipe in the README
(`readme-multi-file-store`); bootstrap `.jqd` patterns are documented as
non-copyable. The harness self-test covers the new modes and their rejections.
The documentation-example inventory is `34` across `8` documents; the Alcotest
and cram counts are unchanged.

The four everyday applications are acceptance fixtures (APP.11).
`demos/applications` holds byte-identical copies of the dice coach, picnic
planner, rota optimizer, and formula notebook sources, imported by
`scripts/applications/import.sh` with a SHA-256 provenance manifest; the
originals are untouched. The baseline is pinned before any workaround is
retired: `test/cli/applications.t` (the routine lane, one more cram file)
verifies the manifest, the `console`-only demo manifests, every recorded
`EXAMPLE.txt` transcript under the interpreter and the native binary (the
hand-calculated picnic scores, the dice policy at pot 19, the rota week
proven optimal at 73 in 705 nodes, the notebook what-if), real interactive
sessions over standard input with interpreter/native parity, and the three
Warp suites with sampled properties (25, 17, and 18 tests); `dune build
@applications-exhaustive` (workflow `applications.yml`, path-scoped, not
required) reruns the suites with `--exhaustive` and the native parity. All
eight entry points now build natively; the dice coach and picnic planner had
never done so before the APP.5 and APP.6 repairs. Warp suites remain
interpreter-only, and the applications' own workarounds are kept as recorded.
The current source inventory is `1023 / 62 / 34`.

Program preparation is one shared frontend service (RF.1). `src/frontend.mli`
now owns the parse, validate, resolve, and install walk that `check`, `hash`,
`run`, `test`, `infer`, `dist-diff`, `tiers`, `export`, `build`, `diff`,
`replay`, `store add`, and the governance commands used to repeat, each command keeping its
documented order (for example `build` resolves the whole file before checking,
and `test` refuses an expression before resolving it). `check` runs in a fresh
scratch session and returns a sealed checked artifact binding the source digest,
the prelude identity, each top's resolved form, identities, rendered schemes,
effects, and call-label companions, and the identities the source depends on;
a damaged surface file yields only the recovery report, and an artifact must
verify against a store's persisted state (same prelude, dependencies and every
declaration present, each name bound per kind to the checked identity, and the
same call-label companions) before it is trusted there. `store add` installs as
one store transaction; `run --store` still installs declarations as the program
runs and keeps them after a later failure, as before. The host worker prepares
its checker through the same service. Output, diagnostics, exit codes, hashes,
and grants are unchanged. Because the artifact renders every scheme, the scheme
printer's quantifier names past `z` now continue as `a1`, `a2`, ... like the
body (27 or more type variables used to print the characters after `z` in the
quantifier, and 160 or more crashed `check --print-sigs`). The ten `test/test_frontend.ml` cases bring the
current source inventory to `1033 / 62 / 34`.

Labeled constructor fields generate accessors (SX.27, D36). Surface lowering
follows each labeled type declaration with one ordinary pure definition
`<type-kebab>.<label>` per label that every constructor carries, marked
`surface-generated` so the printer, `fmt`, and `check --print-sigs` show only
the owning type; a label
that only some constructors carry keeps its pattern and named-construction uses
without an accessor. Declarations now refuse a label repeated within a
constructor (E1239), a label whose field type differs between constructors
(E1240), and an accessor name an explicit definition of the same file also
defines (E1241). `test/cli/surface.t` pins `pair.left(Pair(1, 2))` printing `1`
under the interpreter and natively plus the three exact diagnostics,
`test/cli/applications.t` pins generated accessors agreeing with the
applications' hand-written selectors, the night-shift case study drops its
hand-written `reading.ms` (now generated, and otherwise refused as E1241), and three `test/test_surface_decls.ml`
cases pin kernel-twin identity, eligibility, and validation, bringing the
current source inventory to `1036 / 62 / 34`.

Scoped effect instances are designed and modelled (TS.1,
`docs/designs/scoped-effect-instances.md`). The design keeps TS.0's ambient
operations unchanged and adds opt-in instance capabilities with rigid instance
labels, non-escape (through results and outward effect payloads), and dispatch
by instance. The executable model
(`test/scoped_instances_model.ml`) finds, by bounded seeded testing over 20,000
type-directed programs, no stuck well-typed program for instance typing with
instance dispatch or for TS.0's rule with nearest dispatch, and finds
counterexamples for instance typing over nearest dispatch. The thirteen
`test/test_scoped_instances_model.ml` cases bring the current source inventory
to `1049 / 62 / 34`.

Public interfaces are portable artifacts (API.1). `src/interface.mli` defines
the `interface-v1` manifest that every checked artifact now seals
(`Frontend.Checked.interface`) and that `jacquard interface emit` writes: each
export with its exact identity, owning declaration, name-independent checked
signature, call labels (a term's or operation's `call-abi-v1` companion, a
constructor's field labels), mode and arity, plus the hidden members of exported
declarations. The interface identity covers exports and hidden members only, so
reformatting or renaming binders keeps it; `jacquard interface diff` classifies
a change as compatible only when it is purely additive; `jacquard interface
verify` accepts a store only when it binds every export to its identity with an
equal companion and exposes no hidden member, so a positional export is refused
for its missing companions rather than having labels inferred. `HASH_V0`,
export, and `.jqd` are unchanged (`docs/release/api-identities/DECISION.md`).
The six `test/test_interface.ml` cases and `test/cli/interface.t` bring the
current source inventory to `1055 / 63 / 34`.

Evaluation state has an explicit owner (RF.2). An `Eval.ctx` is now reusable
program configuration (store, wired builtins, memo and validation caches, and
the owner of affine Once resumptions, which stays evaluator-lifetime because
memoized values may hold resumptions; a resumption from another evaluator is
refused with E0907 before its budget is consumed), and `Eval.with_invocation`
scopes everything one evaluation owns: the granted root handlers and the sinks,
RNG, and caches their closures hold, the root observer, and the coverage flag,
all restored on every exit including host exceptions; teardown callbacks
run exactly once, most recent first, with the body's exception taking
precedence. `run`, `relate`, `test`, `replay`, `infer`, `dist-diff`, and the
host worker each run their single evaluation extent as one invocation, so their output and exit
codes are unchanged; scheduler runs and schedule traces keep their existing
per-run ownership, and deterministic scheduling and serial host dispatch stay
separate. The host worker now checks its standard descriptors before opening
anything: a closed standard input or output is carrier loss (exit 74) with the
store untouched, a closed standard error only discards operator output, and the
startup note is best-effort, so a broken standard error cannot change the exit
(`test/cli/host-worker.t`, `docs/host-worker-v0.md`). The five
`test/test_invocation.ml` cases bring the current source inventory to
`1060 / 63 / 34`.

Inference outcomes are typed (INF.1,
`docs/release/inference-outcomes/DECISION.md`). `dist.enumerate-v1` and
`dist.sample-lw-v1` return a `result` that separates a normalized posterior
from impossible evidence, an exhausted terminal-path budget, and numerical
failure (underflow, non-finite, or negative mass), with method, completeness,
seed, bound, and explored-count metadata; `jacquard infer` applies the same
classification (E0901, new E0917 and E0918, `--max-branches`, `--metadata`).
The released `dist.enumerate` and `dist.sample-lw` identities are unchanged.
The eight `test/test_inference_outcomes.ml` cases, `test/cli/inference-outcomes.t`,
and the native gauntlet case g46 bring the current source inventory to
`1068 / 64 / 34`.

Result propagation is surface sugar (SX.29, D77 in `docs/surface-syntax.md`).
The block items `let p = try e` and `try e` elaborate to a two-armed `Ok`/`Err`
match over the rest of the innermost block. The error type is preserved
exactly, evaluation is left to right with nothing after the first `Err`, and
no kernel form, effect or Throw is added. A `try` block hashes identically to
its hand-written match, the formatter keeps the spelling, and interpreter and
native output agree. `demos/request-validation/validate.jac` validates a
request in several fallible steps. The seven `test/test_surface_try.ml` cases
and `test/cli/surface-try.t` bring the current source inventory to
`1075 / 65 / 34`.

Two store and identity repairs precede local projects:

- **Member indexing.** `Store.put_decl` now indexes a declaration's members
  from the persisted object bytes. A permuted, hash-equal definition group
  therefore locates each member's own body instead of the incoming order's.
  Re-adding over a damaged object, whether unparseable or substituted with
  content of another hash, reports the store's corrupt-object error (E0603)
  (`test/test_store.ml`).
- **Real literals.** They denote their `HASH_V0`-normalized value in
  expressions, literal patterns and quoted code, so hash-equal programs run
  the same numbers. Computed reals keep their IEEE sign
  (`spec/serialization.md`; native gauntlet case g47).

- **Source composition.** `Surface_parse.compose_units` parses several
  source units as one program, exactly as their concatenation, while each item
  keeps its own file. It is the composition parse mode local projects use: a
  signature may precede its definition across a unit boundary, blank and
  comment-only units are transparent, and a recursive group may span units.
  Every unit must parse on its own, so an expression split across files is
  refused. `Span.merge` never combines offsets from different
  files (`test/test_surface_compose.ml`).

The three new store cases and the seven composition cases bring the current
source inventory to `1085 / 65 / 34`.

Local projects begin with their manifest (PKG.1 slice A,
`docs/designs/project-structure.md` §3). `Project_manifest` reads
`project.jqd`, the `project-v1` data value, and validates it against a strict
schema:

- unknown fields fail closed
- duplicates and budgets are refused
- units must be relative source paths
- `(requires (core ...))` is checked against the running Core

It prints one canonical spelling, and keeps a semantic digest (without `name`
and `metadata`) separate from the full document digest. `jacquard project
check|fmt` finds the manifest upward from the working directory, stopping at
a `.git` directory, and rewrites it atomically.

Diagnostics E1700–E1704 and E1735 are documented in `docs/errors.md`. The five
`test/test_project_manifest.ml` cases, including a 2,000-input fuzz property,
and `test/cli/project-manifest.t` bring the source inventory to
`1090 / 66 / 34`.

A project without dependencies then composes and runs. `jacquard project
check|run|test` composes the library units as one program, applies the library
rules and the namespace contract, and checks the library once. Each entry is
composed separately over the frozen library, and only the tests an entry's own
units bind are discovered. Declared grants are compared with checked authority
(W1700, or E1730 under `--strict-grants`) and never granted. Unit paths are
contained, regular, bounded and listed once. `test/cli/project-local.t` covers
each refusal and location independence, bringing the source inventory to
`1090 / 67 / 34`.

Projects then depend on one another. Each library in the graph is composed
dependency-first into one store and resolved in its own view: its bindings,
its direct dependencies' export projections, and the prelude. Private names
(E1705) and private identities (E1709) are refused, in client code and in
`eval-code` payloads alike. A dependency is pinned by its `project-context-v1`
identity. `jacquard project pin` writes the pins atomically after rechecking
every file it read (E1733), and every build compares them (E1710, transitive
E1712). `test/cli/project-deps.t` covers two libraries with private helpers,
pins and their change reports, and each graph refusal.
`test/test_project_frontend.ml` covers pin stability and the concurrent-edit
refusal. Together they bring the source inventory to `1092 / 68 / 34`.

A project then travels as a bundle. `jacquard project bundle` writes the
closure's objects with their interfaces, contexts and companions. Each run
step is a separately checked thunk, and each test entry is a list of typed
Warp roots. The bundle is published atomically, byte-identical for identical
inputs, and refused when `eval-code` is reachable from any root. `--bundle`
runs and tests a bundle only after verifying it in full: hashes, ownership,
closure, type checks, re-derived interfaces and recomputed contexts, prelude
and Core. A bundle is also a dependency, pinned by the same context identity
as its source. `test/cli/project-bundle.t` covers each refusal and a second
checkout that calls an exported callable by its labels, bringing the source
inventory to `1092 / 69 / 34`.

The four applications are now local projects. `display`, `dice-coach`,
`picnic-planner`, `rota-optimizer`, `formula-notebook` and the shared
interaction `suite` each have a manifest; `display` exports only the two
helpers the models use. `run.sh` is a thin wrapper over `jacquard project`,
with no concatenation. `jacquard project build` compiles a `(native)` run entry
in a fresh per-build directory and finds bodies by reachability.
`test/cli/applications.t` keeps its transcript: every demo and interactive
session under both engines, the manifests, and the 25/17/18 suites. It adds
the migration proofs: every entry's bindings hash exactly as the old
concatenation, a non-exported display helper is refused by name, by hash and
through eval, and no `cat` remains. The source inventory stays
`1092 / 69 / 34`.

A documentation-only onboarding exercise (`docs/onboarding/exercise.md`) asks
an unfamiliar developer to set up, run, test, change, diagnose and natively
build the rota optimizer from the public documents, with facilitator rules
and a recording sheet. The owner's own read-through is recorded as owner
review, never as participant evidence. `test/cli/onboarding.t` keeps every
scripted step and promised outcome true, bringing the source inventory to
`1092 / 70 / 34`. The participant exercise itself remains to be
run.

The whole-feature review of local projects then closed these gaps:
- **Output overlap (E1725).** It now guards native `project build -o` outputs
  and `project test --cache-dir`, as well as bundles, so no command can
  overwrite a unit or write into a dependency.
- **Tracked state (W1701).** Git tracking any file under `.jacquard/` now
  draws a warning.
- **Split signatures (W1702).** A definition that fails its signature in
  another unit is reported with both files named.
- **Test cache.** `project test` now actually reuses its Warp cache: its
  `.jacquard/` parent was never created, so every run missed.
- **Refusal text.** The manifest and grant refusals are pinned by their exact
  text.

`test/cli/project-guards.t` covers these, and also: `test` and `build` from
three working directories with an empty `HOME`, an interrupted pin leaving
the manifest intact, dependency order not affecting pins, and the
two-library native build. That brings the source inventory to
`1092 / 71 / 34`. The project-structure design's §11 now records the
implemented store policy: a fresh temporary store per command.

List-based predicates follow (SX.30, DES.4 §6). `bool.all`, `bool.any`,
`list.all?`, `list.any?`, `int.between?` and `real.between?` are new ring-0
prelude objects beside `bool.and` and the integer comparisons, and no existing
identity changes. The ring-0 freeze golden gains exactly their six signatures,
as the numeric dictionaries' did, and the tier table counts six more terms. The rota optimizer's staff
validation becomes one flat `bool.all` list. It gives the same verdict as the
nested `bool.and` tree it replaces on a valid record and on eleven
single-field violations, and the demo transcript is unchanged. Because the
prelude identity changed, the applications' dependency pins were re-pinned.
Three `test/test_stdlib.ml` cases, `test/cli/predicates.t` (interpreter and
native parity, and the rota verdicts) and the `stdlib-predicates` doctest bring
the source inventory to `1095 / 72 / 35`.

Surface sugar then binds the prelude's constructors by identity (SX.31). `if`,
list literals and `try` elaborate against the prelude's `Bool`, `List` and
`Result` constructors, so a file declaring its own `True`, `Cons` or `Ok`
cannot capture them. Programs already resolving to the prelude keep their
hashes. The three `test/test_sugar_identity.ml` cases pin the identities
against the loaded prelude, show that each sugar's hash ignores same-named
file constructors, and confirm that stub environments still resolve by name.
Together they bring the source inventory to `1098 / 72 / 35`.

`with` is now a reserved word, ahead of the nominal field update form that
DES.4 records as approved (`Ctor(value with label: expr, ...)`). No source used
it as a bare name. A stray use names the reserved word and the `term:` escape,
and one `test/test_surface_scaffold.ml` case brings the source
inventory to `1099 / 72 / 35`.

Labeled fields now have generated setters as well as accessors (SX.28, DES.4
Phase 1). A type's labels generate `<type>.with-<label>` setters, total over sum types
and type-changing on parametric fields. Each setter hashes as its hand-written
twin and carries the field label as its call label. E1241 guards setter
collisions as it guards accessors. Two `test/test_surface_decls.ml` cases bring
the source inventory to `1101 / 72 / 35`.

The maintained applications now use those features instead of their
workarounds (APP.12). The rota report and parser use single interpolations and
`text.to-int`, the notebook uses the ASCII classifiers, Text patterns and
interpolation. The rota and the notebook use the list predicates, all four use
the range checks, dice, picnic and the shared display use `real.from-int`, and both
larger models read and update records through generated accessors and
setters. Every `EXAMPLE.txt` and `CUSTOM-EXAMPLE.txt` is unchanged, the
suites keep their checks apart from the notebook's end-of-input assertion, and `test/cli/applications.t` still confirms
interpreter and native parity and composition identity. The one behavior
change is that a blank notebook line reprompts instead of ending the
session. `display.fixed3` keeps its half-up rounding, which
`display-tests.jac` now pins, because `text.from-real-fixed` would change a
published digit. `demos/applications/README.md` lists what was retired and
what was kept. No suite or cram was added, so the source inventory stays
`1101 / 72 / 35`.

Several fields now update in one expression (SX.28b, DES.4 Phase 2).
`Ctor(value with label: e, ...)` takes exactly one value before the reserved
word `with` and one or more labeled fields after it. It elaborates to, and
hashes as, the explicit let-and-match twin: the value is evaluated first, then
each new field once, in source order, under the interpreter and natively.
Unknown and repeated labels are E0305/E0306 at the label, a malformed form is
E1220, and on a sum type the refused one-clause match (E0813) names the total
setter. The formatter prints the form back and never trades it for setters. The
notebook's two multi-field rebuilds use it with every transcript unchanged.
Five `test/test_surface_field_update.ml` cases and
`test/cli/surface-field-update.t` bring the current source inventory to
`1106 / 73 / 35`.

`fmt` no longer lets a trailing line comment swallow the syntax after it. A
comment ending a call or named argument, a `with` field update or its value, a
list or tuple item, a parameter, a pattern field, a type argument, an `if`
condition, a pipe operand, an annotation, or the last arm or item before a
closing brace used to be followed on the same line by the next comma, keyword,
or delimiter, so the output no longer parsed while `fmt` still exited 0. The
printer now checks whether the rendering it is about to continue ends in a line
comment and, if so, starts the next line with that token; after a commented
final item it omits the optional trailing comma. Comments inside a single pair
of `()` and around a sequenced match arm's braces are kept instead of dropped;
a comment inside directly nested parentheses was still dropped until the
follow-up below. Output
without comments is unchanged, except that a lone
arrow parameter that breaks onto its own line no longer takes the vertical
trailing comma, which spelled a one-element tuple type. The E1238 summary now
names the `with` field update as well as the named call. Two
`test/test_surface_trivia.ml` cases, one `test/test_surface_laws.ml` case, and a
`test/cli/surface.t` section bring the current source inventory to
`1109 / 73 / 35`.

A follow-up closes three more `fmt` robustness gaps. A mutually recursive group
of surface definitions, such as `corpus/valid/even-odd.jac`, fell back to the
raw `jqd { (defterm ...) }` escape even without comments, because the printer
recognized group members only through internal group references and not
through the names lowering uses to form the group. It now prints as adjacent
definitions with the same hashes. A surface comment that did reach that escape
was copied verbatim, but the bootstrap reader only knows `;` comments, so the
output did not parse; the escape now carries each comment as `; ` followed by
its original text. As a last line of defense, `jac fmt` reparses its own
output and exits 1 with E1204, printing and writing nothing, if a printer bug
would produce text that does not parse. A comment after a definition's `=` no
longer spreads the parameter list vertically. Parser recovery in an effect body
could stop on an invalid token or a stray `|` and loop forever; recovery there
now always consumes at least one token, and a `test/cli/surface.t` case runs
the former hang under `timeout`. Directly nested parentheses now keep their
own comment owners, so `((1 -- c1\n) -- c2\n)` keeps both comments; this also
stops a comment in a parenthesized block from being printed twice. Comment-free
output of every tracked `.jac` file is byte-identical to the previous printer
except `corpus/valid/even-odd.jac`, which now prints natively. Two
`test/test_surface_trivia.ml` cases, six new trivia-law sources, and two
`test/cli/surface.t` sections bring the current source inventory to
`1111 / 73 / 35`.

RT.1 adds deterministic computation fuel (`docs/computation-fuel.md`): an
optional per-invocation `fuel-v1` budget that `jacquard run`, `jacquard infer
enumerate` and `jacquard infer lw` accept as `--fuel UNITS`, and E0919 for an
exhausted, incomplete run. Without `--fuel` every command is unbounded and its
output is unchanged. Ten `test/test_invocation.ml` cases and the new
`test/cli/fuel.t` transcript bring the current source inventory to
`1121 / 74 / 35`.

RT.1's second slice extends computation fuel to `jacquard test --fuel UNITS`
(a per-test cap on one run's budget; an exhausted test is `INCOMPLETE`, never
cached, and bounded cache entries are keyed by the budget) and
`jacquard host worker --fuel UNITS` (the v0 abort outcome carries E0919), and
makes every exhausted bounded command exit 2. One `test/test_invocation.ml`
case and new `test/cli/fuel.t` and `test/cli/host-worker.t` sections bring the
current source inventory to `1122 / 74 / 35`.

RF.3 separates typed observation production from versioned trace projections
(`docs/observation-boundary.md`): the evaluator root produces ordered
`Observation` events (operations with their arguments, trusted output, and root
handler results) to an observer that cannot evaluate, and `run-transcript-v1`
is a byte-identical projection of them. Schedule traces, host envelopes and
governance audit carriers are unchanged. Three `test/test_invocation.ml` cases
bring the current source inventory to `1125 / 74 / 35`.

OBS.1 adds versioned observation policies and policy-bound
`observation-transcript-v1` (`docs/observation-policies.md`): operations are
selected by identity with compared arguments, results and output; values
compare by data-v1 (constructors by identity); excluded fields and secrets
never reach bytes or diagnostics; results and output pair with their call by a
correlation id now carried on typed events; failed, incomplete (including
unfinished projections) and truncated observations are recorded; comparison is
equal, divergent or inconclusive, and refuses transcripts of different
policies. `run-transcript-v1` is unchanged. Twelve
`test/test_observation_policy.ml` cases bring the current source inventory to
`1137 / 74 / 35`.

OBS.1 adds `jacquard relate --policy`: runs are compared under an observation
policy, divergence stays E1003 and names the policy, an inconclusive comparison
is E1007, a refused policy (malformed, a stale operation identity, a mismatched
interface pin) is E1005, a runtime failure is recorded as an observation, and
the equal verdict names the policy identity. `jacquard relate` without a policy
is unchanged. The new `test/cli/relate-policy.t` brings the current source
inventory to `1137 / 75 / 35`.

FMT.3 keeps comments inside parenthesized types: a parenthesized type records
a `paren` container (and its body) like a parenthesized expression, a group
that owns comments keeps its parentheses with each comment on its own side of
`(`, and positional constructor fields stay on one line when a field owns such
a group. Comment-free types format as before. The formatter's reparse guard
(E1204) now also refuses output that drops or alters a comment, or that would
format differently on a second pass, so a remaining printer gap fails loudly
instead of losing a comment or printing an unstable layout. One
`test/test_surface_trivia.ml`
case brings the current source inventory to `1138 / 75 / 35`.

The scoped effect instance checker (slice 1 of
`docs/designs/scoped-effect-instances.md`) adds 14 cases: the new
`test/test_scoped_instances_checker.ml` suite and instance-entry, label-sort and
occurs cases in `test/test_types.ml`. Instance declarations are registered on
test checker contexts only. The source inventory is now `1152 / 75 / 35`.

The State runtime of scoped effect instances (slice 2, design §10 A2) adds
`prelude/32-scoped-instances.jqd` (`state.scoped`, `state-ref`,
`state-instance`, `state.get-at`, `state.put-at`) and registers it on every
production checker context. It adds seven cases: the new
`test/test_scoped_instances_runtime.ml` suite and the trusted-scheme case in
`test/test_scoped_instances_checker.ml`. It also adds one cram file,
`test/cli/scoped-instances.t`, which pins the interpreter result and the native
refusal (E1101). Every retained prelude hash is unchanged; the prelude hash
golden only gains lines.

**Migration:**

- An existing store refuses the new prelude (E0705, "added declarations");
  re-initialize the store.
- Retained interface-v1 manifests and sealed checked artifacts fail with
  `Prelude_changed`, and retained bundles fail with E1720; regenerate them.
- Project context identities that include the prelude manifest change.

The source inventory is now `1159 / 76 / 35`.
