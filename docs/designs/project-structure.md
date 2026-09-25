# PKG.0 Local Project Structure

- Status: design for task 217 (PKG.1), revised after an independent
  architecture review. Nothing here is implemented. The owner decisions are
  listed in §17.
- Date: 2026-09-25
- Base: `main` with API.1 (`interface-v1`), RF.2 (invocations), INF.1 and SX.29.
- Scope note: `AGENTS.md` excludes package management from 0.2 release
  hardening "until the owner decides otherwise". The owner directed this
  design, and task 217 is its implementation. PKG.1 is post-0.2 feature work.
- Inputs:
  - task 217's acceptance criteria
  - DES.4 §7
  - the owner's long-range package draft (`docs/jacquard-package-cli.md`, draft
    0.1, untracked in the owner's checkout)
  - a code-grounded review of the first draft of this document

## 1. Question

Multi-file Jacquard programs are assembled today by concatenation.
`demos/applications/run.sh` `cat`s authored files in a fixed order into one
temporary `.jac`. Two applications share `shared/display.jac` by including it
in both concatenations. Names are prefixed by hand (`rota.solve`,
`RotaStaff`). Every checked name lands in one mutable `names.jqd` per store, so
nothing is private.

PKG.1 needs a project format that:

1. replaces concatenation with declared composition, with exactly the same
   semantics
2. gives libraries a real public/private boundary for client code
3. pins dependencies exactly, so a build never resolves anything
4. lets a second checkout check and run an exported callable
5. gives one run, test and build workflow that does not depend on the working
   directory
6. can grow into the package draft (registry, signatures, upgrades) through
   additive, versioned extension

It must do this without changing the kernel, `.jqd`, `HASH_V0`, the store
object format, `interface-v1`, or any existing single-file command.

## 2. Facts This Design Is Built On

Each fact is checked against the code. The first draft got the first one
wrong.

| fact | evidence | consequence |
|---|---|---|
| Nominal names hash. Type, constructor, field-label, effect and operation names inside `deftype`/`defeffect` are hashed content; term binding names are erased | `src/canon.ml` header and its type/effect encoders | Rewriting names to add a namespace changes identities. v1 does not rewrite (§4) |
| The store has immutable content-addressed `objects/` and one mutable `names.jqd` holding `named`, `hidden` and `call-abi-v1` entries; `hidden` is a global flag | `src/store.ml` | Visibility cannot be a global flag; it is relative to a consumer (§5) |
| Explicit hash references (`term:#h`, `.jqd` `(ref #h)`) bypass name lookup; `Store.locate` refuses only globally hidden hashes | `src/resolve.ml` (`resolve_gref`), `src/surface_lower.ml` (`HashRef`), `src/store.ml` | Privacy must cover explicit identities, not just names (§5) |
| The frontend hard-codes `Store.names_view`; native compilation discovers bodies by iterating `store.names`; Warp discovers tests from the whole store | `src/frontend.ml`, `src/native/build.ml`, `src/warp.ml` | A project needs one frontend service that feeds every consumer (§6) |
| Surface lowering groups definitions across the whole parsed file, with SCCs and dependency-first order | `src/surface_lower.ml` | Checking unit by unit is not concatenation; units must be composed as parsed source (§6) |
| `interface-v1` records the exact identities and owner hashes of exports, and its `diff` classifies an identity change as breaking | `src/interface.mli`, `docs/release/api-identities/DECISION.md` | For a static closure, the interface identity already pins the implementation (§8) |
| Quoted names are data, and `eval-code` resolves against the live store's names | `src/resolve.ml`, `src/prelude.ml` | Closures are not closed under `eval`; v1 restricts it (§9) |
| Objects are written in place, `names.jqd` is rewritten, and rollback deletes unexpected files | `src/store.ml` | Stores are not safe to share between concurrent writers (§11) |

## 3. The Manifest: `project.jqd`

A project is a directory containing `project.jqd`: a **data value** in the
permanent bootstrap carrier. It is read with the existing reader, validated by
a strict schema, and never evaluated.

