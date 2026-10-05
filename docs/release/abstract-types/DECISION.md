# TYPE.1 Abstract Types Decision

Status: implemented, 2026-10-04. Design: `docs/designs/abstract-types.md`.

## Decision

Add opaque types. `opaque type ProbValue = ProbValue(value: Real)` declares a
type whose constructors are sealed: only the owning project, or the single
source that declares the type, constructs or matches them. A library can then
enforce an invariant (a probability lies in [0, 1], a list is non-empty, a
request was validated) that clients in a project graph cannot bypass by name,
by hash, by re-declaration, through a bundle, through `eval-code`, through host
protocol v0, or through a generated setter. Single files get a narrower
guarantee (Claim Boundary). Opacity is part of the type's identity
(declaration tag `0x47`). Transparent declarations keep their bytes, so no
existing hash changes, the prelude's included.

Owner decisions (2026-10-03):

- the marker is the contextual keyword `opaque` before `type`;
- re-declaring another project's type or effect is refused for all types and
  effects, not only opaque ones (E1737);
- `eval-code` refuses a live reference to a sealed constructor everywhere,
  the owner's own dynamic code included;
- an opaque value displays as `<opaque name>`, and as `<opaque>` in typed
  observations.

## Upgrade Notes

Breaking or observable changes, each refused with a stated code:

- **E1737.** A root project without a namespace, or an entry unit of any
  project, may no longer declare a type or effect whose name lies in another
  project's namespace, even a byte-for-byte copy. Rename the declaration, or
  give the root its own namespace.
- **Prelude names stay the prelude's.** A single file, or a root without a
  namespace, that rebinds a prelude constructor or governance term name no
  longer gets its own declaration back from the builtins that look those names
  up; the builtins use the pinned prelude identities.
- **Posterior models must be exported.** In a project or bundle run, a
  posterior builtin accepts only a prelude term or a term some context exports;
  passing any other model by hash, the root's own unexported terms and entry
  definitions included, is refused (E1709). Export the model term.
- **Bundles are `bundle-v2`.** A bundle records the namespace of every context
  it carries. A `bundle-v1` bundle that carries dependency contexts, or that
  contains an opaque declaration, is refused (E1735); rebuild it with
  `jacquard project bundle`. Older readers refuse `bundle-v2` (E1720 or E1735).
- **Older tools fail closed.** A tool without TYPE.1 reads the opaque marker as
  a malformed constructor specification. It refuses a bundle that carries an
  opaque declaration, and it cannot open a persistent store that holds one at
  all, not only that declaration.
- **Transcripts.** Typed observations gain the unsupported kinds `opaque` and
  `capability`; older transcript readers refuse them. `run-transcript-v1`
  bytes are unchanged and stay structural, so a transcript file exposes an
  opaque value's representation, as the store does.
- **`dist-diff` cache.** The posterior cache key is now versioned
  (`dist-diff-v2`), so existing cache entries are ignored. A posterior that
  contains an opaque value is never cached.
- **Host protocol v0** refuses opaque types in both directions (E1604),
  including a transparent type whose fields reach one. Manifest-abstract types
  are unaffected.
- **Native runtime.** `jq_con_info` gains `type_name` and `opaque`, and the
  runtime adds `jq_display`. C code that initializes `jq_con_info` by hand must
  set the two fields; omitted trailing fields zero-fill to a transparent
  constructor with no type name, so its values print unredacted, and
  `-Wmissing-field-initializers` reports them. `jq_show` is unchanged and stays the structural key.

Identity and compatibility, including the migration table for changes to an
opaque type, are in `docs/release/api-identities/DECISION.md` (Opaque Types).

## Evidence

- `test/test_opaque_types.ml`: the marker, canonical identity, printing,
  single-file sealing (E0315), public projections and setters, frozen builtin
  identities, the `eval-code` refusal, and display versus structural keys.
- `test/test_bundle_regions.ml`: bundle namespaces and regions (E1738,
  E1739) and the posterior model guard (E1709).
- `test/cli/project-bundle.t`: `bundle-v2`, its namespace checks (E1739),
  the refusal of a `bundle-v1` bundle that carries dependency contexts (E1735)
  and the acceptance of one that does not.
- `test/test_host_invoke_preflight.ml`, `test/test_host_boundary_codec.ml` and
  `test/test_host_session.ml`: host protocol v0 refusals (E1604).
- `test/cli/opaque-types.t`: constructor export (E1736), re-declaration,
  including a byte-for-byte copy and an entry unit (E1737), explicit identities (E1709), and
  redacted `dist-diff` output with no cache file.
- `test/native-gauntlet/g53-opaque-display.jqd`: native and interpreter
  redaction agree byte for byte.
- `test/cli/abstract-types-demos.t`: the `demos/abstract-types` libraries and
  client on both engines.
- `docs/release/0.2/EVIDENCE.md` records each slice's evidence.

## Claim Boundary

Opacity is language access control for checked code, not concealment. Stores,
bundles and run transcripts hold every value's representation and are readable
by anyone with the files. Value ordering can still reveal a representation.
Single-file sealing protects only within one run and against `eval-code`:
another file may repeat the declaration and so construct its values, and a
persistent store is trusted content whose stored terms any later run can call.
In project mode, dynamic code runs with the root's visibility, so the root's
own private helpers stay callable from `eval-code`. A sealed-handle host
protocol is future work.
