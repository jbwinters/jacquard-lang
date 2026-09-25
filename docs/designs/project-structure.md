# PKG.0 Local Project Structure

- Status: design for task 217 (PKG.1), revised after an independent
  architecture review and a second review. Nothing here is implemented. The owner decisions are
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
| `put_decl` keeps the first object's bytes for a hash-equal declaration but indexes member locations from the incoming declaration's order | `src/store.ml` (`put_decl`) | Indexes must be derived from persisted objects; this is a prerequisite fix (§11) |
| `interface-v1` identity covers exports, their labels, and hidden `(member, owner)` pairs, but not private call-ABI companions and not the prelude | `src/interface.ml` (`identity`) | One interface pin cannot commit to composition state; the pin is a separate context identity (§8) |
| A store names every member of a declaration it installs, so a provider exporting only type `ABox` still names `ABox`'s constructor, and `Interface.verify` rejects it as publicly bound | `src/store.ml` (`put_decl`), `src/interface.ml` (`verify`) | Verification uses an export projection, not the provider's store names (§5) |
| Canon normalizes signed zero and NaN, including inside quoted code, while `code.render` and `code.hash` observe the printed carrier; a quoted `-0.0` and a quoted `0.0` are hash-equal but render differently | `src/canon.ml`, `src/prelude.ml` (`code.render`) | Equal identities do not yet guarantee identical behaviour for quoted real payloads; a prerequisite normalization fix (§8) |
| The parser rejects a signature detached from its definition (E1224) per file; `Span.merge` assumes one file | `src/surface_parse.ml`, `src/span.ml` | Composition needs a composition parse mode and multi-origin spans (§6) |

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
| `requires` | `(core "MAJOR.MINOR")`: this Core release series or a later minor release in the same major, checked before anything runs. Exact prelude and Core identities are committed in context identities and bundles (§8, §9) |
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
- **Two digests.**
  - The **semantic projection** is the manifest with `metadata` removed,
    `name` removed, and `deps`, `exports` and `entries` sorted by key. It is
    encoded canonically and hashed with `HASH_V0`, domain-tagged
    `project-manifest-v1`. It changes only when semantics do.
  - The **document digest** hashes the full canonical manifest, for
    provenance.
  - A future semantic tag is part of the projection by definition, so adding
    one always changes it.

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
| a single object | 4 MiB |
| bundles | 256 MiB and 100,000 objects by default; configurable (§9) |

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

| store kind | required spelling | example |
|---|---|---|
| `term`, `op` | `rota.<rest>` | `rota.solve` |
| `type`, `effect` | `rota-<rest>` | `RotaStaff` (store `rota-staff`) |
| generated accessors | follow their type, `<type-kebab>.<label>` | `rota-staff.id` |
| `con` | **exempt**; a constructor is owned by its type | `GeneralSkill` of `RotaSkill` |

The rules:

- **Constructors are exempt because they are owned.** The applications'
  constructors are unprefixed (`GeneralSkill`, `Bold`, `Sunny`, `ProvenOptimal`)
  and renaming them would change their types' hashes. A constructor is
  therefore governed by its owning type:
  - it is exported exactly when its type is exported with constructors, and
    stays hidden when the type is exported abstractly
  - it is never checked against the prefix
- **Visible constructors must not collide.** Constructor names that become
  visible together (local, dependency exports, prelude) are checked
  explicitly. Two with the same name from different owners is E1731, naming
  both owning types and projects. This keeps resolution unambiguous without
  renaming anything.
- The contract applies to library units only (E1706); entry units are exempt.
- The boundary is exact: `.` or `-` immediately follows the namespace, so
  `rotation.x` does not satisfy `rota`.
- **Namespace disjointness.** After projects are deduplicated by context
  identity (§8), no two distinct projects in a graph may share a namespace, and
  none may be a boundary-prefix of another (`rota` and `rota-staff`) (E1707).
  E1707 is checked before E1714.