```text
(project-v1
  (name "rota-optimizer")
  (requires (core "0.2"))
  (namespace rota)
  (units "model.jac" "fixtures.jac" "report.jac")
  (exports (term rota.solve) (term rota.render-report)
           (type rota-problem) (type rota-solution) (type rota-status))
  (deps (dep (as display) (path "../shared") (pin #9c07…)))
  (entries
    (run demo (units "demo.jac") (grants console) (native))
    (run interactive (units "interactive.jac") (grants console) (native))
    (test suite (units "tests.jac" "interaction-tests.jac")))
  (metadata (description "Shift rota optimizer") (license "Apache-2.0")))
```

| field | meaning |
|---|---|
| `name` | display text. Not identity, not resolution |
| `requires` | the Core version range this project needs, checked against `jacquard --version` before anything runs. Exact prelude identities live in pins and bundles (§8, §9) |
| `namespace` | optional. The prefix contract of §4 |
| `units` | library units, in composition order, **declarations only** (§6) |
| `exports` | the public surface, as explicit `(kind store-name)` selectors, with kinds `term`, `con`, `op`, `type` and `effect`. Store spellings are used (`rota-problem` is the store name of `RotaProblem`), so the bootstrap reader can read every entry |
| `deps` | direct dependencies: an alias (a diagnostic label only in v1), a source (`(path P)` in v1), and one exact pin (§8) |
| `entries` | entries keyed by `(kind, name)`. `run` entries may be marked `(native)` for `project build` |
| `metadata` | a preserved, explicitly **non-semantic** container (description, license, authors, homepage). Tools may display it; it never affects checking, identity or pins |

**Strictness and evolution:**

- Unknown fields outside `metadata` are refused, never ignored. So are
  duplicate fields, duplicate `(kind, name)` entries, and duplicate export
  selectors.
- The head `project-v1` is the format version. There is no second version
  field.
- **Newer tools must keep accepting `project-v1` forever.** New semantics
  arrive only as a new head (`project-v2`) or as new tagged alternatives
  inside a field that the v1 reader already refuses by name. Examples:
  - dependency sources `(registry …)` alongside `(path …)`
  - `(features …)`
  - entry-scoped `(dev-deps …)`

  A v1 tool therefore fails closed on a newer manifest, rather than
  misreading it.
- `jacquard project fmt` prints the one canonical spelling. Field order is
  free on input.

**Budgets (checked before and during parsing):**

| resource | limit |
|---|---|
| manifest size | 64 KiB, checked before parsing |
| any text | 1 KiB |
| units | 256 |
| entries | 64 |
| exports | 1024 |
| direct dependencies | 64 |
| whole dependency graph | at most 256 projects and depth 32 |
| bundles | a configurable byte budget (§9) |

**Why a bootstrap data file:**

- the reader and canonical printer already exist
- the package draft chose a Jacquard value (`package.jqd`)
- a data-only head carries no evaluation risk
- strict schemas over forms mirror the host protocol's strict JSON

## 4. Namespaces: A Checked Prefix Contract (No Rewriting)

Because nominal names hash (§2), a namespace that rewrote `Staff` into
`RotaStaff` would change identities, and would make source meaning depend on
hidden context. v1 therefore **rewrites nothing**. `(namespace rota)` is a
contract checked against the names the source already spells:

| store kind | required spelling | source spelling |
|---|---|---|
| `term`, `op` | `rota.<rest>` | `rota.solve` |
| `type`, `con`, `effect` | `rota-<rest>` | `RotaStaff` (store `rota-staff`) |
| generated accessors | follow their type | `rota-staff.id` |

The rules:

- Every name that the library units bind must satisfy the contract (E1706).
  This includes generated accessors and setters.
- Entry units are exempt, because their names are never visible outside the
  entry.
- The boundary is exact: a `.` or `-` immediately follows the namespace, so
  `rotation.x` does not satisfy `rota`.
