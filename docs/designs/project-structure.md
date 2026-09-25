# PKG.0 Local Project Structure

- Status: design for task 217 (PKG.1). Nothing here is implemented. The owner
  decisions are listed in §13.
- Date: 2026-09-24
- Base: `main` with API.1 (`interface-v1`), RF.2 (invocations), and SX.29
  merged.
- Inputs:
  - task 217's acceptance criteria
  - DES.4 §7 (namespaces as a lowering-time prefix)
  - the owner's long-range package draft (`docs/jacquard-package-cli.md`, draft
    0.1). This design is deliberately a strict subset of that draft.

## 1. Question

A Jacquard program larger than one file is assembled today by concatenation.
`demos/applications/run.sh` `cat`s the authored files in a fixed order into a
temporary `.jac`. Two applications share `shared/display.jac` by copying it
into both concatenations. Names are prefixed by hand (`rota.solve`,
`RotaStaff`). Every checked name lands in one mutable `names.jqd` per store, so
nothing is private, and a stray top-level name in one file can collide with
another file.

We need a project format that:

- replaces concatenation with a declared, deterministic composition
- gives multi-file programs and shared libraries real boundaries: exported
  versus private names
- pins dependencies exactly, so a build never resolves anything
- lets a second checkout check and run an exported callable
- has a stable run, test and build workflow independent of the working
  directory
- grows into the package draft (registry, signatures, upgrades) without a
  format migration

It must do all this without touching the kernel, `.jqd`, `HASH_V0`, the store
object format, or the meaning of any existing single-file command.

## 2. Inventory

| piece | today | role in this design |
|---|---|---|
| store | `objects/<hash>.jqd`, immutable and content-addressed; one mutable `names.jqd` of `(named <name> <kind> #h)`, `hidden`, and `call-abi-v1` entries (`src/store.ml`) | objects stay shared and immutable; names become per-project views |
| name resolution | the checker resolves against `Store.names_view`, the whole index | the checker receives a composed, bounded view instead (§5) |
| interface manifests | `interface-v1`: exports with exact identity, name-independent signature, labels, visibility; `jacquard interface emit/verify/diff` (API.1) | a dependency's public surface, and half of its pin |
| naming | D34: PascalCase types and constructors, kebab-case terms. D37: dotted names are one atomic token forever | namespaces reuse the hand-written spelling (§4) |
| application assembly | `run.sh` concatenation per entry point (demo, interactive, test suite, build) | replaced by manifest entries (§6) |
| package draft | `package.jqd`, a content-addressed manifest; impl and interface hashes per dependency; builds never resolve; v0 refuses diamonds | the target this design must embed into (§10) |

## 3. The manifest: `project.jqd`

A project is a directory containing `project.jqd`. The file is a data value in
the permanent bootstrap carrier. It is never code: it is read with the existing
reader and validated by a strict schema, and it is never evaluated.

```text
(project-v1
  (name "rota-optimizer")
  (namespace rota)
  (units "model.jac" "fixtures.jac" "report.jac")
  (exports rota.solve rota.render-report RotaProblem RotaSolution RotaStatus)
  (deps
    (dep (as display) (path "../shared")
         (interface #9c07…) (implementation #3f2a…)))
  (entries
    (run demo (units "demo.jac") (grants console))
    (run interactive (units "interactive.jac") (grants console))
    (test suite (units "tests.jac" "interaction-tests.jac"))
    (build demo)))
```

| field | meaning | rules |
|---|---|---|
| `name` | a display name | not identity, not resolution; text |
| `namespace` | the name prefix for everything the library units declare (§4) | a kebab-case identifier, or omitted for no prefix |
| `units` | library source units, in elaboration order | relative `.jac` or `.jqd` paths; order is semantic, exactly as concatenation order is today |
| `exports` | the public surface, by store name | every name must exist after elaboration; the only names a dependent can see |
| `deps` | direct dependencies | each has a local alias, a local path, and both pins (§7) |
| `entries` | named entry points | `run`, `test` and `build`; each adds entry-only units (§6) |

Strictness follows the host protocol's rule:

- unknown fields, duplicate fields and duplicate entry names are refused
- an unknown head (`project-v2`) is refused by a v1 reader
- no unknown field is ever ignored

Field order inside `project-v1` is free, but a canonical printer normalizes it,
so `jacquard project fmt` gives one spelling. Sizes are bounded: at most 256
units, 64 dependencies, 64 entries, and 1024 exports. Paths are relative,
UTF-8, never absolute, and never URLs.