- A project without `namespace` has no contract. That is allowed only for a
  project nothing depends on (E1708).

**Consequences:**

- Source is self-describing: every file states its full names, and editors
  show the true spelling (§14).
- Identities are exactly today's. The applications satisfy the contract
  after the constructor exemption. A second review checked this for `rota`,
  `nb` and `display`, and PKG.1 confirms `dice` and `picnic` in its manifests
  (§13).
- The DES.4 ergonomic step, writing `solve` to get `rota.solve`, is deferred
  (§17 decision 2).

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
- **Dynamic code goes through the same gate.** Code reaching `eval-code` is
  checked like new client source: names **and** explicit identities must be
  visible in the running entry's project view. Ordinary quoted references are
  data until executed. Live `unquote` splices are checked immediately, like
  any client expression.
- **Visibility is relative, never global.** It is a property of a
  (consumer, provider) pair computed by the project frontend (§6). The store's
  existing `hidden` flag keeps its current meaning (opaque prelude and host
  members) and is not reused for project privacy.
- **Each provider has two views:**
  - an internal view, which its own checked bodies use
  - an **export projection**, containing only its `exports` and the
    constructors of types exported with constructors

  A provider is verified against its export projection, never against its
  store's full name index. That index names every declaration member, so an
  abstract type's constructor would otherwise be reported as publicly bound
  (§2).
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

1. **Compose the library.**
   - Parse every library `.jac` unit in a **composition parse mode**. This
     mode defers file-boundary checks, such as a signature detached from its
     definition (E1224), until after composition.
   - Concatenate the parsed top-level items in unit order and lower them
     **once**. Grouping, SCC order, signature adjacency and cross-file
     recursion are then what concatenation gives today.
   - A `.jqd` unit contributes its kernel top-level forms, in place, at its
     unit position. It is already lowered, so it takes part in ordering but
     not in surface grouping.
2. **Multi-origin spans.**
   - Every item keeps its own file and span.
   - A generated node spanning items from different files, such as a recursive
     group's merged span, records the list of origins rather than one merged
     span, because `Span.merge` assumes a single file.
   - Diagnostics print every origin.
3. **Library rules.**
   - Library units are declarations only; a top-level expression is E1715.
   - A name defined twice across units is E1716, naming both files. Generated
     accessors count as definitions.
4. **Resolve with a composed view.** Build a full `Resolve.names` value from
   the local bindings, the visible dependency export projections (§5), and
   the prelude, populating every callback:
   - lookup
   - suggestions
   - constructor schemas
   - callable call-ABIs

   Explicit identities are checked against the same visibility (§5).
5. **Freeze the library.** Once checked, the library is immutable.
   - Each entry's units are composed and lowered **separately** over the
     frozen library.
   - Entry definitions may reference library names, but cannot take part in a
     library recursive group; an entry name that the library references is
     E1732.
   - `run` entries may contain top-level expressions.

   This matches today's `run.sh`, where library files precede entry files and
   the library never calls entry code.
6. **Feed every consumer from the project context:**
   - **Native compilation** discovers bodies by reachability from roots by
     hash, never by iterating `store.names`.
   - **Warp discovers only the tests an entry owns.**
   - **Checked artifacts** record the project context identity (§8), not an
     assumed global index.

## 7. Entries, Grants and the CLI

| entry | semantics |
|---|---|
| `(run NAME (units …) [(grants …)] [(native)])` | evaluate the entry units' top-level expressions in order; `(native)` makes it buildable |
| `(test NAME (units …) [(grants …)])` | run the Warp declarations bound by these units, with the existing `--samples`, `--exhaustive`, `--budget`, `--seed` and cache flags |

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
  - Test entries may also declare `(grants …)`. It is compared with the
    authority that Warp requires for the entry's world tests, using Warp's
    existing world-test authority check.
  - Under `--strict-grants`, a mismatch is the error E1730 rather than the
    warning W1700.

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