- **Namespace disjointness.** No two projects in one dependency graph may have
  namespaces where one is a boundary-prefix of the other (`rota` and
  `rota-staff`), and no two may share a namespace (E1707). This makes every
  exported name unambiguous by construction, without inferring provenance
  from spellings.
- A project without `namespace` has no contract. That is allowed for leaf
  applications, but a project used as a dependency must declare one (E1708).

**Consequences:**

- Source is self-describing: every file states its full names, editors show
  the true spelling, and a file's meaning does not change with its project
  (§14).
- Identities are exactly today's. The four applications already follow the
  contract, so migrating them changes no hash (§13).
- The ergonomic step from DES.4, writing `solve` and getting `rota.solve`, is
  **deferred** to a later version (§16 decision 2). If it arrives, it will be
  a surface-level local alias, with its identity effect stated and tested.

## 5. Visibility: Language Access for Client Code

A project's checked code may refer to three things:

1. **Local:** everything its own library units bind, and, inside an entry,
   the entry's own bindings.
2. **Dependency exports:** for each **direct** dependency, exactly the
   `(kind, name)` selectors in its `exports`, as recorded in its pinned
   interface. A dependency of a dependency is not visible unless re-exported.
   Re-export means listing the name in one's own `exports`, which v1 allows
   only for names one's own units bind. Re-exporting a dependency's name is
   deferred.
3. **The prelude:** the public index of the pinned prelude.

This single rule applies to **names and to explicit identities**:

- A name that resolves outside the visible set is E1705. For example:
  "`display.pad-to` is private to project `display`".
- An explicit identity in client code must identify something visible by the
  rule above. That covers `term:#h`, surface `HashRef`, and `.jqd` `(ref …)`
  in expressions, types, patterns and handler clauses. Otherwise it is E1709,
  "hash … is not visible in this project". A dependency's private helper
  cannot be reached by knowing its hash.
- **Already-checked dependency bodies are trusted and traversed by identity.**
  Visibility restricts what *new client code* may reference. It does not
  re-check a dependency's internals, which legitimately reference their own
  private objects.
- **Visibility is relative, never global.** It is a property of a
  (consumer, provider) pair computed by the project frontend (§6). The store's
  existing `hidden` flag keeps its current meaning (opaque prelude and host
  members) and is not reused for project privacy. Each provider is verified
  against **its own** interface in **its own** store (§11). This avoids
  `Interface.verify`'s global-exposure check confusing one package's export
  with another's private member.
- If two direct dependencies both export the same identity (for example, both
  re-export a shared type in a later version), that identity is visible once.
  The rule depends on identities, not on installation order.

**What this is and is not.** This is **language access control** for checked
client code. It is not concealment: private objects are present in stores and
bundles, readable by anyone with the files, and reachable by unchanged
low-level commands. The design says so in diagnostics and docs.

## 6. The Project Frontend Service

One internal service, `Project_frontend`, is the only way project commands
prepare code. It is built beside `Frontend` and reuses its checking.

1. **Compose.** Read the manifest and pinned dependency interfaces. Parse
   every library unit, then concatenate their **parsed top-level items** in
   unit order, keeping each item's source span and file. Lower that composed
   file once. Grouping, SCC ordering, signature adjacency and cross-file
   recursion are therefore exactly what concatenation gives today (§2).
2. **Library rules:**
   - Library units are declarations only; a top-level expression is E1715.
   - A name defined twice across units is E1716, naming both files. Generated
     accessors count as definitions, so an accessor colliding with an
     explicit term in another unit is caught.
3. **Resolve with a composed view.** It builds a full `Resolve.names` value
   that populates every callback, not only lookup:
   - lookup
   - suggestions
   - constructor schemas
   - callable call-ABIs

   It is built from the local bindings plus the visible dependency exports
   plus the prelude, and it replaces `Store.names_view` for project code.
   Explicit identities are checked against the same visibility (§5).
4. **Freeze the library, then overlay each entry.** The checked library
   environment is immutable. Each entry composes its own units over it the
   same way (parsed items after the library), with top-level expressions
   allowed in `run` entries and evaluated in source order.
