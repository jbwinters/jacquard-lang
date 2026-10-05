# API.1 Portable Public-Interface Identities Decision

- Decision date: 2026-09-23
- Reconstruction base: `57aff70b` (main after SX.27)
- Release posture: post-0.2 successor research prototype

## Decision

Ship a versioned interface manifest, `interface-v1`, as the portable
description of what a checked source or a store exposes. It is derived from
semantic artifacts, never authored: `Frontend.check` seals one into every
checked artifact (`Frontend.Checked.interface`), `Interface.of_side` derives one
from a store, and `jacquard interface emit` writes one. `HASH_V0`, the kernel,
the object store, `names.jqd`, and bootstrap `.jqd` are unchanged.

The manifest binds each export name to:

- its **exact identity** (the member, constructor, operation, type, or effect
  hash) and the declaration hash that owns it;
- its **checked signature** for a term, constructor, or operation, rendered with
  every referenced identity spelled as its full hash, so the text does not
  depend on any name;
- an operation's **continuation mode**; a type's or effect's **arity**;
- its **external call labels**: the term's or operation's `call-abi-v1`
  companion, or the constructor's field labels. Absent labels mean
  positional-only, which is never inferred from binder names;
- its **visibility**: exports are the public bindings; every derived member of
  an exported declaration that is not itself bound is recorded as a `hidden`
  member with its owner, so a consumer knows it exists without being able to
  name it.

It also records the source digest and the prelude identity as provenance.

## Identity And Compatibility

The interface identity is `HASH_V0` of the serialized exports and hidden
members alone. Provenance lines do not enter it, so reformatting a source or
renaming its local binders leaves the identity unchanged, while renaming an
export, changing a label vector, a signature, a mode, an arity, or an export's
membership changes it.

`Interface.diff` compares two manifests by (name, kind); a rename pairs a name
that disappeared with a name that appeared for the same identity, so an alias
(two names for one identity) that is added or removed is reported as exactly
that. A change is
**compatible** only when it is purely additive: a new export, or a hidden
member becoming public. A removed export, a rename (the same identity under
another name), an identity, signature, label, mode, or arity change, or an
export becoming hidden is **breaking**. `jacquard interface diff` prints one
line per change and exits 1 for a breaking report.

## Serialization And Portability

A manifest is a deterministic form file (the `.jqd` carrier, one form per line,
exports sorted by name then kind). The `(interface-v1 (hash-algorithm
"HASH_V0"))` header comes first; another version or algorithm, an unknown form,
or a malformed export is refused with E0613. Serialization round-trips exactly,
and a manifest derived from a source equals the one derived from a store the
same declarations were installed in, so a pin made from source is checkable
against any provider.

## Import Validation

`Interface.verify` (and `jacquard interface verify MANIFEST STORE`) accepts a
store only when it provides the interface exactly:

- the prelude identity matches when both sides record one;
- every export is bound, for its kind, to its recorded identity;
- a term or operation carries the recorded `call-abi-v1` companion exactly. A
  store that holds the same identity without a companion, or with different
  labels, is refused (E0614); labels are never reconstructed from binders;
- the declaration that owns each export agrees with the recorded owner,
  operation mode, type or effect arity, and constructor field labels, so a
  manifest edited by hand cannot vouch for contracts the store does not
  declare;
- no hidden member is publicly bound.

Signatures are not re-derived on import. An identity fixes its signature
relative to the prelude, and both are verified; re-checking inside a store
whose names were rebound (a source that redefines `Int` or `eq`) would report
spurious differences, which is what makes source and store derivations
agree.

Every mismatch is reported, in manifest order.

## Export And Quotation

`jacquard export` is unchanged: it still emits positional `.jqd` only, and the
exported program keeps its hashes and behaviour. The companion artifact is the
manifest, produced separately by `jacquard interface emit`; a positional export
plus its manifest is the portable pair, and `verify` shows exactly what the
export alone loses (its companions). Quoted named calls remain E1238: quoted
code has no durable label carrier, and this decision does not add one. A later
checked-code artifact (CODE.1) may pin a manifest identity alongside quoted
code; that is its decision to make.

## Consumers

- PKG.1 (217) pins dependencies and declares exports through manifests and
  checks providers with `verify`.
- TYPE.1 (218) turns the recorded hidden members into an enforced abstraction
  boundary; today hiding is a store fact the manifest reports and enforces on
  import, not a language rule.
- CODE.1 (222) pins the interface identity and dependencies of checked code.
- DX.1 (227) reads labels, signatures, and identities by name from the sealed
  interface instead of re-deriving them.

## Opaque Types (TYPE.1)

An `opaque type` (`docs/designs/abstract-types.md`) changes no format here.
Its constructors are sealed, so they appear among an interface's hidden
members and never among its exports (E1736). Opacity is part of the type's
identity (declaration tag `0x47`), so it flows into every interface and context
pin that mentions the type, and `Interface.diff` reports making a type opaque,
or transparent again, as an identity change.

Any change to an interface's identity, additive or not, changes the context
pin, and dependent projects re-pin. The table gives source compatibility: do
clients still compile after rebuilding and re-pinning? The caveat in each row
is behavioural. Behavioural compatibility never covers display or typed
observations, which an opacity change alters.

| Change | Source compatibility (behavioural caveat) | Pin |
|---|---|---|
| making a type opaque | breaking | re-pin |
| making an opaque type transparent again (the abstraction widens) | compatible, absent constructor-name collisions; display and observations now expose the representation | re-pin |
| changing an opaque type's representation (fields, constructor names, field labels) | compatible if every public signature and exported accessor is preserved; behavioural only if their semantics are too, and clients that depend on ordering or structural equality can still observe the representation | re-pin |
| changing a smart constructor's body | compatible; validation outcomes may change | re-pin |
| removing an export | breaking | re-pin |
| adding a validated function or exporting an existing accessor | compatible | re-pin |
| widening a manifest-abstract type (`diff` labels it "abstraction widened") | compatible, absent constructor-name collisions | re-pin |

These claims cover clients that use stable public names. A client that names
an exported term or type by explicit hash must update the hash after any change
to that identity. Exposing constructors can collide with a client's or another
dependency's constructor names (E1731).

## Evidence

- `test/test_interface.ml`: rename and reformat stability; label, signature,
  mode, arity, addition, removal, and visibility detection; deterministic round
  trip and refused damage; import validation against a positional twin, a
  relabeled provider, a partial provider, and a bare store; source/store
  agreement; the scheduler carrier's private constructor as a hidden member.
- `test/cli/interface.t`: byte-identical emission, the atomic output rule, E0613,
  the diff verdicts and exit codes, `verify` against a provider store and the
  positional export, refusal of a missing store without creating one, help
  presence, and the rota-optimizer model's interface (the one application
  model that stands alone; `emit` checks a single file, and multi-unit
  applications wait for PKG.1's project workflow).
- Existing stores, positional exports, and every prior transcript are unchanged.

## Claim Boundary

This is the minimal producer, validator, and API diff the consumers need. It
does not add namespaces, project files, registries, signatures, a compatibility
solver, or a language-level visibility rule, and it does not freeze the
manifest format beyond `interface-v1`.
