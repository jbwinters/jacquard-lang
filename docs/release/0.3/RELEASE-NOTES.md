# Jacquard Core 0.3.0

Jacquard 0.3.0 integrates everything reviewed since 0.2.0: local projects,
portable interface identities, a frozen host protocol, new surface forms,
scoped effect instances, computation fuel, typed inference outcomes,
observation policies, and opaque types. Read [the bounded claims](CLAIMS.md)
and [full limits](LIMITS.md) before relying on a feature claim, and the
upgrade notes below before moving a 0.2 program or store.

Highlights:

- **Local projects:** a `project.jqd` manifest with a namespace, units,
  exports and entries; `jacquard project check|run|test|build|hash|pin|bundle`;
  path and bundle dependencies with per-project visibility and
  context-identity pins; verifiable bundles; native project builds.
- **Interface identities:** `interface-v1` manifests with
  `jacquard interface emit|verify|diff`, classifying a change as compatible or
  breaking.
- **Host protocol v0:** a frozen, language-neutral protocol with bounded
  codecs, invoke preflight and session accounting, the opt-in
  `jacquard host worker`, and an executable conformance kit.
- **Surface language:** named call arguments, labeled partial constructor
  patterns, generated field accessors and setters, `Ctor(value with label: e)`
  field updates, `try` Result propagation, list predicates, and numeric and
  character helpers; a more robust formatter.
- **Effects:** checked effect payloads, and scoped effect instances for State,
  Throw and Emit on both engines.
- **Computation fuel:** deterministic `fuel-v1` budgets with `--fuel` on `run`,
  `infer`, `test` and the host worker.
- **Inference:** typed `dist.enumerate-v1` and `dist.sample-lw-v1` outcomes,
  `--max-branches` and `--metadata`.
- **Observation:** a typed observation boundary, `observation-policy-v1`
  policies, and `jacquard relate --policy`.
- **Opaque types:** `opaque type` seals a type's constructors to its owning
  project, so a library can enforce an invariant; values print as
  `<opaque name>` on both engines. `demos/abstract-types` shows three such
  libraries and a client.
- **Everyday applications:** four demo applications kept as projects, with
  end-of-input-aware console input and more native Text primitives.

Install the final release:

```sh
curl -fsSL https://raw.githubusercontent.com/jbwinters/jacquard-lang/jacquard-core-0.3.0/scripts/install.sh | sh
export PATH="$HOME/.local/bin:$PATH"
jac --version
jac run "$HOME/.local/share/jacquard/demos/basics/m1-fact.jac"
```

For RC verification before final promotion:

```sh
curl -fsSL https://raw.githubusercontent.com/jbwinters/jacquard-lang/jacquard-core-0.3.0-rc1/scripts/install.sh \
  | JACQUARD_INSTALL_VERSION=jacquard-core-0.3.0-rc1 sh
```

## Upgrade Notes

Moving from 0.2.0, these programs or artifacts behave differently:

- **`try` and `with` are reserved.** A bare `try` or `with` used as a name,
  parameter, binder or field label no longer parses. Rename it; a name may also
  be written with the `` `term:with` `` escape. Names such as `with-x` and
  `try-parse` are unaffected, and `.jqd` files are unaffected.
- **Generated accessors and setters.** A field label that every constructor of
  a type carries now generates the accessor `<type-kebab>.<label>` and the
  setter `<type-kebab>.with-<label>` (`Pair(left: …)` gives `pair.left` and
  `pair.with-left`), provided the generated name is a valid symbol (an escaped
  type name ending in `?` or `!` generates neither). Opaque types get no
  setters, and a label only some constructors carry generates neither. If a
  file also defines one of those names by hand, or declares an effect operation
  with that name, it is refused (E1241); delete or rename the explicit
  definition. A generated name shadows a same-named prelude or store term, as a
  hand-written one would, and `jacquard hash` lists the generated identities
  after each labeled type. Fields whose generated names would collide, such as
  `x` and `with-x`, are refused the same way (E1241); rename one of the labels.
  Labels are also checked where a type is declared: a label repeated within one
  constructor (E1239), or given different field types in different constructors
  (E1240), is refused; rename or retype it.
- **Checked effect payloads.** Handlers and programs that mixed payload types
  in one effect region, handled only some operations of an effect whose
  operations share a payload type, stored effectful or open-row callbacks in
  nominal fields whose declared type erases their payload constraints, or
  resumed an operation-polymorphic result with a concrete value are now refused
  (E0801); a type parameter that carries the whole callback type is accepted.
  Every type variable in a nominal field must also appear in the type's header,
  and fields with an explicit `forall` are refused.
  `docs/effect-payload-containment.md` lists each migration.