5. **Feed every consumer from the project context:**
   - **Native compilation** discovers callable bodies by reachability from the
     entry's roots by hash, not by iterating `store.names`. Two libraries with
     private `helper`s of different bodies then cannot shadow each other.
   - **Warp discovers only the tests an entry owns**: the test declarations
     bound by that entry's own units. It never scans the whole store.
   - **Checked artifacts** record the project context (manifest digest and
     pins), not an assumed global index.

## 7. Entries, Grants and the CLI

| entry | semantics |
|---|---|
| `(run NAME (units …) [(grants …)] [(native)])` | evaluate the entry units' top-level expressions in order; `(native)` makes it buildable |
| `(test NAME (units …))` | run the Warp declarations bound by these units, with the existing `--samples`, `--exhaustive`, `--budget`, `--seed` and cache flags |

- Entry units see the library and the visible dependencies, and nothing
  outside the entry sees them.
- **Grants are declared, never granted.** `project check` compares an
  entry's `(grants …)` with its checked authority. It uses the **existing
  authority normalization**, so for example `console` covers `ConsoleInput`
  and scheduler effects keep their special handling. A mismatch is a warning
  (W1700), and an error under `--strict-grants` for CI.
  - `project run` still requires `--allow` on the command line, and native
    binaries keep their runtime grant enforcement.
  - A manifest can never grant authority.

The CLI is a new group. Existing commands do not change.

```text
jacquard project check     [--project DIR] [--strict-grants]
jacquard project run       [--project DIR] ENTRY [--allow …] [--seed N]
jacquard project test      [--project DIR] [ENTRY] [Warp flags]     # no ENTRY: every test entry
jacquard project build     [--project DIR] ENTRY [-o OUT]
jacquard project pin       [--project DIR] [--dep ALIAS …] [--dry-run]
jacquard project interface [--project DIR]
jacquard project bundle    [--project DIR] -o BUNDLE
jacquard project fmt       [--project DIR]
```

**Discovery.** Without `--project`, the CLI uses the nearest `project.jqd`
found by searching upward from the working directory. The search stops at the
first directory containing `.git` or at the user's home directory, whichever
comes first, and the chosen project is printed in every diagnostic header.
Manifest paths are relative to the manifest. Runtime file I/O performed by
the program keeps today's semantics, relative to the process's working
directory. The design states this explicitly so that it is not surprising.

## 8. Dependencies and Pins

A dependency is `(dep (as ALIAS) (path P) (pin #I))`, where **`#I` is the
dependency's exact `interface-v1` identity**.

- **What the pin covers.** `interface-v1` records the exact identities of the
  exports and their owners. For a static closure, those identities
  transitively commit to every reachable implementation object. So one exact
  pin covers behaviour, labels and visibility. The first draft's separate
  "implementation hash" was redundant for static closures and is dropped. The
  `eval` path, which the static closure does not cover, is restricted in §9.
- **Builds never resolve.** `check`, `run`, `test` and `build` recompute
  each dependency's interface identity from its source and compare it with the
  pin. A mismatch is E1710. It reports:
  - the `interface diff` against the **previous interface artifact**, if
    `.jacquard/interfaces/<identity>.jqd` still holds it
  - otherwise, an honest "the previous interface is unavailable in this
    checkout"
- **The authoring state.** A dependency without `(pin …)` is accepted only by
  `project pin`. Every other command refuses it (E1711).
- **The `project pin` workflow:**
  - `--dry-run` prints the plan: each dependency's old and new identity and
    the diff classification.
  - Without it, `pin` writes the new manifest **atomically**: a temporary file
    in the same directory, fsync, then rename.
  - `--dep ALIAS` updates selected dependencies only.
  - It saves each pinned interface under `.jacquard/interfaces/` so future
    diffs have their baseline.
  - It never edits a dependency's own manifest.
- **Transitive pins.** A dependency's own pins must verify (E1712). The
  diagnostic reports the chain of aliases. The root cannot override them.
