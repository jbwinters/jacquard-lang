# TYPE.0 Abstract Types and Checked Construction Boundaries

- Status: design for TYPE.1 (not yet implemented), revised after twelve rounds of independent review.
- Owner decisions recorded 2026-10-03:
  - an `opaque type` marker;
  - re-declaration refused for all types and effects;
  - `eval` refuses sealed constructors everywhere;
  - opaque values print as `<opaque name>` (typed observations as `<opaque>`).
- Base: `main` after PKG.1 (project manifests, abstract exports) and API.1
  (interface identities).

## 1. Problem

A library enforces a domain invariant by hiding a type's constructors and
exporting only validated functions. Examples: a probability lies in [0, 1], a
list is non-empty, a request was validated.

PKG.1 already supports this at the project level:

- **Abstract export.** A manifest that exports `(type X)` without `(con C)`
  hides the constructor.
- **Refusals.** Using the hidden name is E1705, and an explicit or derived
  identity is E1709.
- **Interface.** `interface-v1` records hidden members.

That protection is name-level and depends on session ownership bookkeeping.
Reading the code establishes these routes:

1. **Root re-declaration (demonstrated).** A root project without a namespace
   can re-declare a dependency's type byte for byte. Identities are content
   addresses, so the copy is the same type. Installing it as library code makes
   the root a co-owner, entitled to construct and match. A re-declaration
   inside an *entry* is already refused (E1709): entries never become owners.
2. **Host ingress (demonstrated).** Host protocol v0 decodes a constructor value
   for any constructor the store can locate. Its type preflight walks type
   arguments and tuples but not the fields of nominal declarations, and its
   value encoder serializes every constructor value.
3. **Unchecked evaluation (demonstrated).** Single-file `eval-code` resolves
   against the public name view. Code values can carry an explicit
   `(ref #h con)` built from a known hash.
4. **Bundles (confirmed by code reading).** A bundle's interface is checked only
   for self-consistency, not for whether an exported declaration belongs to the
   bundle's own context. Importing a bundle makes it an owner of every object it
   carries. So a bundle can export a dependency's hidden constructor. Beyond
   exports, a bundle can carry a hash-valid term whose body constructs a
   dependency's sealed value: stored-term checking trusts store references.
5. **Generated setters (demonstrated).** `<type>.with-<label>` rebuilds the
   constructor, so exporting one bypasses validation.

## 2. Decision: opaque types

### 2.1 The marker

`opaque type ProbValue = ProbValue(value: Real)` in a project with namespace `prob` declares an **opaque type** named `prob-value`.

- `opaque` is a contextual keyword, valid only before `type` at the top level,
  so existing identifiers named `opaque` keep working.
- The kernel form is `(deftype prob-value () (opaque) (con …))`: the
  `(opaque)` marker sits after the type parameters and before the constructor
  specifications.
- Older tools read the marker as a malformed constructor specification and
  refuse the declaration, so they fail closed. A bundle carrying an opaque
  declaration is refused by an older reader before it parses objects, through
  the Core version check (E1720) or the bundle format check (E1735).
  An older tool loads every object when it opens a store, so it cannot open a
  persistent store that holds an opaque declaration at all, not only that
  declaration. Release notes must say so.
- An opaque type's constructors are **sealed**.
- Every place that matches on a type declaration gains the flag: the canonical
  form, the interface, the host protocol, the project frontend, the checker,
  resolution and surface lowering.

### 2.2 Opacity is identity

Opacity is part of the type's canonical identity.

- A transparent declaration keeps declaration tag `0x41` and its exact bytes, so
  **no existing hash changes**, including every prelude declaration.
- An opaque declaration uses tag `0x47` with the same payload layout.
- `spec/serialization.md` records the new tag.

Consequences:

- Making a type opaque, or transparent again, changes the identity of the type,
  its constructors (their identities derive from the declaration hash), its
  accessors, and every term that mentions the type.
- A malformed store or bundle cannot drop opacity without breaking every pin
  that names it.

### 2.3 Ownership and the defining scope

**Types and effects are owned by namespace.** The rule is order-independent.

- A namespaced project must name its types and effects with its namespace
  prefix. Type and effect names are part of their hashed declarations, and
  constructors and operations derive from those declarations. So a sealed
  type, and its constructors, belong to the graph project whose namespace
  prefixes the type's name.