A dependency is `(dep (as ALIAS) SOURCE (pin #C))`, where `SOURCE` is
`(path P)` or `(bundle B)` (§9). `#C` is the dependency's **project context
identity**.

**`project-context-v1`.** It is `HASH_V0` over the canonical encoding of the
record below, domain-tagged `project-context-v1`, with every collection
sorted:

```text
(project-context-v1
  (interface #<interface-v1 identity>)
  (companions (call-abi-v1 #<callable> (slot positional|named <label>)…)…)
  (prelude <prelude identity form>) (core "<version>")
  (deps (dep <alias> #<context identity>)…))
```

The record's parts:

- `interface`: exports, labels and hidden members, with API.1's meaning
  unchanged.
- `companions`: every call-ABI companion in the **export closure**, private
  ones included, using the store's existing `call-abi-v1` form.
- `deps`: the dependency's own pins.

Companion records and `deps` are sorted by hash and by alias; the **slots
inside a companion keep their ABI order**. The identity is `HASH_V0` of the
canonical `.jqd` bytes of this form. Its head, `project-context-v1`, is the
domain tag.

Why this record: API.1's interface identity is exact about exports, but omits
private companions and the prelude (§2). A private label change leaves the
interface identity unchanged, yet can make two otherwise identical callables
conflict (E0612). The context identity commits to both, and **`interface-v1`
keeps its meaning.**

The context identity commits to **what a dependent can reach**. Two
dependency projects with equal records are interchangeable for every
consumer, so deduplicating them by context identity is correct. A private
body unreachable from any export is invisible to consumers and is not
committed. A project's own entries are committed separately, by the bundle
identity (§9).

Companion conflicts are checked across the whole composed graph before any
store mutation (E1719), not only within one export closure.

**What a matching pin guarantees:**

- It guarantees exact identities of every reachable object, and the exact
  composition state (labels, prelude, dependencies).
- It does **not yet** guarantee identical behaviour where quoted real payloads
  differ only in signed zero or NaN bits. Those are hash-equal but observable
  through `code.render` (§2).
- Normalizing quoted reals in the printed carrier is a **prerequisite
  conformance fix**, and PKG.1's bundle and pin tests include that case.

**Builds never resolve.** `check`, `run`, `test` and `build` recompute each
dependency's context identity and compare it with the pin. A mismatch is
E1710. The report carries:

- the `interface diff` against the stored previous interface, if
  `.jacquard/interfaces/<identity>.jqd` holds it
- otherwise, an honest "previous interface unavailable"
- which record components changed (interface, companions, prelude, or
  dependencies)

**Pin workflow:**

- A dependency without `(pin …)` is accepted only by `project pin` (E1711).
- `pin --dry-run` prints the plan: old and new context identity, changed
  components, and the interface diff.
- `pin` first computes every identity from a **snapshot**. It reads each unit
  and **every manifest in the graph** (root and dependencies) once, records
  their `HASH_V0` digests, and rechecks all of them immediately before
  writing. If any file changed during pinning, it aborts with E1733.
- It then writes the manifest atomically: a temporary file in the same
  directory, fsync, rename.
- `--dep ALIAS` selects dependencies. `pin` stores the pinned interfaces for
  future diffs, and never edits a dependency's manifest.
- **Transitive pins** are verified (E1712) and reported with their alias
  chain. The root cannot override them.
- **Compatibility classification** ("drop-in", "additive") is deferred to a
  future, separately versioned, signatures-only projection.

**Graph identity:**

| concept | used for |
|---|---|
| source location | as written |
| filesystem identity | the canonical real path; used to walk the graph and detect cycles (E1713) |
| artifact identity | the context identity; used to deduplicate |
| package identity | reserved for the registry |

One namespace at two context identities is refused (E1714). This is a
deliberate v1 restriction, stricter than the package draft.