- **Compatibility classification** ("drop-in", "additive") is **deferred.**
  `interface-v1` identities are exact, and `diff` rightly treats an identity
  change as breaking. A future, separately versioned compatibility projection,
  signatures only, can provide drop-in classification without changing
  API.1's meaning.

**Graph identity:**

| concept | used for |
|---|---|
| source location | `(path "../shared")`, as written |
| filesystem identity | the canonical real path after resolving symlinks; used to walk the graph and detect cycles (E1713) |
| artifact identity | the pin; used to deduplicate dependencies |
| package identity | reserved for the registry (publisher and name) |

When one namespace appears in the graph at two artifact identities, the
project is refused (E1714). This is a **deliberate v1 restriction**, stricter
than the package draft, which permits private version skew. It is recorded so
it can be relaxed later.

## 9. Bundles: The Second Checkout

A bundle is the runnable, verifiable form of a project. It is produced by
`jacquard project bundle -o app.bundle` and written atomically: built in a
sibling temporary directory, then renamed into place.

```text
app.bundle/
  bundle-v1.jqd       -- root record (below)
  project.jqd         -- the manifest, canonical spelling
  interfaces/         -- the project's and each dependency's interface-v1 manifest
  objects/<hash>.jqd  -- canonically re-printed objects (not copied cache bytes)
```

Entries become **generated entry declarations**, so each is a hashed object:

- A `run` entry's ordered top-level expressions become one generated term,
  `entry/<name>`: a thunk that evaluates them in order. It is recorded with
  its declared grants.
- A `test` entry becomes the list of its owned Warp declaration identities.

The root record `bundle-v1` binds these fields:

- the manifest digest
- the project interface identity
- each dependency pin
- the prelude identity checked against
- the Core version
- each entry: its kind, name, root identity and grants
- the object count

The **bundle identity** is `HASH_V0` of the canonical encoding of that record,
under a domain tag `bundle-v1`. It is distinct from any interface identity.

`jacquard project run app.bundle ENTRY` verifies the bundle before running
anything:

1. **Budgets:** the byte, object-count and depth budgets.
2. **Integrity:** every object's hash and ownership.
3. **Closure:** every root's closure is complete.
4. **Identities:** each interface's recomputed identity equals its record,
   and the root digest matches.
5. **Prelude:** the prelude identity matches the running Core; otherwise E1720,
   showing both identities.
6. **Re-check.** Loading an object only validates its shape, so the whole
   closure is **type-checked on import**.

Only then does it run the entry, in a fresh temporary store under
`.scratch`-style temp space.

The round-trip test of task 217 does not stop at "run a bundled entry". It
also **checks a new source file that imports an exported callable** from the
bundle, using the bundle's interface labels and constructor schemas.

**`eval` in v1.** An entry whose checked authority includes `Eval` cannot be
bundled (E1721). Within a checkout, `eval-code` in a project resolves against
the entry's frozen composed view (§6), never the ambient store. Pinned dynamic
code is deferred.

## 10. Filesystem Policy

- **Units are contained.** After resolving symlinks, every unit path must lie
  inside the project directory (E1722). Units must be regular files (E1723).
  Two units whose canonical paths differ only in case are refused (E1724), so
  behaviour matches on case-insensitive filesystems.
- **Dependencies may be external.** A `(path …)` may use `..`, but it is
  canonicalized, must contain a `project.jqd`, and is read-only to the
  consumer.
- **No overlap.** Output paths (`-o`, bundles, build and cache roots) must not
  overlap any input unit or dependency directory (E1725).
- File reads reuse the descriptor-based regular-file checks already in
  `src/export.ml`. Bundle traversal refuses symlinks, and partial outputs are
  removed on failure.

## 11. Stores, Caches and Native Builds

- **Isolated writable stores.** Each project gets its own store at
  `<project>/.jacquard/store/`, overridable with `--store` or
  `JACQUARD_PROJECT_STORE`, and one writer holds a lock file. **Stores are not
  shared between projects in v1.** Sharing needs atomic object publication,
  writer coordination and ownership-aware rollback, which the store does not
  provide today (§2).