- Prelude identities are looked up first and are owned by no project, so a
  project namespace that happens to prefix a prelude name (for example `task`
  or `governance`) never claims a prelude type.
- The owner of a sealed type is the unique namespace that prefixes its name.
  The existing prefix-overlap refusal (E1707) and the same-namespace refusal
  (E1714) apply to the union of every graph node's namespace and every
  namespace a bundle records, after equivalent contexts are deduplicated. So
  `a` and `a-b` can never both claim `a-b-secret`, and a carried context cannot
  be relabelled to claim another's types.
- A type declared by a root project without a namespace belongs to that root.
- Two copies of the same project (verified equal context identity) are the
  same owner. Equivalent artifacts are deduplicated before any ownership rule
  applies.

**Terms carried by bundles are scoped by region.** A term's hash carries no
namespace, since binding names are only a tie-break, so a term's owner cannot
be read from its content.

- **A context's region** is the `decl_refs` closure of its own roots. The roots
  are its exported terms and, for a bundle, the entry roots it records.
  Traversal always enters the context's own roots, even when another context
  also exports the same hash. Below its roots, it stops at hashes exported by
  the other contexts in this bundle's recorded graph and at prelude objects, so
  a dependency's internals are never part of its consumer's region. Two
  contexts that both export one constructing term therefore both contain it,
  and the term is refused unless both belong to the owner.
- **Builtins use frozen identities.** Several builtins resolve names through
  the store's mutable names at call time, to build prelude values (`true`,
  `false`, `cons`, `nil`, `some`, `none`, `ok`, `err`, `less`, `equal`,
  `greater`, `mk-pair`, `mk-response`, the risk and assessment constructors),
  to recognise them, or to call prelude terms (`governance.validate-*`,
  `governance.assessment-*`). They do this in the interpreter (`infer_dist`,
  `warp`, `prelude`, `posterior_risk` and `bin/main.ml`) and in native wiring
  (`src/native/build.ml`). A namespace-less root or a single file could rebind
  such a name to its own sealed constructor or to a private constructing
  helper, and a dependency calling `support` or a posterior builtin would then
  build the consumer's sealed value without referencing it. TYPE.1 makes every
  builtin construct, recognise, call, register and type frozen prelude
  identities, never names resolved at run time, in every mode. That includes
  native wiring and trusted builtin signatures (`Prelude.wire_builtins`,
  `base_builtin_signatures`, `posterior_builtin_signatures`), on which the
  posterior builtins' pure signatures rest, and operation recognition such as
  `sample` and `observe` in `infer_dist`. Name-only `VCon` pattern matches
  inside builtins may stay, because typed boundaries fix the matched value's
  type. Sugar already does this for six names
  (`sugar_identity.ml`); TYPE.1 adds the rest.
- **Dynamic term references.** The posterior builtins (`posterior_risk`'s
  exact and sampling paths) run a model term named by a hash carried in a
  runtime value, with a pure signature and no `eval` grant, so they bypass
  E1709 and the region walk. In project and bundle runs, such a model
  reference must name a prelude term or a term exported by a context in the
  run's graph; any other hash is refused (E1709) before it runs. The guard applies to the whole run and does not know which project's code holds the reference, so the root's own unexported models are refused too: export a model to pass it by hash. Single-file
  runs keep today's behaviour, under the same bound as `eval-code`. No other
  builtin runs a term from a runtime hash; S2 adds a test that enumerates every
  runtime hash executor, the host worker included.
- **Host invocation is trusted.** The host worker runs the callable a host
  request names by hash, checking only that it is stored, not E1709 or
  regions. A host can therefore call a library's unexported helper whose
  signature avoids opaque types but which builds a sealed value internally.
  The host process has the root's trust; E1604 protects only the opaque types
  that cross the boundary.
- **Owners and entry types.** The owner of a sealed type is the context whose
  namespace prefixes its name; an unprefixed type belongs to the bundle's own
  root, since a namespaced library cannot declare one (E1706) but entry units
  may.
- **Namespaces in regions.** What a context's exports reach must carry its
  namespace (E1739), except through type positions. The whole region, entries
  included, must not reach a type or effect inside another context's namespace
  through a live reference (E1739), so a forged entry cannot use a dependency's
  unexported types and effects.
