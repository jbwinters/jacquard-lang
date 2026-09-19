# Surface Syntax Follow-ups

This tracked ledger records scope deliberately excluded from SS.21. Successor
milestone **SS.22, prelude naming and text building**, completed D38 and D39
without changing the surface grammar. The SS.0-SS.22 implementation arc is
complete. SX.24 subsequently shipped labeled partial patterns, and SX.27
completed D36 with generated accessors and declaration-time label validation;
Tier-F remains parked. SX.23 separately shipped direct named calls with
explicit term/operation labels and constructor field-label reuse; it did not
ship accessors, defaults, label puns, or named local/higher-order calls. None of
this ledger establishes stability or a freeze for the whole surface syntax.

## D36 Generated Constructor Accessors

D36 completed in SX.27. Labeled constructor field syntax, field metadata and
trivia, lowering, and canonical printing shipped in SS.8, and SX.24 shipped
partial labeled patterns. SX.27 adds the rest: surface lowering follows each
labeled type declaration with one ordinary pure `DefTerm` accessor
`<type-kebab>.<label>` per label that every constructor carries, and it
validates labels when the type is declared. A label repeated within one
constructor is E1239, a label whose field type differs between constructors is
E1240, and an accessor whose name an explicit term of the same file defines is
E1241, each reported at the label.

Eligibility decision (SX.27). The draft rule rejected a label missing from any
constructor. SX.27 instead accepts such a label and generates no accessor for
it: a pure accessor must answer for every constructor, and seventeen accepted
sum types in the maintained applications, case studies, and documentation
fixtures deliberately label only some constructors (for example the release-risk
case study's `Decision`, whose `Canary(percent: Int)` and `Hold(reason: Text)`
sit beside a bare `Ship`). Those labels keep their partial-pattern and named-construction
uses. Duplicate and type-inconsistent labels, which no maintained source
declares, are rejected outright. Calling `<type>.<label>` for an ineligible
label remains the ordinary E0301 unknown name.

Evidence: `test/cli/surface.t` runs `pair.left(Pair(1, 2))` and prints `1` in
the interpreter and the native binary, and pins the exact E1239, E1240, and
E1241 spans. `test/test_surface_decls.ml` shows that generated accessors equal
explicit kernel twins in resolved form and canonical identity, and that
ineligible labels generate nothing. The surface printer suppresses accessor
declarations and `check --print-sigs` omits their signatures, so `fmt`,
rendered output, and signature listings show only the owning type.

Migration. Existing labeled declarations keep their meaning; they gain
accessors. A surface declaration that repeats a label (formerly refused only
when a labeled pattern used the ambiguous label, E0308) is now refused where
it is declared. A file that hand-writes a selector under the generated name is
refused with E1241 and drops the hand-written copy: the only maintained case,
the night-shift case study's `reading.ms`, was exactly the generated accessor.
A raw bootstrap `defterm`, and an effect operation the file declares, both
count as explicit; a definition in another file or already in the store is
shadowed by the accessor exactly as a hand-written definition of that name
would shadow it, and is not refused. Only a surface `type` declaration
generates accessors: a raw bootstrap `deftype` inside a `.jac` file keeps the
bootstrap carrier's meaning, with neither generation nor the label rules. An escaped type name that cannot prefix a dotted name (one
ending in `?` or `!`) generates no accessors.