## 9. Bundles: The Second Checkout

A bundle is the runnable, verifiable, importable form of a project. It is
produced by `jacquard project bundle -o app.bundle` and published atomically:
built in a sibling temporary directory, then renamed into place.

```text
app.bundle/
  bundle-v1.jqd       -- the root record
  project.jqd         -- the manifest, canonical spelling
  interfaces/         -- interface-v1 manifests: the project's and each dependency's
  contexts/           -- the canonical project-context-v1 record of the project and every transitive dependency
  companions.jqd      -- every call-ABI companion in the closure
  provenance.jqd      -- full-document manifest digest, tool version, build time; NOT part of any identity
  objects/<hash>.jqd  -- objects, serialized from their authoritative stored bytes (§11)
```

**Generated entry declarations.**

- A `run` entry `demo` becomes the term `entry.demo`. That is a valid dotted
  store name; `/` is not a valid bootstrap symbol.
- The entry is an **ordered sequence of independently checked thunks**.
  Each top-level expression becomes its own generated term, `entry.demo.1`,
  `entry.demo.2` and so on, each with its own type. A single list could not
  hold them: `1` followed by `"two"` is an ordinary program, but a list of
  both is a type error.
- The bundle record lists the sequence in order. `project run` evaluates and
  prints each value in order, exactly as `jacquard run` prints every top-level
  value today.
- A `test` entry becomes an ordered list of typed test-root records, each
  holding its kind (`test`, `world-test` or `warp-decl`), display name and
  identity, which is what Warp needs for discovery and reporting.

**`bundle-v1` grammar** (canonical `.jqd`, sorted where marked):

```text
(bundle-v1
  (manifest #<semantic-projection digest>)
  (context #<project-context identity>)
  (prelude <identity form>) (core "<version>")
  (entries (run <name> (steps #<thunk>…) (grants …))…    -- entries sorted by (kind, name); steps in source order
           (test <name> (root <kind> "<display>" #<hash>)… (grants …))…)
  (objects <count>) (companions <count>))
```

The **bundle identity** is `HASH_V0` of this record's canonical bytes; the
head is the domain tag. It contains the **semantic** manifest projection only.
The full-document digest lives in `provenance.jqd`, so editing `metadata`
never changes a bundle's identity.

**Import and run.** `jacquard project run app.bundle ENTRY` builds a fresh
store in temporary space and **publishes it only after verification**. The
checks, in order:

1. budgets: bytes, objects and depth
2. every object's hash and member ownership
3. closure completeness from every root, including test roots
4. **type-checks the whole closure.** Loading an object only validates its
   shape
5. **derives each interface** from the checked objects: signatures, labels,
   and companions restored from `companions.jqd`. Each is compared with
   `interfaces/`.
6. **recomputes every context bottom-up**, from `contexts/`: each dependency
   before its consumers, checking each record's interface and companions
   against what was derived and its dependency edges against its providers'
   verified contexts. The last check is the project's own context against
   `bundle-v1`
7. prelude and Core match the running tool (E1720)

Only then are the objects trusted for identity traversal.

**Bundles as dependencies.** `(dep (as ALIAS) (bundle "path/app.bundle") (pin
#C))` lets new source in another checkout **import and call an exported
callable**, with labels and constructor schemas from the bundle's verified
interface. That is task 217's second-checkout test. It is not merely running
an entry.

**Dynamic code in v1.** A bundle is refused (E1721) if dynamic evaluation is
**executably reachable** from any root: any run step, test root, or exported
callable. Checking the root's outer authority is not enough. A function can
return a closure whose own arrow carries `Eval`
(`() ->{} () ->{Eval} a`), and exported data can contain such functions.

The refusal is therefore a closure scan:

- If any object reachable from a root, excluding pure quoted data, refers to
  the `Eval` operation or the `eval-code` builtin, the bundle is refused.