**Why a bootstrap data file** rather than TOML, JSON or `.jac`:

- the reader and canonical printer already exist
- the package draft already chose a Jacquard value (`package.jqd`)
- a data-only head carries no evaluation risk
- a strict schema over forms is what the host protocol already does for JSON

## 4. Namespaces

The design keeps DES.4's decision: **a namespace is a lowering-time name
prefix, never a kernel or identity concept.** Two refinements make it
implementable and migratable.

1. **Declared in the manifest, not in source.** Source files stay unchanged
   and remain valid single-file programs. `jacquard run model.jac` means what
   it means today. A unit's meaning depends on its project only through the
   prefix and the visible names (§5), and both are shown in every diagnostic.
2. **Optional.** A project without `namespace` binds names exactly as written.
   That is the migration path: the four applications already spell their
   prefixes by hand (`rota.solve`, `RotaStaff`). As an unprefixed project they
   produce *byte-identical identities* to today's concatenation, which is the
   first migration proof (§11). Dropping the hand prefixes is a second, optional
   step.

With `namespace rota`:

- A kebab-case top-level name `solve` binds as `rota.solve` (D37: one atomic
  token).
- A PascalCase name `Staff` binds as `RotaStaff`, with the namespace folded in
  as PascalCase. This covers types, constructors and effects. D34 forbids
  `rota.Staff`, since a lowercase dotted head is a term.
- Generated accessors and setters derive from the folded type name
  (`rota-staff.id`).
- A name that is already prefixed (`rota.solve`, `RotaStaff`) is refused as
  double-prefixed (E1706), not silently doubled.
- Inside the project's own units, the unprefixed spelling and the full
  spelling both resolve to the same binding. Unprefixed resolution is local
  only (§5).

Identities are unaffected: `HASH_V0` hashes declarations, not names. Renaming
through a namespace changes `names.jqd` and interface names, never object
hashes.

## 5. Resolution and privacy

This is the part concatenation cannot give and prefixes alone do not give. A
prefix is a naming convention; privacy needs a boundary.

The checker for a project unit sees a **composed, read-only name view**, built
fresh for each check, never from an ambient store index. From highest priority
to lowest:

1. **Local.** The names the project's own units have bound so far, in unit
   order. Unprefixed and namespaced spellings are both accepted.
2. **Dependencies.** For each dependency, only the names in its `exports`, as
   recorded in its pinned `interface-v1` manifest, under their full
   (namespaced) spellings.
3. **Prelude.** The prelude of the pinned prelude identity.

The rules:

- **Resolution is total and deterministic.** A name either resolves to exactly
  one entry or fails.
- **Two dependencies exporting the same full name is an error** (E1703),
  naming both dependencies. Because full names carry namespaces, this only
  happens when two dependencies share a namespace, so it is caught when the
  manifest is validated.
- **A local name never silently shadows an export.** If a local top-level name
  equals the full spelling of a dependency export, that is E1704. With
  namespaces this cannot happen by accident.
- **A reference to a dependency's non-exported name** fails with E1705,
  "`display.pad-to` is private to project `display`; export it or use an
  exported function". It does not fall through to a global lookup, because
  there is none.
- **Privacy is by construction, not by convention.** A dependency's private
  declarations are present as objects, because exported closures reach them,
  but they are unnamed in the view. They cannot be referenced by name, and by
  hash only as today's `hidden` members allow, which v1 refuses in project
  units (E1705).
- The prelude view is the pinned prelude's public index. A project that binds
  a name the prelude also binds behaves exactly as a single file does today.
  The local binding wins within the project and is reported by
  `jacquard project check`, so the override is visible.

The mechanism is small, because the checker already takes a `Resolve.names`
value (`Store.names_view`). The project driver builds that value from
interfaces and local bindings instead of from `names.jqd`.

## 6. Entries, grants, and the CLI

An entry is the library units plus the entry's own units, elaborated in that
order, followed by the entry units' top-level expressions. This is exactly
what `run.sh` concatenates today. There are three kinds:

| kind | behaviour |
|---|---|
| `run NAME` | evaluates the top-level expressions |
| `test NAME` | runs the Warp suite declared by the entry's units |
| `build NAME` | compiles the named `run` entry natively |

Entry units are private to the entry: they can see library names, and nothing
can see them.

**Grants are declared, never granted.** `(grants console)` records what an
entry is expected to need.