Accessors are ordinary store terms. Only presentation hides them (the printer,
`fmt`, and `--print-sigs`); `hash` lists their identities after the type,
`diff` reports a renamed label as a removed and an added accessor (a real
change of the type's API), and `test --coverage` counts them like any term.
E1240 compares field types before names resolve: effect rows compare as sets,
and a field type that mentions a hash reference is left to the checker, which
types the accessor's clauses against each other.

**Acceptance contract:**

| contract | required value |
|---|---|
| generation | lowering emits one ordinary pure `DefTerm` accessor per eligible label |
| name | each accessor is named `<type-kebab>.<label>` |
| provenance | each accessor is marked `surface-generated` |
| execution | `pair.left(Pair(1, 2))` prints exactly `1` and exits 0 instead of E0301/exit 1 |
| display | the printer emits the owning labeled type exactly once and suppresses generated accessor bodies |
| validation | reject a label duplicated within a constructor, inconsistent in type across constructors, or colliding with an explicit term; a label missing from some constructor is accepted without an accessor |
| diagnostics | each validation failure has a dedicated diagnostic code and exact span tests |
| preservation | bootstrap identity, full tests, doctests, twins, and demos remain green |
| excluded | shipped labeled partial patterns are independent of this accessor gate |

## D38 Variadic Text Join

D38 completed in SS.22. The callable prelude builtin, focused tests, `.jac` and
`.jqd` corpus twin, native differential cases through eight arguments, and
executable documentation meet the contract below. The language/interpreter
contract remains unbounded; native v1 refuses nine arguments with E1101 under
its global ABI ceiling. Successor SX.26 closes the separate grammar decision
with marked text that lowers locally to the same `text.join` object. The old
list-plus-separator object is preserved hash-for-hash under deprecated
migration-only `text.join-list`; variadic `text.join` is a new canonical object
with marker `text.join-variadic-v1`.

**Acceptance contract:**

| contract | required value |
|---|---|
| export | the prelude exports `text.join` |
| arity | `text.join` accepts zero or more `Text` arguments |
| semantics | arguments are concatenated in call order and the zero-argument result is empty text |
| type | `text.join : (Text...) ->{} Text` |
| compatibility | deprecated migration-only `text.join-list : (List Text, Text) ->{} Text` retains old marker `text.join` and hash `b39cc4607d94b6fc777f781207fff5d9bf9dff9d96ff11361a69d4032a0a4bfd` |
| identity | variadic `text.join` is a distinct object with marker `text.join-variadic-v1` and hash `c6b3e1429d584f14e81f4b1dd46b314ae038170bafc8ac0abdfb0162ed54141d` |
| evidence | focused prelude tests, callable `.jac` examples, and executable documentation pin zero, one, and multiple arguments |
| native | interpreter/native parity is pinned through 8 arguments; 9 succeeds in the interpreter and is E1101 in native v1 |
| implementation | no host-only bypass; focused identity, checker, interpreter, native, ASAN, tier, and boundary tests are required before the full gate |

## D39 Comparison Naming

D39 completed in SS.22. The old hyphenated public names were removed, not
deprecated aliases; the dotted operations therefore have one canonical object
each. Their historical marker IDs and hashes remain unchanged, so old hash
references continue to typecheck and run in both backends. Focused, corpus,
demo, identity, hash-reference, and native evidence meets the contract below.

**Acceptance contract:**

| contract | required value |
|---|---|
| predicates | applicable numeric dictionaries export exactly `gt?`, `gte?`, `lt?`, and `lte?` |
| semantics | the four predicates return `Bool` for strict greater-than, greater-or-equal, strict less-than, and less-or-equal respectively |
| real names | migrate `add-real`, `sub-real`, `mul-real`, `div-real`, and `lt-real` to the reviewed `real.*` namespace |
| identity | only the public name index changes; all five historical semantic hashes and marker IDs remain stable |
| migration | remove obsolete tracked demo, corpus, fixture, and executable-documentation call sites |
| evidence | focused prelude and `.jac` CLI tests pin every predicate and migrated real operation |
| gate | `dune build @all` and full `dune runtest` pass |

## Tier-F Linearity Modes

EL.0 and EL.1 shipped the interpreter/native once-resumption backstop and the
hash-stable kernel operation-mode field. EL.4 now ships D41-D42: `.jac`
requires an explicit `once` or `multi` mode for every operation, accepts
`once effect`/`multi effect` only as uniform-effect shorthand, and prints
mixed effects with a mode on every operation. Bootstrap `.jqd` remains
compatible: absent mode uniquely means legacy `Multi`, and explicit `once`
changes canonical identity. The affine `Resume` checker and stdlib assignments
remain owned by their companion EL.2/EL.3 tasks rather than this surface slice.

**Acceptance contract:**

| contract | required value |
|---|---|
| modes | surface declarations distinguish explicit `once` and `multi` operations, with uniform effect-level shorthand |
| once semantics | a captured once continuation may be resumed at most once; the interpreter and native runtime reject a second resume with E0906 |
| multi semantics | a multi continuation may be resumed repeatedly and preserves existing deep-handler behavior |
| compatibility | bootstrap absent mode remains the unique legacy `Multi` encoding; explicit `once` is interface-hashed |
| surface default | none; omission, duplication, shorthand/per-operation conflict, and partially annotated mixed effects are E1236 |
| evidence | focused parser/printer/recovery tests and a `.jac`/`.jqd` twin pin D41-D42 before release integration |

## Tier-F Resource-Scoped Rows

No resource/path-qualified row syntax or capability guarantee ships in v0.

**Acceptance contract:**

| contract | required value |
|---|---|
| display | signatures render resource scope, including the reviewed example `Fs(read: ./config)` |
| semantics | define whether scopes constrain authority, describe effects, or both; display alone grants no authority |
| checker/runtime | pin scope validation, containment, and root-grant enforcement |
| round trip | parsing and rendering preserve the resource-scoped row meaning |
| migration | define unscoped-row compatibility and migration rules |
| evidence | pin exact signature display plus adversarial scope-escape and grant tests before any grammar change |