- Code inside `quote` is data and is not scanned. Live `unquote` splices are
  code and are scanned. Within a checkout, `eval-code` goes through
the project access gate (§5). Pinned dynamic code is deferred.

## 10. Filesystem Policy

- **Units are contained.** After resolving symlinks, every unit path must lie
  inside the project directory (E1722). Units must be regular files (E1723).
  Two units whose canonical paths differ only in case are refused (E1724), so
  behaviour matches on case-insensitive filesystems. So are two unit entries
  that resolve to the same canonical file (E1734).
- **Dependencies may be external.** A `(path …)` may use `..`, but it is
  canonicalized, must contain a `project.jqd`, and is read-only to the
  consumer.
- **No overlap.** Output paths (`-o`, bundles, build and cache roots) must not
  overlap any input unit or dependency directory (E1725).
- File reads reuse the descriptor-based regular-file checks already in
  `src/export.ml`. Bundle traversal refuses symlinks, and partial outputs are
  removed on failure.

## 11. Stores, Caches and Native Builds

- **Store ownership.** The consumer owns all writable state. Each project
  command uses a store under the **consumer's** cache root,
  `<consumer>/.jacquard/`, overridable with `--store` or
  `JACQUARD_PROJECT_STORE`:
  - the root project's store: `.jacquard/store/`
  - each dependency's checking store: `.jacquard/deps/<context identity>/`

  Dependency directories stay read-only (§10), so checking a dependency from a
  read-only checkout works. One writer holds a lock per store, and stores are
  never shared between consumers in v1.
- **Indexes from persisted objects** (prerequisite fix). `put_decl` must
  derive member locations from the **persisted** object bytes, not from the
  incoming declaration. Otherwise a permuted, hash-equal group can index the
  wrong member (§2). PKG.1 fixes this first, with a regression test.
- **The authoritative representation.** Bundles serialize the persisted
  object bytes. They are canonical kernel forms, including binder names that
  hashing erases, and are deterministic for a given store history. Stores are
  built fresh for bundling, so bundle bytes do not depend on unrelated cache
  history.
- **Bounded reads.** Every read of a manifest, unit, object or bundle goes
  through a size-capped, descriptor-based regular-file read. This extends the
  existing `Export` checks with byte ceilings.
- **Semantic metadata.** Companions and visibility are recomputed from pinned
  inputs and never trusted from a cache.
- **Caches.**
  - Warp test caches: `.jacquard/test-cache/`.
  - Native builds run in a **fresh per-build directory**, renamed into
    `.jacquard/build/<entry>/` on success. Concurrent builds of the same
    entry cannot share `prog_main` or object paths.
  - Every root is passed explicitly through the APIs.
  - W1701 warns if `.jacquard/` is tracked by version control.
- **Native reproducibility.** v1 promises **semantic** reproducibility only:
  identical pins give identical checked programs. A build records its recipe
  for diagnosis:
  - Core and emitter
  - runtime digest
  - compiler
  - target
  - flags

  Byte-identical binaries need a complete toolchain and environment contract
  (linker, system libraries, paths) and are out of scope.

## 12. Growth Path

`project-v1` embeds in the package draft without reinterpretation:

| package draft | project-v1 | later |
|---|---|---|
| name, exports | `name`, `exports` | unchanged |
| deps (impl, iface) | `(pin #C)`: the `project-context-v1` identity, covering the exact interface, companions, prelude and dependency pins | a signature-only compatibility projection (§8) |
| hint, intent, index, added | — | tagged `(registry …)` sources beside `(path …)` |
| publisher, signature | — | a signed root over a package manifest that commits to dependencies, companions, tests and migrations, in a new head |
| migrations, `outdated`, `upgrade` | `project pin` with a plan | `add` and `upgrade` with migrations |
| workspaces, dev-only deps, features | — | reserved as named extensions (§3) that v1 tools refuse by name |

## 13. The Four Applications (Acceptance)