- **Every constructing term needs a region.** A carried term that references a
  sealed constructor but lies in no region is refused (E1738). Today the
  exact-closure check refuses any unreachable object first (E1728), so E1738
  here is defence in depth.
- **Granularity.** The stop test applies to the exact referenced identity, a
  group member or constructor hash, before it is looked up. A reference to a
  private member of a group whose other member is exported is not stopped.
  Region membership is then recorded per declaration.
- **Entry roots are author-trusted.** Entries are not part of the pinned context
  identity, so including a bundle's entry roots in its region trusts the bundle
  author. They serve only the author's own runs; consumers cannot run a
  dependency's entries and still meet E1709 on anything entries reach.
- **Self-contained bundles.** A bundle's completeness check resolves every
  reference to the bundle's own objects or to prelude objects, never to
  objects already in the session store. Verification receives the session's
  prelude object set for this membership test. So a later bundle cannot borrow an
  earlier bundle's hidden helpers, and regions do not depend on import order.
- **The rule (E1738).** A term carried by a bundle that references a sealed
  constructor is admitted only if every region containing it belongs to that
  type's owning context. A reference is any hash in the term's live references (`decl_refs`, built
  from `expr_refs`, `pat_refs` and `quoted_refs`, which yields only live splices) that locates to a sealed constructor,
  whatever its syntactic kind. That covers an application, an unapplied
  constructor value returned for a caller to apply, a constructor pattern and
  a live splice, and it excludes quoted data. Region traversal, E1738 and the
  `eval-code` refusal share this one definition. Traversal is transitive, so any path from a hostile
  root to a sealed constructor pulls the constructing term into the hostile
  region, where it is refused. Shared helpers that touch nothing sealed are
  exempt, even when two contexts share one by identity.
- **What the rule stops.** A dependency cannot construct its consumer's sealed
  type. A hostile term cannot reach a library's unexported raw helper by hash:
  that helper lies in the library's region, and the hostile term does not.
- **What it allows.** A library's own private helpers and entry-only test
  helpers lie in its own region and are accepted.
- **When it is computed.** Regions are computed per context when a bundle is
  imported, before its consumers are composed.
- **Source projects** are not subject to E1738. Their units are checked from
  source by the name and identity refusals (E1705, E1709) and the owners table.
  The session store also holds imported bundle objects, including a
  dependency's private constructing helpers, but E1709 refuses any explicit
  hash the consumer may not reference, so source cannot reach them. Each
  project session opens a fresh store, so no unowned leftovers from earlier
  imports exist; the exemption depends on that and must be revisited if
  sessions ever reuse a persistent store.

**The defining scope** of a sealed type is its owning project's library and
that project's own entries, so its tests can construct and match.

**Single files.** The scope is the declarations that this run's source
declares, whether or not the store already held them, so re-running the same
source stays in scope.

- A sealed constructor that this run did not install is refused where it is
  used: when resolving a name or an explicit hash in source.
- Store admission never refuses stored objects, so a later run can still open
  the store and use an earlier run's validated functions.
- Single-file sealing therefore protects only within one run and against
  `eval-code`. Nothing protects against someone who copies the source or
  re-declares the type in a later file.
- **A persistent store is trusted content.** A later run can call any stored
  term by name or hash, so the guarantee does not extend to a store that
  untrusted parties can write.
- **Bundle import is transactional.** Verification and the E1739 and E1738
  checks run inside a store transaction, and a refused import aborts the
  session, discarding its in-memory state. A refused bundle leaves none of its
  objects behind.

Outside the defining scope, the existing refusals apply to a sealed
constructor: E1705 for its name and E1709 for an explicit or derived identity.

### 2.4 Closing each route