- **Prelude names keep their meaning.** `if`, list literals and `try` bind the
  prelude's constructors by identity, and builtins use the prelude's frozen
  identities, so a file that declares its own `True`, `Cons` or a governance
  name no longer changes what those forms or builtins mean.
- **Inference edge cases.** A posterior whose surviving path or run weights are
  NaN, infinite or negative, or whose total is not finite, is now refused
  (E0917) rather than printed as a misleading table; individual categorical
  support weights are not validated beyond that. An enumeration in which every
  path underflows is reported as E0917 instead of E0901. `infer enumerate` now
  lists paths that underflow alongside surviving ones with probability 0, where
  0.2 omitted them; `infer lw` drops impossible runs, where 0.2 listed them
  with probability 0; an `infer lw` run that draws only from zero-mass
  categoricals is refused (E0901) instead of printing a posterior; and `infer
  lw` with a non-positive `--samples` is a usage error.
  `docs/release/inference-outcomes/DECISION.md` has the full table. The
  `dist-diff` posterior cache moved to a versioned key, so existing cache
  entries are ignored.
- **Real literals evaluate as their canonical identity.** The literal `-0.0`
  now denotes `+0.0`, as its hash always did, so `1.0 / -0.0` is positive
  infinity on both engines, and every NaN literal is the one canonical NaN.
  Reals computed at run time keep their sign.
- **Stores.** 0.3 opens a 0.2 store and records its prelude, byte for byte:
  reopening that store with a prelude whose `.jqd` source files differ in any
  byte, including a later Core's prelude, is then refused (E0705), so keep the
  prelude the store was opened with, or create a new store and re-add your
  definitions. A definition in that store whose name the 0.3 prelude now
  defines (for example `bool.all`) then resolves to the prelude's; rename such
  definitions first. Treat the upgrade as one-way and keep a copy: in testing,
  a 0.2 store that 0.3 had run against no longer resolved prelude names under
  0.2; a store holding `call-abi-v1` label companions is refused by the 0.2
  reader; and a store holding an opaque declaration cannot be opened by older
  tools at all. Older readers also refuse `bundle-v2` bundles (E1720 or E1735)
  and observation transcripts that use the new `opaque` or `capability` kinds.
- **`store add` and stored groups.** `store add` now chooses the parser by file
  extension, so a bootstrap file named `*.jac` must be renamed to `.jqd` or
  added with `--syntax jqd`; a refused `store add` leaves the store unchanged.
  Reinstalling a recursive group whose members are hash-identical but listed in
  another order now resolves each member to its own persisted body, correcting
  results 0.2 could get wrong, and a damaged stored object is refused (E0603).
- **Pins and bundles are Core-version-bound.** Projects are new in 0.3, but
  context pins and bundles record the Core version, so any made by a build
  reporting another Core version (including unreleased builds after 0.2.0,
  which report `0.2.0`) are refused: E1710 for a direct dependency's pin, E1712
  for a transitive one, and E1720 for a bundle. Re-pin with `jacquard project
  pin` and rebuild bundles with `jacquard project bundle`. A manifest's
  `(requires (core "0.2"))` is still satisfied by 0.3.0.
- **Diagnostics.** No code was renumbered. `fmt` now exits 1 (E1204) rather
  than printing output that would not parse, drop a comment, or change on a
  second pass; `check` reports fewer cascading errors; W1203 is judged by a
  match scrutinee's shape.
- **Host conformance kit.** The kit's `core_version` is now `0.3.0`, so
  `spec/host-protocol-v0/kit/kit.json` has a new SHA-256 (`a01b9401…`, recorded
  in `EVIDENCE.md`); an adapter that pinned the kit re-pins it. The protocol,
  carrier and transcripts are unchanged.
- **Native runtime.** Hand-written C that initializes `jq_con_info` must set
  its new `type_name` and `opaque` fields for an opaque constructor.

Unchanged: no command or flag was removed; there is no default fuel budget or
branch limit; `HASH_V0`, the 27-form kernel, run transcripts, schedule traces
and host envelopes keep their formats; and existing hashes do not change,
except for a file whose own constructors previously captured `if` or list
literals (see Prelude names above).
`docs/release/abstract-types/DECISION.md` has the opaque-type details.

Jacquard remains a research prototype. Language grants are not an OS sandbox;
structured concurrency, Channels, fuel and the host worker are
interpreter-only; probability is finite and discrete; Workspace governance is
not a production authorization system; the public `.jac` projection remains
evolving v0 syntax; local projects are not a package manager; and no human
readability result is claimed.
