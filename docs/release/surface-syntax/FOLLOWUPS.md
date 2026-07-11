# Surface Syntax Follow-ups

This tracked ledger records scope deliberately excluded from SS.21. Successor
milestone **SS.22, prelude naming and text building**, completed D38 and D39
without changing the surface grammar. The SS.0-SS.22 implementation arc is
complete, but D36 accessor generation and label validation remain deliberately
partial and Tier-F remains parked. None of this ledger establishes stability or
a freeze for the whole surface syntax.

## D36 Generated Constructor Accessors

D36 is partial. Labeled constructor field syntax, field metadata and trivia,
lowering, and canonical printing shipped in SS.8. Surface lowering does not
emit generated accessor `DefTerm` declarations. Duplicate labels are accepted
rather than diagnosed, and the draft's cross-constructor label consistency and
explicit-term collision rules are not enforced. These omissions are the
reviewed partial boundary, not accidental claims that SS.8 generated accessors.

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

D38 completed in SS.22. The callable prelude builtin, focused tests, `.jac` and
`.jqd` corpus twin, native differential cases through eight arguments, and
executable documentation meet the contract below. The language/interpreter
contract remains unbounded; native v1 refuses nine arguments with E1101 under
its global ABI ceiling. Text interpolation remains absent and is still a
separate grammar decision. The old list-plus-separator object is preserved
hash-for-hash under deprecated migration-only `text.join-list`; variadic
`text.join` is a new canonical object with marker `text.join-variadic-v1`.

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