| Route | Rule |
|---|---|
| Re-declaration (E1737) | A project may not declare a type or effect inside another project's namespace, taken from the same union as E1707 and E1714: every graph node's namespace and every namespace a bundle records for a carried context. Only a root without a namespace can attempt it, and the rule refuses it there whatever the installation order. The only exemption is an equivalent context: a second copy of a project with a verified equal context identity is the same owner. A declaration whose bytes equal another project's declaration is still a re-declaration. Prelude identities, owned by no project, stay allowed. The rule applies to all types and effects. |
| Constructor export (E1736) | A manifest `(con C)` naming a sealed constructor is refused. Bundle verification also refuses a recorded export of a sealed constructor, and derived interfaces never contain one. |
| Interface projections | Every checked unit has two projections: an **internal** one for its owner's own checking, and a **public** one for interface emission and `diff`. The public projection omits sealed constructors automatically, so an ordinary single-file program with an opaque type still checks. Refusal is reserved for an explicit export attempt (E1736). |
| Bundles (E1739, E1738) | A bundle records the namespace of each context it carries, and its verification checks each one (E1739). The check is kind-aware, matching the source rules: the recorded namespace must prefix every exported term (as `ns.name`, or `ns-Type.label` for a term named after a type), type and effect name, and every type or effect name its exports reach; no part of a context's region, entries included, may reach a type or effect inside another context's namespace through a live reference. A constructor or operation is validated through its owning declaration's namespace, so an ordinary exported constructor such as `Some` is not refused. A type or effect declaration reached only through type positions (annotations, field types, effect rows, and transitively the field types of declarations so reached) is exempt from the prefix check, whether transparent or opaque: naming a type grants no construction. Because `decl_refs` merges type and expression references, this needs a separate traversal that records whether each reference sits in a type position. One context identity must not appear with two namespaces across the graph. A second context in the same namespace at another identity is refused, as E1714 refuses it today. Recording namespaces bumps the bundle format to `bundle-v2` and renames the recorded snapshot file. Every carried dependency context must record a namespace; only the bundle's own run-only root may lack one, mirroring E1708. Readers of `bundle-v1` refuse a `bundle-v2` bundle (E1735), so they fail closed. New readers accept a `bundle-v1` bundle only at the matching Core version, as today (E1720), and only when it carries no dependency contexts, since carried contexts have no recorded namespace. The v1 root context's namespace comes from its digest-verified `project.jqd`, and E1739 applies to it with that namespace. A `bundle-v2` root's recorded namespace must equal its `project.jqd` namespace (E1739). Any other `bundle-v1` bundle is refused (E1735) and must be rebuilt as `bundle-v2`. A `bundle-v1` bundle cannot contain an opaque declaration, and one that does is refused (E1735). Bundle terms are then checked by region (E1738, above). Store admission itself never refuses (see single files). |
| Unchecked evaluation | `eval-code` refuses any payload with a live reference to a sealed constructor, in single-file and project mode, the owner's own dynamic code included. Bundle runs need no refusal: a bundle cannot reference `eval-code` at all (E1721). Quoting stays plain data. This bounds direct construction only. In project mode, dynamic code resolves with the root project's visibility, as today, whichever project's code performs `eval-code`, and it runs with root authority. A dependency's private helpers stay refused (E1709), but the root's private helpers, including any that construct the root's sealed types, are callable. `eval` is a root-granted effect that appears in the calling function's type, so granting it to a computation that runs dependency code trusts that dependency with the root's private term access. Caller-scoped visibility is out of scope. In single-file mode, dynamic code can call any stored term. The native backend has no `eval-code`, so it needs no counterpart. |
| Host ingress (E1604) | Host protocol v0 refuses opaque types in both directions, with no wire change. Manifest-abstract types, which are not opaque, remain constructible through generic host decoding, as today. The type preflight inspects reachable field types through a cycle-safe, store-aware walk, so a transparent wrapper around an opaque type is refused too. The value guard recurses through arguments, results, operation arguments and operation responses. The host worker uses an arbitrary store with no session ownership, so only this type-level marker can protect it. A sealed-handle host protocol needs a new protocol version and is deferred. |
| Setters | An opaque type gets no generated setters. Exporting a setter of a manifest-abstract type warns (W1703). Accessors are still generated, because reading a field cannot violate an invariant. |
| Display | A value of an opaque type renders as `<opaque name>` everywhere the runtime renders values except typed observations, so its representation is not observable through display. That covers `debug.inspect`, run results, diagnostics and match-failure messages, and unapplied constructors. Typed observations map a value of an opaque type to the opaque observation before its constructor arguments are walked, with the single kind word `opaque` added to the transcript's opaque kinds. Observations drop the type name and render as `<opaque>`. The same slice adds the missing `capability` kind, which observations already emit. Transcripts record it as unsupported and never compare it, as for secrets and closures: two different probabilities must not compare equal. Older readers refuse the unknown kind, so they fail closed. **Rendering is split in two.** `Value.show` stays the structural rendering, unchanged, because inference uses it as an equality and aggregation key (`infer_dist`, `posterior_risk`, `warp`); redacting it would merge distinct opaque outcomes. A new redacting renderer serves every user-facing site, and S3 classifies each existing `Value.show` call as key or display; the native runtime splits likewise. **Run transcripts (`run-transcript-v1`) stay structural**: their recorded bytes are the comparison key for relational Warp and `run --compare`, so the byte format and key are unchanged. A transcript file and its divergence messages therefore expose an opaque value's representation, as the store does: they are local artifacts with the store's trust, outside the display guarantee. **A site that is both key and display keys on the structural rendering and prints the redacted one.** `dist-diff` matches posterior entries by structural rendering and prints them redacted. Its on-disk posterior cache stores only the structural text, which cannot be redacted on a cache hit, so a posterior containing an opaque value is never cached. **Opacity is looked up by constructor identity.** A constructor's identity derives from its declaration's bytes, which include the opaque marker, so whether a constructor is sealed is a fact about the hash itself, the same in every store. Every store records the opaque constructors it indexes in a process-wide registry (`Opaque_registry`), and the redacting renderer (`Value.display`) and `Observation.of_value` consult it, so neither needs a store and runtime values need no extra field. The native runtime carries the type name in the static constructor info. It is a pure function of the constructor identity, so equality, ordering, hashing and fingerprints are unchanged; ordering can still reveal the representation. `Show` is a user dictionary with no structural instance, so it is unaffected. |
| Trusted carriers | Secret, Task, Resume and scoped-instance capabilities keep their frozen-identity protection. User opacity adds to those guards and does not replace them. |