These manifests are illustrative; PKG.1 commits the complete ones, and the
cram in §16 checks them against `run.sh` output. All four are hash-preserving
under §4, because constructors are exempt and every other name already
carries its prefix.

| project | namespace | depends on | library units | entries |
|---|---|---|---|---|
| `applications/shared` | `display` | — | `display.jac` | test `display` (`display-tests.jac`) |
| `applications/dice-coach` | `dice` | display | `model.jac` | run `demo`, run `interactive` (both native); test `suite` (`tests.jac`) |
| `applications/picnic-planner` | `picnic` | display | `model.jac` | same shape as dice-coach |
| `applications/rota-optimizer` | `rota` | — | `model.jac`, `fixtures.jac`, `report.jac` | run `demo` and `interactive` (native); test `suite` (`tests.jac`, `interaction-tests.jac`) |
| `applications/formula-notebook` | `nb` | — | `syntax.jac`, `model.jac`, `commands.jac`, `application.jac` | run `demo` (`workbook.jac`, `demo.jac`), run `interactive` (native); test `suite` (`workbook.jac`, `parser-tests.jac`, `model-tests.jac`, `interaction-tests.jac`) |
| `applications/suite` | none (a leaf) | dice, picnic, display | — | test `interaction` (`interaction-tests.jac`, moved here from `shared/`) |

The routine and exhaustive lanes stay as today's Warp flags passed through
`project test`.

**The combined dice and picnic suite.** Today, `run.sh dice-coach test` and
`run.sh picnic-planner test` both run one combined suite: the display tests,
both models' tests, and the shared interaction tests. The wrapper reproduces
it by running four test entries in order:

1. `shared` `display`
2. `dice-coach` `suite`
3. `picnic-planner` `suite`
4. `suite` `interaction`

Coverage is the same, and each test now runs in its owning project.

PKG.1 commits the complete manifests, including exact export lists. The cram
proves hash and output preservation against today's `run.sh`.

A test that needs a private name stays in its owning project's test entry,
or the name becomes an export. Each such choice is recorded in the PKG.1
evidence.

**Migration proofs:**

1. **Identity preservation.** For every entry, project composition yields
   the same declaration hashes as `run.sh` concatenation, compared by a cram.
2. **Behaviour.** `test/cli/applications.t` output is unchanged, including
   native builds. `run.sh` becomes a wrapper over `jacquard project`.
3. **`cat` disappears** from every README and from `run.sh`.
4. **Privacy.** Referencing a non-exported `display.` helper by name, by hash,
   or through `eval` is refused (E1705 or E1709).

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

Project errors use E1700–E1739 and warnings W1700–W1709. Every diagnostic
carries its span, or its list of origins (§6), the project path, and, for
dependency failures, the alias chain. Filesystem and imported-object failures
without a source span report the file path and byte offset. Exit status is 1
for diagnostics and 124 for usage errors.

| code | condition |
|---|---|
| E1700 | malformed manifest form |
| E1701 | unknown manifest field |
| E1702 | duplicate field, entry key, or export selector |
| E1703 | manifest budget exceeded |
| E1704 | `requires` not satisfied by the running Core |
| E1705 | a name is not visible |
| E1706 | a name violates the namespace contract |
| E1707 | namespaces clash or one is a boundary-prefix of another (checked before E1714) |
| E1708 | a depended-on project has no namespace |
| E1709 | an explicit identity is not visible |
| E1710 | a pin does not match |
| E1711 | a dependency is unpinned |
| E1712 | a transitive pin fails |
| E1713 | a dependency cycle |
| E1714 | one namespace appears at two context identities |
| E1715 | an expression in a library unit |
| E1716 | a name is defined twice across units |
| E1717 | an export selector names nothing |
| E1718 | unknown entry |
| E1719 | a call-ABI companion conflicts across the graph, detected before any store mutation |
| E1720 | the bundle's prelude or Core does not match |
| E1721 | a bundle root requires `Eval` |
| E1722 | a unit path escapes the project |
| E1723 | a unit is not a regular file |
| E1724 | two units' paths differ only by case |
| E1725 | an output overlaps an input |
| E1726 | a bundle object's hash does not match |
| E1727 | a bundle object's member ownership does not match |
| E1728 | a bundle closure is incomplete |
| E1729 | a derived interface or context does not match the bundle record |
| E1730 | declared grants differ from checked authority (`--strict-grants`) |
| E1731 | visible constructor names collide |
| E1732 | the library references an entry's name |
| E1733 | a source or manifest file changed during pinning |
| E1734 | two unit entries resolve to the same file |
| W1700 | declared grants differ from checked authority |
| W1701 | `.jacquard/` is tracked by version control |