- **Semantic metadata.** Call-ABI companions and visibility are part of the
  project's semantic state. They are recomputed from the pinned inputs and
  never trusted from a cache.
- **Caches.**
  - Warp test caches go under `.jacquard/test-cache/`.
  - Native builds go under `.jacquard/build/<entry>/`, with the existing
    native cache moved beneath it.
  - Every cache and artifact root is passed explicitly through the APIs; none
    is working-directory-relative.
  - `project check` warns (W1701) if `.jacquard/` is tracked by version
    control.
- **Native build recipe.** A native build records:
  - Core version and emitter version
  - runtime source digest
  - compiler and its version
  - target triple
  - flags and optimization level

  The build is *semantically* reproducible from the pins. A byte-identical
  binary is claimed only when the recipe matches.

## 12. Growth Path

`project-v1` embeds in the package draft without reinterpretation:

| package draft | project-v1 | later |
|---|---|---|
| name, exports | `name`, `exports` | unchanged |
| deps (impl, iface) | `(pin #I)`: the exact interface identity, which covers the static implementation | a signature-only compatibility projection (§8) |
| hint, intent, index, added | — | tagged `(registry …)` sources beside `(path …)` |
| publisher, signature | — | a signed root over a package manifest that commits to dependencies, companions, tests and migrations, in a new head |
| migrations, `outdated`, `upgrade` | `project pin` with a plan | `add` and `upgrade` with migrations |
| workspaces, dev-only deps, features | — | reserved as named extensions (§3) that v1 tools refuse by name |

## 13. The Four Applications (Acceptance)

The manifests are sketched here and finalised by PKG.1 against the actual test
ownership:

```text
applications/shared/project.jqd          namespace display; units display.jac
                                         exports the display helpers the apps use
                                         test display (units display-tests.jac)
applications/dice-coach/project.jqd      namespace dice; deps display;
                                         run demo/interactive (native); test suite (units tests.jac)
applications/picnic-planner/project.jqd  namespace picnic; deps display; same shape
applications/rota-optimizer/project.jqd  namespace rota; units model, fixtures, report;
                                         run demo/interactive (native); test suite
applications/formula-notebook/project.jqd namespace nb; units syntax, model, commands, application;
                                         run demo (units workbook.jac demo.jac) (native);
                                         run interactive (native);
                                         test suite (units workbook.jac parser-tests.jac
                                                     model-tests.jac interaction-tests.jac)
applications/suite/project.jqd           no namespace (leaf); deps dice, picnic, display;
                                         test interaction (units interaction-tests.jac)   -- moved here from shared/
```