- `jacquard project check` compares that declaration with the checked
  authority manifest (the entry's closed effect row). A missing or extra grant
  is a warning with the exact difference.
- `jacquard project run` still requires `--allow` on the command line, exactly
  like `jacquard run`. A manifest can never grant authority. This matches the
  package draft ("documented expectation, not authority") and the authority
  design.

The CLI is a new group. Existing commands do not change.

```text
jacquard project check    [DIR]              # validate manifest, pins, and every entry
jacquard project run      [DIR] ENTRY [--allow ...]
jacquard project test     [DIR] [ENTRY]
jacquard project build    [DIR] ENTRY -o OUT
jacquard project pin      [DIR]              # (re)compute dependency pins; the only command that writes them
jacquard project interface [DIR]             # the project's interface-v1 manifest
jacquard project bundle   [DIR] -o BUNDLE    # §8
jacquard project fmt      [DIR]              # canonical manifest spelling
```

`DIR` defaults to the nearest ancestor containing `project.jqd`, found by
searching upward from the working directory, and is printed in every
diagnostic header. All paths inside the manifest are relative to the manifest,
never to the working directory.

## 7. Dependencies and pins

A dependency is `(dep (as ALIAS) (path P) (interface #I) (implementation
#M))`.

- **`interface #I`** is the dependency's `interface-v1` identity: its exported
  names, their exact identities, signatures and labels.
- **`implementation #M`** is `project-implementation-v1`: the hash of the
  sorted list of declaration hashes in the closure of the dependency's
  exports, plus the prelude identity it was checked against. It is semantic:
  reformatting or renaming a private binder does not change it. Any change to
  behaviour does.

**Builds never resolve.** `check`, `run`, `test` and `build` recompute both
hashes from the dependency's source and compare them with the pins:

| outcome | result |
|---|---|
| both equal | proceed |
| interface equal, implementation changed | E1710 "implementation changed; the interface is compatible", with `interface diff` = identical and a hint to rerun `jacquard project pin` |
| interface changed | E1711 with the `interface diff` classification (compatible or breaking) and the exact changed exports |
| the dependency's own pins fail | E1712, reported through the path of aliases |

Only `jacquard project pin` writes pins, so changing what a build means is
always a visible, reviewable manifest edit.

Why both hashes: an interface-only pin is not reproducible, because the
implementation could change under it. An implementation-only pin cannot say
"drop-in compatible". The package draft pins both for the same reason.

- **Cycles** among projects are refused (E1713), with the cycle printed.
- **Diamonds.** When two paths reach one dependency directory, the pins must be
  identical, or the project is refused (E1714). This is the package draft's v0
  "refuse diamonds with differing versions". Because paths are local, a
  diamond is always the same directory, so this only fires when pins are
  stale.

## 8. Bundles: the second checkout

`jacquard project bundle -o app.bundle` writes a directory, deterministic
byte for byte:

```text
app.bundle/
  bundle-v1.jqd        -- (bundle-v1 (project <manifest-hash>) (interface #I) (implementation #M)
                       --             (prelude <identity>) (entries ...) (objects <count>))
  project.jqd          -- the manifest, canonical spelling
  interface.jqd        -- the project's interface-v1 manifest
  objects/<hash>.jqd   -- the complete object closure of every export and entry
```

`jacquard project run app.bundle ENTRY` checks the bundle before doing anything:

- It verifies every object's hash.
- It verifies that the prelude identity matches the running Core, refusing with
  the two identities otherwise (E1720).
- It verifies that the recomputed interface and implementation hashes match
  `bundle-v1.jqd`.

It then runs the entry in a fresh temporary store. Task 217's "a second
checkout can check and run an exported callable" is the bundle round-trip
test. Source is not required to run a bundle. Source is required to rebuild
it.

## 9. Store and artifact locations

- The project store is `<project>/.jacquard/store/` by default, and
  `--store DIR` or `JACQUARD_PROJECT_STORE` overrides it. It holds objects plus
  a derived names index, which is a cache that the driver rebuilds when it is
  stale. The names view used for checking is always recomputed (§5), so a stale
  or corrupt index can cost time but never change resolution.
- Build artifacts go to `<project>/.jacquard/build/`, and `-o` overrides it.
- Neither location depends on the working directory. `.jacquard/` belongs in
  `.gitignore`, and `jacquard project check` warns if it is tracked.
- Objects are immutable and content-addressed, so sharing an object directory
  between projects is always safe. A global object cache is a later
  optimization with no format change.

## 10. Compatibility and growth

- **Unchanged:** the kernel, `.jqd`, `HASH_V0`, the object format, `names.jqd`
  syntax, `interface-v1`, and every existing command. Single-file programs
  never need a manifest.
- **Growth into the package draft.** `project-v1` is a strict subset of the
  draft's `package.jqd`:

  | draft field | here |
  |---|---|
  | `name`, `exports` | the same |
  | `deps` impl and iface | `implementation` and `interface` |
  | `hint`, `intent`, `index`, `added`, `publisher`, `signature` | not yet |

  A registry release adds those fields in `project-v2` (or `package-v1`). The
  v1 reader refuses them rather than ignoring them, so no v1 build can
  misread a later manifest. A `(path …)` dependency later gains a sibling
  `(registry …)` source with the same pin fields, and `project pin` becomes
  `add`/`upgrade` with migrations (draft §6).
- **Diagnostics:** E1700–E1729 are reserved for projects.

## 11. The Four Applications (acceptance)

`shared/` becomes a library project, and each application becomes a project
that depends on it where needed:

```text
demos/applications/shared/project.jqd       (namespace display) units display.jac; exports display.*
demos/applications/dice-coach/project.jqd   deps display; entries demo, interactive; test suite
demos/applications/picnic-planner/project.jqd
demos/applications/rota-optimizer/project.jqd
demos/applications/formula-notebook/project.jqd
```

The shared dice-and-picnic suite, which today concatenates both models, becomes
a small `applications/suite/` project depending on both.

Migration proofs:

1. **Identity preservation.** Each project, with no namespace and hand
   prefixes kept, yields the same declaration hashes as today's `run.sh`
   concatenation. A cram compares `jacquard hash` output from both paths.
2. **Behavioural parity.** `run.sh` becomes a thin wrapper over
   `jacquard project run/test/build`. `test/cli/applications.t` output is
   unchanged, including native builds.
3. **`cat` disappears** from every README and from `run.sh`.
4. **Privacy.** A deliberate reference to a non-exported `display.` helper
   from an application fails with E1705. This is pinned as a negative cram.

## 12. Validation And Hardening

For task 217, beyond §11:

- **Strict parsing.** Every refusal in §3, §5 and §7 has a negative test with
  its exact diagnostic.
- **Manifest fuzzing.** Fuzz `project.jqd` with random forms, oversized lists,
  duplicated fields and path forms. Every input is accepted or refused with a
  code, never with a crash.
- **Determinism:**
  - identical inputs give byte-identical interface, implementation and bundle
    output
  - reordering the `deps` list or the `exports` list changes nothing
  - reordering `units` changes only what top-level order can change
- **Pin lifecycle:**
  - a private edit in a dependency gives E1710
  - an exported signature change gives E1711 with the `interface diff` class
  - a stale transitive pin gives E1712
  - a cycle gives E1713, and a diamond with differing pins gives E1714
- **Fresh checkout.** A clean clone plus `jacquard project test` passes, with
  no global store touched (`HOME` pointed at an empty directory).
- **Bundle round-trip.** Build a bundle and run it from another directory in a
  fresh temporary store. A bundle with one tampered object is refused, and so
  is a bundle whose prelude identity differs (E1720).
- **Two-library example** (task 217): two libraries whose private names
  collide (both define `helper`) and an application using both. It checks, and
  both helpers stay private.

## 13. Decisions Requiring Owner Direction

1. **Manifest carrier:** a bootstrap data file `project.jqd` (recommended),
   rather than TOML or JSON.
2. **Namespace declared in the manifest, not in source** (§4, recommended).
   DES.4 sketched a source-level `namespace rota` declaration. Moving it to the
   manifest avoids a new keyword and keeps every file a valid standalone
   program.
3. **The `Staff` → `RotaStaff` folding for PascalCase names** (§4, from DES.4).
   The alternative is to keep PascalCase names unprefixed and rely on privacy.
   That reads better, but type names would collide across libraries.
4. **Pin both interface and implementation** (§7, recommended). This is
   stricter than DES.4's interface-only sketch.
5. **Grants declared, never granted** (§6, recommended).
6. **Refuse diamonds with differing pins in v1** (§7, as in the package draft).
7. **Commit the package and registry drafts.** `docs/jacquard-package-cli.md`
   and `docs/jacquard-registry-server.md` are untracked in the owner's
   checkout, and this design cites the first. The owner decides whether they
   become tracked design history.