## 16. Validation For Task 217

**Prerequisite fixes, each with a regression test:**

- `put_decl` indexes member locations from persisted objects (§11)
- quoted-real carrier normalization (§8), or an explicit decision to defer
  it, with the documented behaviour exception
- a composition parse mode, and multi-origin spans (§6)

**Project behaviour:**

- **Refusals.** Every diagnostic in §15 has a negative test with its exact
  text.
- **Fuzzing.** Manifest fuzzing: every input is accepted or refused with a
  code, never with a crash.
- **Determinism:**
  - identical inputs give byte-identical interfaces, context identities and
    bundles
  - reordering `deps` or `exports` changes nothing
  - metadata edits change the document digest, but not the semantic
    projection or context identity
- **Composition equivalence.** A detached signature across two units, and a
  recursive group across two units, behave as their concatenation does, with
  diagnostics naming both files.
- **Pins:**
  - a reachable private edit gives E1710 (interface component)
  - a private label edit gives E1710 (companions component)
  - an interrupted pin leaves the old manifest intact
  - a concurrent source edit during pinning gives E1733
  - unpinned, transitive, cycle, diamond and namespace-clash cases each have
    a test
- **Visibility:**
  - a private name, a private hash, a private hash inside `eval` payloads,
    and a private constructor of an abstract exported type are all refused
  - a provider exporting an abstract type verifies against its export
    projection
- **Fresh checkout.** With an empty `HOME`, a clean clone followed by
  `project test` passes.
- **Bundles:**
  - run an entry from another directory
  - a new project that depends on the bundle imports and calls an exported
    callable using its labels
  - tampered object, mismatched interface, wrong prelude, and an `Eval`
    exported callable are each refused
- **Two-library example.** Two libraries with private `helper`s of
  different bodies, and an application using both. It checks, both helpers
  stay private, and native builds reach the right bodies.
- **The applications** meet §13.

## 17. Decisions Requiring Owner Direction

1. **Scope.** PKG.1 is authorised post-0.2 feature work despite `AGENTS.md`'s
   hardening note (implied by the owner's direction).
2. **Namespaces in v1 are a checked prefix contract with no rewriting.**
   Constructors are exempt and owned by their types (recommended). DES.4's
   automatic prefixing is deferred to a later, explicit local-alias design.
3. **The pin is a `project-context-v1` identity.** It covers the exact
   interface, all companions, the prelude and Core, and dependency pins.
   `interface-v1` is unchanged, and drop-in compatibility classification is
   deferred (recommended).
4. **Bundles refuse any root requiring `Eval`**, including exported callables
   (recommended).
5. **Refuse one namespace at two context identities in v1.** Stricter than
   the package draft; recommended as a deliberate restriction.
6. **The manifest carrier.** `project.jqd`, a bootstrap data value, with a
   non-semantic `metadata` container (recommended).
7. **Quoted-real normalization.** Fix the printed carrier before PKG.1
   (recommended), or ship PKG.1 with the documented behaviour exception.
8. **Track the package drafts.** Should `docs/jacquard-package-cli.md` and
   `docs/jacquard-registry-server.md` become tracked design history?