The routine and exhaustive lanes stay as today's flags, passed through `project
test`.

Tests that exercise private names stay in their owning project's test entry.
Cross-application interaction tests move into `suite/` and use exports only.
Any test that needs a private name is either moved to its owner or makes the
name an export, with the choice recorded.

**Migration proofs:**

1. **Identity preservation.** For every entry, the declaration hashes from
   `project` composition equal those of today's `run.sh` concatenation. A cram
   compares both; this holds because v1 rewrites no names.
2. **Behaviour.** `run.sh` becomes a thin wrapper over `jacquard project …`.
   `test/cli/applications.t` output is unchanged, including native builds.
3. **`cat` disappears** from every README and from `run.sh`.
4. **Privacy.** An application referencing a non-exported `display.` helper,
   by name or by hash, is refused (E1705 or E1709). Negative crams pin this.

## 14. Editor And Documentation Integration

- **Membership.** A file belongs to every project whose manifest lists it as
  a unit. Task 227 (the language server) picks the nearest listing manifest,
  and reports and lets the user choose when there is more than one.
- Because v1 rewrites nothing, hover and navigation show true names. The
  frontend service (§6) exposes three things to the language server:
  - the composed view
  - each export's origin (source unit, or the generated accessor and its type)
  - dependency interfaces
- **Documentation.** `project interface` produces the documentation input:
  every export, including generated accessors that source-oriented displays
  omit, with its labels, effects and origin. Rendering documentation is
  deferred.

## 15. Diagnostics

The project range is E1700–E1739, with warnings W1700–W1709. Every
diagnostic carries its span, the project path, and, for dependency failures,
the alias chain. Exit status is 1 for diagnostics and 124 for usage errors,
as today.

| code | condition |
|---|---|
| E1700–E1704 | manifest: malformed form, unknown field, duplicate field or entry or export, budget exceeded, `requires` not satisfied |
| E1705 | a name is not visible (private or undeclared) |
| E1706 | a name violates the namespace contract |
| E1707 | namespaces clash or one is a boundary-prefix of another |
| E1708 | a dependency project has no namespace |
| E1709 | an explicit identity is not visible |
| E1710 | a pin does not match |
| E1711 | a dependency is unpinned |
| E1712 | a transitive pin fails |
| E1713 | a dependency cycle |
| E1714 | one namespace appears at two artifact identities |
| E1715 | an expression in a library or test unit |
| E1716 | a name is defined twice across units |
| E1717 | an export selector names nothing |
| E1718 | an entry kind or name is unknown |
| E1719 | a call-ABI companion conflicts across the graph (E0612 in project context), detected before any store mutation |
| E1720 | the bundle's prelude or Core does not match |
| E1721 | an entry that needs `Eval` cannot be bundled |
| E1722–E1725 | path containment, non-regular file, case collision, output overlap |
| E1726–E1729 | bundle integrity: hash, ownership, closure, root digest |
| W1700 | declared grants differ from the checked authority |
| W1701 | `.jacquard/` is tracked by version control |

## 16. Validation For Task 217

- **Refusals.** Every diagnostic in §15 has a negative test with its exact
  text.
- **Fuzzing.** Manifest fuzzing covers random forms, oversized input,
  duplicates, and path forms: every input is accepted or refused with a code,
  never with a crash.
- **Determinism:**
  - identical inputs give byte-identical interfaces and bundles
  - reordering `deps` or `exports` changes nothing
  - reordering `units` changes only what concatenation order would change
- **Pin lifecycle:**
  - a private edit reachable from an export gives E1710
  - `pin --dry-run` shows the plan and diff
  - an interrupted pin leaves the old manifest intact
  - unpinned, transitive, cycle and diamond cases each have a test
- **Fresh checkout.** `HOME` points at an empty directory, and a clean clone
  followed by `project test` passes without touching any global store.
- **Bundle round trip.** Run a bundle from another directory. Check a new file
  that imports a bundled export using its labels. Tampered-object,
  wrong-prelude and `Eval` refusals each have a test.
- **Two-library example.** Two libraries with private `helper`s of different
  bodies, and an application using both. It checks, both helpers stay
  private, and native builds pick the right body for each.
- **The four applications** meet §13.

## 17. Decisions Requiring Owner Direction

1. **Scope.** Treat PKG.1 as authorised post-0.2 feature work despite
   `AGENTS.md`'s hardening note (recommended; implied by the owner's
   direction).
2. **Namespaces in v1 are a checked prefix contract with no rewriting**
   (recommended). The alternative, DES.4's automatic prefixing, changes
   nominal identities and hides meaning from source. It is deferred to a later
   version as an explicit local-alias design.
3. **A single exact pin** (the `interface-v1` identity), with drop-in
   compatibility classification deferred (recommended).
4. **Bundles refuse `Eval` entries in v1** (recommended).
5. **Refuse one namespace at two artifact identities in v1.** This is stricter
   than the package draft; recommended as a deliberate restriction.
6. **The manifest carrier.** `project.jqd`, a bootstrap data value, with a
   non-semantic `metadata` container (recommended).
7. **Track the package drafts.** `docs/jacquard-package-cli.md` and
   `docs/jacquard-registry-server.md` are untracked. This design cites the
   first. Should they become tracked design history?
