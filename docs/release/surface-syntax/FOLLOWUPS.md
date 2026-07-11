# Surface Syntax Follow-ups

This tracked ledger records scope deliberately excluded from SS.21. The next
milestone remains **SS.22, prelude naming and text building**.

## D36 Generated Constructor Accessors

D36 is partial. Labeled constructor field syntax, field metadata and trivia,
and canonical printing shipped. Surface lowering does not emit generated
accessor `DefTerm` declarations, and it does not enforce the draft's
cross-constructor label consistency or explicit-term collision rules.

Current non-generation evidence is pinned in `test/cli/surface.t`: declaring
`type Pair = | Pair(left: Int, right: Int)` and evaluating
`pair.left(Pair(1, 2))` exits 1 with E0301 naming the unknown `pair.left` term.
This is evidence of the missing feature, not its implementation contract.

**Acceptance contract:**

| contract | required value |
|---|---|
| generation | lowering emits one ordinary pure `DefTerm` accessor per eligible label |
| name | each accessor is named `<type-kebab>.<label>` |
| provenance | each accessor is marked `surface-generated` |
| execution | `pair.left(Pair(1, 2))` prints exactly `1` and exits 0 instead of E0301/exit 1 |
| display | the printer emits the owning labeled type exactly once and suppresses generated accessor bodies |
| validation | reject a label missing from any constructor, duplicated within a constructor, inconsistent in type across constructors, or colliding with an explicit term |
| diagnostics | each validation failure has a dedicated diagnostic code and exact span tests |
| preservation | bootstrap identity, full tests, doctests, twins, and demos remain green |
| excluded | labeled patterns remain outside this acceptance gate |

## D38 Variadic Text Join

D38's promised variadic `text.join` is absent. Text interpolation remains a
separate grammar decision and is not part of SS.22.

**Acceptance contract:**

| contract | required value |
|---|---|
| export | the prelude exports `text.join` |
| arity | `text.join` accepts zero or more `Text` arguments, not the current two-argument `(List Text, Text)` shape |
| semantics | arguments are concatenated in call order and the zero-argument result is empty text |
| type | `text.join : (Text...) ->{} Text` |
| evidence | focused prelude tests, callable `.jac` examples, and executable documentation pin zero, one, and multiple arguments |
| implementation | no host-only bypass; `dune build @all` and full `dune runtest` pass |

## D39 Comparison Naming

D39's `gt?`, `gte?`, `lt?`, and `lte?` predicates and `real.*` migration are
absent.

**Acceptance contract:**

| contract | required value |
|---|---|
| predicates | applicable numeric dictionaries export exactly `gt?`, `gte?`, `lt?`, and `lte?` |
| semantics | the four predicates return `Bool` for strict greater-than, greater-or-equal, strict less-than, and less-or-equal respectively |
| real names | migrate `add-real`, `sub-real`, `mul-real`, `div-real`, and `lt-real` to the reviewed `real.*` namespace |
| migration | remove obsolete tracked demo, corpus, fixture, and executable-documentation call sites |
| evidence | focused prelude and `.jac` CLI tests pin every predicate and migrated real operation |
| gate | `dune build @all` and full `dune runtest` pass |

## Tier-F Linearity Modes

No one-shot or multi-shot declaration syntax or checker rule ships in v0.

**Acceptance contract:**

| contract | required value |
|---|---|
| modes | declarations distinguish `one-shot` and `multi-shot` operations |
| one-shot semantics | a captured continuation may be resumed at most once; a second resume is rejected by the checker or a pinned runtime diagnostic |
| multi-shot semantics | a captured continuation may be resumed more than once and preserves existing deep-handler behavior |
| runtime | specify interaction with native copy-on-resume and interpreter continuation cloning |
| migration | define defaults for existing declarations plus compatibility and migration rules |
| evidence | pin checker diagnostics and interpreter/native semantic parity before any grammar change |

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