### 2.5 Manifest-abstract types

A transparent type exported without its constructors keeps today's name-level
hiding. A warning (W1703) suggests `opaque` when a type is exported abstractly,
and also covers exporting such a type's setter.

## 3. Identities, compatibility and migration (API.1)

Opacity binds every identity that mentions the type, so it flows into
`interface-v1` and `project-context-v1` pins. The `interface-v1` format does not
change; sealed constructors appear among hidden members.

API compatibility and pin stability are separate questions. Any change to an
interface's identity, additive or not, changes the context pin, and the
dependent project must re-pin.

Three notions differ. **Source compatibility** asks whether clients still
compile after rebuilding and re-pinning. **Behavioural compatibility** further
requires every public operation and accessor to keep its meaning; it never
covers display or typed observations, which an opacity change alters. The **`diff` classifier** treats any identity
change in an exported signature as incompatible, because signatures embed
hashes; TYPE.1 does not change that classifier. The table gives source compatibility and the behavioural caveat.

| Change | Source compatibility (behavioural caveat) | Pin |
|---|---|---|
| making a type opaque | breaking | re-pin |
| making an opaque type transparent again (the abstraction widens) | compatible, absent constructor-name collisions; display and observations now expose the representation | re-pin |
| changing an opaque type's representation (fields, constructor names, field labels) | compatible if every public signature and exported accessor is preserved; behavioural only if their semantics are too, and clients that depend on ordering or structural equality can still observe the representation | re-pin |
| changing a smart constructor's body | compatible; validation outcomes may change | re-pin |
| removing an export | breaking | re-pin |
| adding a validated function or exporting an existing accessor | compatible | re-pin |
| widening a manifest-abstract type (`diff` labels it "abstraction widened") | compatible, absent constructor-name collisions | re-pin |

These claims cover clients that use stable public names. A client that
references an exported term or type by explicit hash must update the hash
after any change to that identity. Widening a type, or making it transparent,
exports its constructors, which can collide with a client's or another
dependency's constructor names (E1731); the claims assume no such collision.

A representation-independent identity is future work.

E1737 is a breaking change for one existing case: a root project without a
namespace that declares a transparent type or an effect whose name begins with
a dependency's namespace prefix. Two further observable changes: a single file
or namespace-less root that rebinds a prelude constructor or governance term
name no longer gets its own declaration back from builtins, and a project or
bundle run can no longer pass a private model term to a posterior builtin by
hash. The release notes record it.

## 4. Demonstrations

Three library projects under `demos/abstract-types/`, and a client
application that depends on all three:

- **Probability** (namespace `prob`): `opaque type ProbValue = ProbValue(value: Real)`.
  - `prob.of-real : Real -> Result Text ProbValue` rejects NaN and values
    outside [0, 1].
  - `prob.value`, `prob.complement` and `prob.both` are closed over the
    invariant.
- **NonEmptyList** (namespace `nel`): `opaque type NelList a = NelList(head: a, tail: List a)`.
  - `nel.of-list` returns an option.
  - `nel.singleton`, `nel.head` (total), `nel.to-list` and `nel.map`.
- **ValidatedRequest:** an opaque validated request built by
  `req.validate(name, email, age) : Result ReqInvalid ReqValid`, in namespace `req`, with accessors.

## 5. Evidence

Write the failing forgery tests first, then make them pass:

- **External attempts**, each refused:
  - by name (E1705);
  - by pattern;
  - by explicit and derived constructor identity (E1709);
  - by a manifest constructor export (E1736);
  - by root re-declaration, in either installation order (E1737);
  - by a hostile bundle exporting a dependency's constructor (E1739);
  - by a hostile bundle whose private term constructs a sealed value, or
    calls a library's unexported raw helper by hash (E1738);
  - by a dependency whose term constructs its consumer's sealed type (E1738);
  - by two carried contexts that both export one constructing term (E1738),
    and by a constructing term that lies in no region (E1728 fires first);
  - by a hostile root calling a private member of a library's exported
    recursive group by hash (E1738);
  - by a bundle that records a sealed constructor as an export (E1736);
  - by an unapplied constructor returned from a helper, and by a live splice
    (E1738);
  - by a byte-identical re-declaration of a library type, including one
    reached only inside a bundle (E1737);
  - by a bundle that relabels a carried context's namespace (E1739);
  - by a forged wrapper type;
  - by `eval-code` payloads in project and single-file mode;
  - by host invocation with an opaque type, directly or inside a transparent
    wrapper, in either direction (E1604).
- **Positive cases:**
  - smart constructors and internal matches in the owner's entries;
  - two equivalent copies of one library, accepted;
  - a bundle's own private and entry-only helpers that construct its sealed
    type, accepted;
  - a single-file program with an opaque type, which checks and emits a public
    interface without its constructors.
- **Annotation-only references:** a consumer that names a dependency's
  unexported transparent or opaque type in an annotation or a field type is
  accepted by E1739.
- **Documented limit:** a dependency granted `eval` that calls a
  root-private constructing helper by hash succeeds, pinning the stated bound.
- **Display:** `<opaque name>` on both engines.
- **Inference keys:** inference over distinct opaque outcomes, directly and
  inside containers, keeps them distinct on both engines; so do relational
  Warp, run comparison and `dist-diff`, and the native `pmf` equality.
- **Rebound builtin names (construction)**, for a namespace-less root (a
  namespaced consumer is refused earlier by E1706 or E1731): a dependency
  bundle whose
  exported function calls `support(bernoulli(1.0))`, run by a consumer that
  declares `opaque type Bool = False | True`, yields prelude booleans, not the
  consumer's sealed values, on both engines; likewise a rebound
  `governance.validate-call` is not invoked by a dependency's posterior call,
  and a dependency's posterior call naming the root's private constructing
  model by hash is refused (E1709).
- **Rebound builtin names (display):** a single file declaring an opaque type whose
  constructor is named `true`, `cons` or `mk-pair` still renders `<opaque name>`
  through inference and Warp results.
- **Migration:** a representation change requires a re-pin (E1710), and so does
  an additive export.
- **Regressions:**
  - unchanged corpus and prelude hashes;
  - the existing Secret, Task and instance carrier tests;
  - native parity for the three demos.

## 6. Slices

| Slice | Content |
|---|---|
| S0 | This design, and the specification of the canonical tag |
| S1 | Kernel, canonical form, surface syntax, printer and formatter; corpus hash stability |
| S2 | Project frontend (namespace ownership with prelude precedence, E1736, E1737, interface projections), bundle contexts and verification (E1739), reachability scope (E1738), the single-file point-of-use refusal, setter suppression and W1703 |
| S3 | Runtime and host: per-constructor opacity metadata and `<opaque name>` rendering at every value-rendering site, the `eval-code` refusal, the transitive host v0 refusal and its specification text |
| S4 | Native display and the three demos with parity |
| S5 | Documentation: surface syntax, errors, the API identity migration table, project structure |
