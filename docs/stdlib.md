# The Jacquard Standard Library — Design, Draft 0.1

Companion to the kernel spec, the whitepaper, and the dev plan. This document
supersedes the prelude sketch in dev plan task W2.6; a reconciliation table sits at
the end.

Signature notation used throughout (display form, per the checker's elaborated
output): `name : (args) ->{row} result`. An empty row `->{}` means pure. An open row
`->{Abort | e}` means Abort plus whatever `e` turns out to be. Tail-only rows now use the
canonical `->{| e}` surface spelling; bootstrap s-expressions remain supported as the kernel
format. Rows are name-sets: an effect declaration may have type parameters, but a row contains
only the effect name. Those type parameters are erased from the row, so payload types remain
independent type variables in the surrounding arguments, result, and `forall` binders.

Unless a fence is labeled `jacquard doctest=...`, blocks in this design document
are signature catalogs, algebraic laws, or pseudocode fragments rather than complete
source files. Executable fences are extracted to `test/docs-doctest/fixtures/`,
compared byte-for-byte, and run or checked under `dune runtest`.

---

## 1. What beauty means here

A standard library is the vocabulary a language actually speaks, and for Jacquard the
audience is split: models write most calls, people review them, often seeing one
function at a time through a bounded window. Beauty under that constraint is
predictability. A reader who knows one corner of the library should be able to guess
the rest, and a model that has seen `list.map` should emit `option.map` correctly
without ever having seen it.

Five principles generate the whole design:

1. **One word, one shape.** A verb means the same thing everywhere it appears. `map`
   transforms the contents and preserves the shell, whatever the shell is. If a type
   would need to bend a verb's meaning, that type does not get the verb.
2. **Data for results, effects for control.** A function either returns evidence
   (`Option`, `Result`) with an empty row, or performs an effect (`Abort`, `Throw`)
   that its row announces. Never sentinels, never both at once. Conversions between
   the two styles are named, few, and lawful (§5).
3. **Total by default, bang for control.** The bare name is total. The `!` suffix
   marks the variant that performs `Abort` or `Throw`, visible at every call site and
   confirmed by the row. `list.head` returns `Option a`; `list.head!` has `{Abort}`
   in its signature.
4. **Boundaries ship with implemented effects.** A shipped library effect names
   canonical handlers, an explicit runtime grant, or a documented embedding
   boundary. Reserved taxonomy names are labeled unimplemented rather than
   presented as usable library declarations.
5. **Combinators are row-transparent.** A higher-order function performs what its
   argument performs and nothing else. `for-each` with a pure function is pure; the
   same `for-each` with `println` carries `Console`. The library never hides an
   effect and never adds one.

Fixed helper effects and callback effects compose without contaminating each other.
For example, Preflight's reusable gate has signature
`forall | e. ((Code) ->{| e} Bool) ->{Dist | e} Code`: `Dist` belongs to the gate,
while a pure predicate keeps `e` empty and a scripted predicate closes `e` to
`Eval`. Top-level callers remain closed (`{Dist}` or `{Dist, Eval}`), so this
precision does not add implicit authority. Handler subtraction is unchanged: a
handler requires only its declared handled labels on flexible computations invoked
inside the handled body, including callbacks reached through typed wrappers. It
then removes those labels; helper-owned and before/after effects remain on the
outer row instead of leaking into the callback contract.

Everything else is elaboration.

## 2. The shape of the library: rings

The kernel has no modules; a codebase is hashes plus a name index. The library is
therefore organized as dependency rings, which content-addressing makes literal:
a ring may reference hashes only from itself and rings below.

| Ring | Name | Contents | Rows found here |
|------|------|----------|-----------------|
| 0 | Axioms | `Bool`, `Ordering`, `Option`, `Result`, `List`, dictionaries (`Eq`, `Ord`, `Show`), arithmetic and comparison builtins | empty only |
| 1 | Control | `Abort`, `Throw`, `State`, `Emit` with their canonical handlers; the data/control seams | effect rows, all dischargeable in pure code |
| 2 | Structures | `Text` operations, `Map`, `Set`; `Dist` with `Distribution` and the pure inference handlers | empty rows plus `Dist` |
| 3 | Boundaries | `Console`, `Clock`, `Fs`, `Net`, `Eval`, `Infer`, `Approval`, `Audit`, and `Secret`; runtime grants, governance handlers, and embedding boundaries | authority/model/governance rows reviewed in the program manifest |

The placement of `Dist` in ring 2 is a deliberate statement: inference is pure.
Enumeration needs no world at all, and likelihood weighting needs only a seed, which
is a number. Only entropy acquisition (a fresh seed) touches ring 3.

Naming convention: dotted lowercase, `list.map`, `text.split`, subject type first.
Names live in the metadata index, so all of this is curation rather than structure,
and renames are free (§8 returns to what that buys).

The complete blessed effect vocabulary—including schema-reserved interfaces, risk defaults, user-effect coloring rules, exact hashes, and
canonical handler or installation boundaries—is release-frozen in
[`effect-taxonomy.md`](effect-taxonomy.md). Review-tool behavior is documented
in [`effect-review.md`](effect-review.md).

| ET.8 blessed status | exact names |
|---|---|
| implemented (18) | `Abort`, `Throw`, `State`, `Emit`, `Dist`, `Fault`, `Eval`, `Console`, `Clock`, `Fs`, `Net`, `Workspace`, `Infer`, `Approval`, `Audit`, `Secret`, `Judge`, `Channel` |
| reserved with published identity (1) | `Async` |
| reserved/unimplemented (7) | `Choose`, `Env`, `Pg`, `Blob`, `Serve`, `Crypto`, `Log` |

The status table is descriptive, not a grant list. The full identity table is
machine-checked against `Effect_registry`, the prelude declarations, and the
TSV artifact. `Async` has an interpreted scheduler. `Channel` has the exact
SC.14 interpreted scheduler route and requires no world grant. The other seven
reserved names have no published declaration hash or handler in this release.

Phase-zero parallelism also lives in ring 0. `parallel.map` and `parallel.both`
accept only closed-empty-row callbacks, remain pure themselves, and are
observably sequential in the interpreter. They introduce neither an `Async`
effect nor a task runtime; a future native implementation may use threads only
when it preserves the same values, failures, ordering contract, and output
identity. See `concurrency.md` §3.

The `Channel a` interface frozen by SC.13 is shipped by SC.14 with its exact
hash, typed capacity error, FIFO/close/cancellation rules, and scope ownership;
see [`concurrency.md`](concurrency.md#8-typed-channels-sc13--c3-contract).
It is an interpreted scheduler facility, not a world grant or native runtime.

## 3. Ring 0: the axioms

### Core types

```jacquard doctest=stdlib-core-declarations mode=check fixture=stdlib-core-declarations.jac stdout=stdlib-core-declarations.stdout stderr=empty exit=0
type Bool =
  | False
  | True

type Ordering =
  | Less
  | Equal
  | Greater

type Option a =
  | None
  | Some a

type Result e a =
  | Err e
  | Ok a

type List a =
  | Nil
  | Cons a (List a)
```

`Unit` is the empty tuple `()`, native to the kernel. Pairs and wider products are
kernel tuples. There is no `Char` in this draft (§9, D9).

### Dictionaries: ad-hoc polymorphism, honestly deferred

Jacquard has no traits yet (kernel spec §10.3), and the library refuses to fake them
with builtin structural equality, which OCaml regrets, or compiler-magic
`comparable`, which Elm regrets. Instead, capabilities like equality are ordinary
values: single-constructor data with labeled fields, passed explicitly. The
following catalog is pseudocode because record types remain unsupported; its
field notation is a design sketch, not surface declaration syntax.

```text
type Eq a   = MkEq   { eq      : (a, a) ->{} Bool }
type Ord a  = MkOrd  { compare : (a, a) ->{} Ordering }
type Show a = MkShow { show    : (a) ->{} Text }
```

Ring 0 provides the instances (`int.eq`, `int.ord`, `text.ord`, `bool.eq`, ...) and
the derivations (`ord.to-eq : (Ord a) ->{} Eq a`, `eq.for-pair`, `eq.for-list`, and
so on). Container operations that need a capability take the dictionary as an
argument: `list.sort(xs, int.ord)`.

This is the forward-compatible move, and the reason to be unbothered about the
verbosity: every serious trait mechanism (Haskell classes, Rust traits, OCaml's
proposed implicits) compiles down to dictionary passing anyway. When the deferred
decision lands, it lands as sugar that auto-fills these exact arguments, and no
signature in this library changes shape.

### The vocabulary grid

The one-word-one-shape principle, as a grid. A check means the verb exists with the
uniform signature schema; a blank means the meaning would bend, so the verb is
absent. Models should treat rows of this grid as templates.

| verb | List | Option | Result | Map | Text |
|------|------|--------|--------|-----|------|
| `map`     | yes | yes | yes (over Ok) | yes (over values) | |
| `filter`  | yes | yes | | yes | |
| `fold`    | yes | yes | yes | yes | |
| `each`    | yes | yes | yes | yes | |
| `length`  | yes | | | yes (`size`) | yes |
| `empty?`  | yes | yes (`none?`) | | yes | yes |

Uniform schemas, with `List` as the exemplar. This is a signature catalog, not
a complete source file: surface signatures must be attached to term bodies.

```text
list.map    : (List a, (a) ->{| e} b) ->{| e} List b
list.filter : (List a, (a) ->{| e} Bool) ->{| e} List a
list.fold   : (List a, b, (b, a) ->{| e} b) ->{| e} b
list.each   : (List a, (a) ->{| e} ()) ->{| e} ()
```

Note every one of these accepts an effectful function and threads its row through
untouched, per principle 5. There is no separate `mapM`; the map is the map.

### Pure parallel hints

```text
parallel.map  : (List a, (a) ->{} b) ->{} List b
parallel.both : (() ->{} a, () ->{} b) ->{} (a, b)
```

The empty callback rows are closed contracts, not inferred open rows. Passing a
callback or thunk with any effect is a type error. The interpreter maps in input
order and forces `parallel.both`'s left thunk before its right thunk; ordinary
failure and control behavior is therefore exactly the behavior of `list.map`
and explicit left-then-right tuple evaluation. These APIs are optimization hints,
not observable concurrency.

### List, the rest of it

The following signature-only catalog intentionally omits term bodies and is
therefore not executable Jacquard source.

```text
list.head     : (List a) ->{} Option a          list.head!    : (List a) ->{Abort} a
list.last     : (List a) ->{} Option a          list.nth      : (List a, Int) ->{} Option a
list.reverse  : (List a) ->{} List a            list.append   : (List a, List a) ->{} List a
list.concat   : (List (List a)) ->{} List a     list.range    : (Int, Int) ->{} List Int
list.zip      : (List a, List b) ->{} List (a, b)
list.sort     : (List a, Ord a) ->{} List a      -- stable
list.contains?: (List a, a, Eq a) ->{} Bool
list.find     : (List a, (a) ->{| e} Bool) ->{| e} Option a
```

### Option and Result

These are interface signatures without definitions, so this catalog is kept
as `text` rather than presented as a complete source file.

```text
option.map          : (Option a, (a) ->{| e} b) ->{| e} Option b
option.then         : (Option a, (a) ->{| e} Option b) ->{| e} Option b
option.with-default : (Option a, a) ->{} a
option.get!         : (Option a) ->{Abort} a

result.map        : (Result e a, (a) ->{| f} b) ->{| f} Result e b
result.map-error  : (Result e a, (e) ->{| f} d) ->{| f} Result d a
result.then       : (Result e a, (a) ->{| f} Result e b) ->{| f} Result e b
result.with-default : (Result e a, a) ->{} a
result.get!       : (Result e a) ->{Throw} a
result.of-option  : (Option a, e) ->{} Result e a
option.of-result  : (Result e a) ->{} Option a
```

`then` is the sequencing verb (Elm's `andThen`, Rust's `and_then`); the word `bind`
is avoided as jargon, and there is no monad abstraction to name because there is no
mechanism to abstract it with yet. When traits land, `then` is the method they will
collect.

### Bool, strictly

Jacquard is strict, so `bool.and : (Bool, Bool) ->{} Bool` evaluates both arguments.
The short-circuit forms take thunks and say so in their types. The block is a
signature-only interface catalog and has no executable term bodies.

```text
bool.and-then : (Bool, () ->{| e} Bool) ->{| e} Bool
bool.or-else  : (Bool, () ->{| e} Bool) ->{| e} Bool
```

A future surface `&&` desugars to `match`, costing nothing. Until then the library
refuses to pretend strict application short-circuits.

## 4. Ring 1: control effects and their handlers

Four effects cover pure control. Each is shown with its declaration and the handlers
it ships with. An idiom appears here worth naming once: an operation whose handler
never resumes may promise any result type, so `abort : () -> a` needs no bottom type.

```jacquard doctest=stdlib-control-effects mode=check fixture=stdlib-control-effects.jac stdout=stdlib-control-effects.stdout stderr=empty exit=0
once effect Abort a where {
  abort : () -> a
}

once effect Throw e a where {
  throw : (e) -> a
}

multi effect State s where {
  get : () -> s
  put : (s) -> ()
}

once effect Emit w where {
  emit : (w) -> ()
}
```

Canonical handlers are listed by signature here; their term bodies live in the
prelude, so this is not a complete executable source block.

```text
abort.to-option : forall a | e. (() ->{Abort | e} a) ->{| e} Option a
abort.or        : forall a | e. (() ->{Abort | e} a, a) ->{| e} a
throw.to-result : forall a b | e. (() ->{Throw | e} b) ->{| e} Result a b
throw.catch     : forall a b | e. (() ->{Throw | e} a, (b) ->{| e} a) ->{| e} a
state.run       : forall a b | e. (() ->{State | e} a, b) ->{| e} (a, b)
state.eval      : forall a b | e. (() ->{State | e} a, b) ->{| e} a
emit.collect    : forall a b | e. (() ->{Emit | e} a) ->{| e} (a, List b)
emit.pipe       : forall a b | e. (() ->{Emit | e} a, (b) ->{| e} ()) ->{| e} a
```

Every signature reads the same way: take a computation whose row includes the
effect, return one whose row does not, pass everything else through. Handling is
subtraction made visible.

## 5. The seams: data and control, converted lawfully

Principle 2 splits the library into a data style and a control style. Four functions
and the handlers above are the entire border between them:

| | to control | to data |
|---|---|---|
| absence | `option.get! : (Option a) ->{Abort} a` | `abort.to-option` |
| error | `result.get! : (Result e a) ->{Throw} a` | `throw.to-result` |

The border is lawful, and the laws are corpus property tests, deliberately phrased
as round trips. Free variables and mathematical equality make these equations
law notation rather than standalone Jacquard programs.

```text
abort.to-option(fn () -> option.get!(o))        =  o
throw.to-result(fn () -> result.get!(r))        =  r
abort.to-option(fn () -> x)                     =  Some x      -- pure body
state.run(fn () -> get(), s)                    =  (s, s)
state.eval(fn () -> { put(t); get() }, s)       =  t
list.map(xs, fn (x) -> x)                       =  xs
list.map(list.map(xs, f), g)                    =  list.map(xs, fn (x) -> g(f(x)))   -- f, g pure
emit.collect(fn () -> { emit(w); x })           =  (x, [w])
```

The guidance for library authors is one sentence: compute in data style, communicate
in control style, and cross the border at the last responsible moment.

## 6. Ring 2: structures

### Text

UTF-8 throughout (dev plan D3). Indexing and length count codepoints; this is the
honest middle ground, and the document says plainly that codepoints are not
graphemes, so `text.length("👍🏽")` is 2. A grapheme-aware layer is future work
(§9, D9), and nothing here will need renaming when it arrives.

`text.join` is a callable variadic builtin, not interpolation syntax. Its
contract is `text.join : (Text...) ->{} Text`: zero arguments return `""`, one
argument returns that text unchanged, and multiple arguments are concatenated
deterministically in call order. Every argument is evaluated strictly and must
be `Text`; a non-text argument reports its one-based argument position. This
language and interpreter contract is unbounded. Native v1 parity covers zero
through eight arguments; a nine-argument application is refused with E1101 by
the general application ceiling documented in `native-compilation.md`.

`text.join-list : (List Text, Text) ->{} Text` is the deprecated migration-only
compatibility binding. It retains the pre-SS.22 `text.join` marker and member
hash `b39cc4607d94b6fc777f781207fff5d9bf9dff9d96ff11361a69d4032a0a4bfd`.
New code should use variadic `text.join`, whose distinct marker is
`text.join-variadic-v1` and whose member hash is
`c6b3e1429d584f14e81f4b1dd46b314ae038170bafc8ac0abdfb0162ed54141d`.
The two bindings are separate canonical objects, not aliases with overloaded
runtime meaning.

```jacquard doctest=stdlib-text-join mode=run fixture=stdlib-text-join.jac stdout=stdlib-text-join.stdout stderr=empty exit=0
(text.join(), text.join("one"), text.join("Jac", "qu", "ard"))
```

The remaining text block is an interface catalog with no function bodies, so
it is not a complete source file.

```text
text.length   : (Text) ->{} Int                 text.concat  : (Text, Text) ->{} Text
text.join     : (Text...) ->{} Text             text.split   : (Text, Text) ->{} List Text
text.join-list: (List Text, Text) ->{} Text      -- deprecated migration compatibility only
text.slice    : (Text, Int, Int) ->{} Text      text.trim    : (Text) ->{} Text
text.contains?: (Text, Text) ->{} Bool          text.empty?  : (Text) ->{} Bool
text.eq?      : (Text, Text) ->{} Bool          text.eq      : Eq Text
text.from-int : (Int) ->{} Text                 text.to-int  : (Text) ->{} Option Int
text.from-real: (Real) ->{} Text                text.to-real : (Text) ->{} Option Real
```

Use `text.eq?` for a direct comparison and pass `text.eq` to APIs that require
an explicit `Eq Text` dictionary, such as `list.contains?`, `dist.tally`, or
`check.eq`.

### Numeric operations and predicates

Integer dictionary primitives retain the bare names `eq`, `lt`, and
`int-compare` where existing dictionary construction uses them. Public numeric
predicates are consistently subject-first and `?`-suffixed:

```text
int.gt?  int.gte?  int.lt?  int.lte?   : (Int, Int) ->{} Bool
real.gt? real.gte? real.lt? real.lte?  : (Real, Real) ->{} Bool
```

The real arithmetic family is `real.add`, `real.sub`, `real.mul`, and
`real.div`, each `(Real, Real) ->{} Real`. SS.22 removes the former
`add-real`/`sub-real`/`mul-real`/`div-real`/`lt-real` names rather than retaining
aliases, so each operation has one canonical prelude identity. Real arithmetic
and comparisons follow OCaml/C IEEE-754 behavior. The public rename changes
only the name index: the five existing operations retain their pre-SS.22
semantic hashes and internal marker IDs, so old hash references remain valid.
Division may produce
infinity or NaN, and all four ordered comparisons return `False` when either
operand is NaN.

### Map and Set

Ordered structures parameterized by a dictionary at construction; the dictionary is
stored inside the value, so it is supplied exactly once and cannot be mixed up
afterwards. The map/set block is likewise a signature catalog; metavariables
and omitted bodies are descriptive interface notation rather than executable
source.

```text
map.empty : (Ord k) ->{} Map k v
map.set   : (Map k v, k, v) ->{} Map k v
map.get   : (Map k v, k) ->{} Option v
map.update: (Map k v, k, (Option v) ->{| e} Option v) ->{| e} Map k v
map.fold  : (Map k v, b, (b, k, v) ->{| e} b) ->{| e} b
map.size  : (Map k v) ->{} Int
set.empty : (Ord a) ->{} Set a                   -- insert, member?, fold, size
```

### Dist

The declarations from the whitepaper use the current surface grammar below.
Discrete only in this draft, matching milestone M3.

```jacquard doctest=stdlib-dist-declarations mode=check fixture=stdlib-dist-declarations.jac stdout=stdlib-dist-declarations.stdout stderr=empty exit=0
type Distribution a =
  | Bernoulli Real
  | Categorical(values: List (a, Real))
  | UniformInt Int Int

multi effect Dist where {
  sample : (Distribution a) -> a
  observe : (Distribution a, a) -> ()
}
```

The inference handlers are signature-only interface documentation; their
implementations live in the prelude and are not duplicated in this block.

```text
dist.pmf        : (Distribution a, a, Eq a) ->{} Real
dist.enumerate  : (() ->{Dist | e} a) ->{| e} List (a, Real)     -- normalized, unmerged
dist.tally      : (List (a, Real), Eq a) ->{} List (a, Real)   -- merge equal outcomes
dist.sample-lw  : (() ->{Dist | e} a, Int, Int) ->{| e} List (a, Real)  -- seed, count
```

Enumeration returns an unmerged weighted list so that it needs no equality; merging
is a separate step that asks for its `Eq` honestly. There is no separate random
number library. `sample(UniformInt(1, 6))` under the sampling handler is the die
roll, and randomness is just `Dist` without `observe`, one story instead of two.
Granting `Dist` at the root installs the entropy-seeded sampling handler; an
`observe` reaching the root is an error, since conditioning requires an inference
handler and the root has nothing to condition.

Risk `none` for `Dist` means no external authority. It does not mean “no
review”: support, weights, observations, seeds, inference handler, and
approximation error remain part of the result's uncertainty review. Likewise,
model output from `Infer` and governance confidence are evidence rather than
verified truth or consent.

One more consumer leans on `Dist`'s constructors: Warp's shrinker (W6.4) orders
each distribution's outcomes by SIMPLICITY, and shrinking lowers outcome indices.
The ordering per constructor, pinned here because generators inherit it:
`UniformInt` counts up from `lo` (index 0 = `lo`); `Categorical` uses entry order
(index 0 = the first entry, so put the simplest outcome first in generator
tables); `Bernoulli` places `false` at index 0 — "toward false" is the shrink
direction. Deleting a choice from the log replays the generator without it, which
is how one `UniformInt` length choice makes whole-list shrinking fall out.

## 7. Ring 3: world, model, meta, and governance boundaries

World effects are declared like any other; what distinguishes them is that only the
runtime installs their root handlers, under explicit grants. The row of `main` is
the program's authority manifest, and this table is what a reviewer is reading when
they read it:

| effect | risk | canonical boundary | reviewing it means |
|--------|------|--------------------|--------------------|
| `Console` | low | `console.scripted` or explicit root grant | terminal observation or interaction |
| `Clock` | low | `clock.fixed` or explicit root grant | wall-clock observation or waiting |
| `Fs` | medium | `fs.in-memory`, `fs.read-only`, or explicit root grant | filesystem access; the root grant is not path-scoped |
| `Net` | high | `net.scripted`, `net.record`, or explicit root grant | network access |
| `Eval` | high | explicit root grant only | execution of constructed code at root authority |
| `Infer` | medium | `infer.scripted` or explicit root grant | unverified model output |
| `Approval` | special | four hash-revalidating Approval handlers | exact consent semantics, not ordinary risk ordering |
| `Audit` | special | `audit.in-memory` or `audit.line-log` | evidence ordering and sink-failure behavior |
| `Secret` | special | fixed/vault embedding APIs or environment root grant | opaque lookup and deliberate plaintext exposure |

The complete reviewed assignment, including control, Warp, Dist, and Fault,
is frozen in `prelude/operation-modes.manifest`. Modes are declared in the
interfaces and never inferred from these names or descriptions.

Convenience functions build on the ops in ordinary code: `println`, `console.ask :
(Text) ->{Console} Text`, `fs.read-lines`. Attenuation is handler interposition and
needs no library support beyond `Handle` itself, though ring 3 ships worked examples:
`fs.read-only`, a handler that forwards `read` and turns `write` into a `Throw`, is
twelve lines and doubles as the tutorial on interposition.

### Workspace facade schemas and calls

GM.9 releases one narrow, typed request facade before any membrane driver or
handler is installed:

```text
workspace.read-file  : (Path) -> Result ToolError Text
workspace.write-file : (Path, Text) -> Result ToolError ()
workspace.fetch      : (Request) -> Result ToolError Response
```

All three operations are `once`. `Path = PathValue(Text)` is the frozen
facade carrier, while `Request`/`Response` remain the existing network
carriers. Merely having Workspace in a row grants no root capability.
Later live/dry layers handle it and may translate an allowed request to raw
authority.

`workspace.operation-spec` maps each member of the closed
`WorkspaceOperation` enumeration to ordinary inspectable data: its resolved
operation identity, canonical name, exact raw-authority envelope, explicit
preconditions, and safe secret references. Read and write declare `Fs`.
Fetch declares the exact ordered `Net, Secret` envelope and carries only
`SecretRef("workspace", None)`; no `Secret` value or exposed text can fit the
spec. `governance.validate-authority` orders blessed effects by the frozen
effect-taxonomy sequence and uses a deterministic hash fallback only for
non-taxonomy identities.

The pure `workspace.call-read`, `workspace.call-write`, and
`workspace.call-fetch` normalizers produce `Result Text GovernanceCall` via
the canonical governance constructor. Each accepts only its typed operation
arguments and recomputes its exact operation spec; there is no public generic
`workspace.call` or `workspace.call-from-spec` path. Preconditions are the
frozen empty `quote {()}` Code. Path wrappers and URLs remain readable. File
contents and request bodies contribute their HASH_V0 digest to argument Code,
so meaningful changes re-key the call without copying body text into the Call
or its deterministic human summary. Call summary text remains presentation
metadata and is excluded from `call-id` by the GM.2 identity contract.

`workspace.summarize-read`, `workspace.summarize-write`, and
`workspace.summarize-fetch` are separate pure typed functions. Success values
contribute canonical payload digests while their human details expose only a
codepoint count, completion label, or HTTP status. Error summaries use the
closed `ToolError` label and omit driver detail. They never use
`debug.inspect` or a generic renderer.

`workspace.dry-layer` and `workspace.live-layer` are the world-free and raw
leaf membranes. `workspace.forward-layer` is the reusable non-leaf membrane:

```text
workspace.forward-layer :
  forall a | e.
  (AuditSequence, BoundPolicy LivePolicy, WorkspaceSimulators,
   () ->{Workspace | e} a)
  ->{State, Judge, GovernanceApprovalV1, Audit, Workspace | e} a
```

It gates each request, re-performs the identical Workspace operation with
unchanged arguments, records `Completed(..., "forwarded", ...)`, and resumes
once. It introduces no `Fs`, `Net`, `Secret`, raw driver, live leaf, or sequence
owner. Compose any number of forwarding layers inside one
`governance.with-sequence`, with exactly one outer `workspace.live-layer` when
real authority is desired. Argument-changing forwarding is not part of this
API because the current Call builders cannot yet attach truthful parent-call
lineage.

`Defect`, the pending owner decision D7 from the exhaustiveness discussion, would
live in this ring as the visible-but-auto-granted channel for invariant violations.
This document assumes it exists for exactly two library uses so far: `observe` at
root, and integer division by zero in `int.div!`'s underlying builtin. Both are
trivially reworded if D7 resolves the other way.

### Audit evidence and handlers

`Audit` is the released ring-3 governance effect. Its sole operation is once
`audit.record : (AuditEntry) -> ()`; the `Evaluated`, `Consented`, and
`Completed` constructors now carry exact `GovernanceVersion` and `Int sequence`
fields. This D69 v2 identity intentionally supersedes the historical ET.2 v1
interface. `audit.in-memory` discharges Audit hermetically and returns the
result paired with entries in occurrence order.

`Hash` is opaque. There is no public unchecked value constructor:
`hash.parse : (Text) -> Result Text Hash` accepts exactly 64 lowercase
hexadecimal digits, and `hash.to-text` returns that unique HASH_V0 spelling.
Short, uppercase, non-hexadecimal, prefixed, and otherwise alternate spellings
are rejected. The marker constructor is absent from both the public name index
and direct derived-hash lookup; the installed OCaml library also exposes
`Hash.t` abstractly. `code.of-hash` preserves the validated digest as a real
`#<digest>` form scalar rather than demoting it back to arbitrary text.

`audit.entry-code : (AuditEntry) ->{} Code` is the standard serialization
path. It builds versioned form data from typed fields. `audit.line-log` renders
that Code as one compact, reparsable form and passes the line plus LF to an
injected append callback. It never uses `debug.inspect`, JSON, or a generic
value renderer. The callback's contract is `(Text) -> Result Text ()`: `Err`
must mean that no bytes were appended. The handler returns `Err` without
resuming, so failures of pre-action `Evaluated` and `Consented` writes are
fail-closed and preserve action ordering.

An `Err` while recording `Completed` is still returned, but the earlier action
has already happened and cannot be rolled back by a log handler. Irreversible
drivers must return a receipt or idempotency key in
`GovernanceOutcomeSummary` so an operator can reconcile the external action
with the audit stream. The handler does not retry implicitly: a retry could
duplicate an append after an ambiguous sink failure.

The current `audit-chain-v2` carrier commits each exact `audit-entry-v2` form to
its predecessor HASH_V0 and publishes a new head. The chain uses
`audit.entry-code`'s compact canonical bytes directly; there is no parallel
AuditEntry serializer. It also enforces the exact contiguous sequence `0, 1, 2,
...`, rejecting duplicate, skipped, decreasing, or negative positions. The fixed
empty head and exact domain-separated digest
contract are specified in [`effect-taxonomy.md`](effect-taxonomy.md).

`jacquard audit genesis` prints the empty head. A single writer uses
`jacquard audit append LOG ENTRY --previous HASH`, persists the returned head
independently, and passes that head to
`jacquard governance verify-log LOG --head HASH` for offline review. The
append command takes a nonblocking advisory whole-file lock and performs its
bounded read, verification, final pathname-identity check, and append through
one open file description; replacement or concurrent-change races fail with
E1306 rather than redirecting the record to a new pathname target. The
verifier rejects reorder, removal, alteration, duplication, sequence gaps,
wrong versions, and
malformed or noncanonical records with diagnostics. Because a chain cannot by
itself reveal removal of a valid suffix, the independently published head is a
required part of the verification contract.

`jacquard governance verify-run BUNDLE` verifies a portable
`governance-run-bundle-v1`: the published Audit head and records plus the exact
Call, policy, assessment, and Proposal artifacts named by those records. It
recomputes their unchanged identities, resolves operation names through the
selected prelude/store, and checks evaluation, consent, completion, and parent
Call relationships. This is an offline review boundary; it does not execute a
driver or prove that an external action occurred.

`jacquard governance reconcile BUNDLE` verifies a
`governance-reconciliation-bundle-v1` around that unchanged run bundle. Its
separate HASH_V0-chained action journal records durable attempts and
receipt digests, then classifies each authorization as unobserved, attempted
with an unknown outcome, waiting for an Audit completion, or fully reconciled.
An exact receipt matches a completion only when its Call, execution branch,
and canonical outcome agree. It enforces the Live/Dry verdict matrix, requires
every live completion to have one unique earlier executable authorization,
accepts the dry gate's `blocked`, `no-simulation`, `simulated`, and
`simulation-failed` completion branches only for their matching dry verdict,
and reports a live completion missing its receipt even when no attempt was
published. Any unresolved state returns E1516; absence of a receipt never
proves that an effect did not occur, and the command never
retries, repairs, compensates, or claims rollback. The Audit and action streams
also have no trusted cross-stream clock. Provider receipt bytes remain outside
the package, but their digests can still reveal equality or permit guesses for
low-entropy inputs and are not a secret-protection mechanism.

### Versioned governance membrane values

GM.1 ships the ordinary ring-3 values consumed by later governed facade
handlers. `GovernanceVersion` is declared in the shared Audit carrier
`prelude/19-audit.jqd` and reused by `prelude/21-governance-core.jqd`. The existing ET.2 `Risk` and
`Verdict` types remain the four-constructor frozen enums. New versioned carriers
use the `governance-*` names where ET.2 or ET.6 already owns an unversioned
public name: `GovernanceVersion`, `ToolError`, `GovernanceAuthority`,
`GovernanceCall`, `GovernanceAssessment`, `GovernanceOutcomeSummary`,
`LivePolicy`, `DryPolicy`, `StoredPolicy`, and `BoundPolicy a`.

The `governance.make-*` and `governance.bind-*` functions are pure smart
constructors returning `Result Text a`. They reject non-finite or out-of-range
confidence thresholds, reversed live-policy limits, empty/noncanonical
operation names, unordered or duplicate authority, resource authority without
its preceding effect authority, and empty resource scopes.
`governance.make-call` accepts the canonical qualified `effect.operation` name,
not a caller-supplied digest. The trusted pure
`governance.resolve-operation-id` boundary locates that exact operation in the
currently resolved Store effect declaration and derives its operation-member
hash; missing effects and members return `Err`. `Call.call-id` is HASH_V0 over
the version, that resolved operation hash, canonical arguments, exact ordered
authority envelope, preconditions, and optional parent call. It deliberately
excludes the qualified display name, summary, and carried ID. Validation
re-resolves the name and rejects a mismatched operation hash before checking
the Call hash. Policy and assessment IDs likewise hash one versioned Code
encoding.

`DryPolicy.min-confidence` remains validated, stored, and identity-bearing
because it is part of the frozen GM.0 carrier schema. It is not a dry verdict
gate: `governance.dry-verdict` returns `Simulate` for every non-`Forbidden` risk
when a simulator exists, returns `NoSimulation` only when it does not, and
always returns `Block` for `Forbidden`.

The kernel has no module-private constructors, and the store privacy primitive
also removes derived-hash lookup needed by already-resolved constructor calls.
Consequently `governance-call-v0` and `bound-policy-v0` remain representable,
while `governance.validate-call` and the two `governance.validate-bound-*`
functions are mandatory verifier backstops at trust boundaries. Forged
hash/value pairs return `Err`; they do not raise. Stable summary functions omit
arguments, preconditions, evidence, authority configuration, digests, driver
details, and all `Secret` values. There is no generic `Show` derivation for
these carriers.

### Judge assessment handlers

GM.5 releases the ring-3 `Judge` effect. Its executable GM.1 carrier spelling
is `assess : (GovernanceCall) -> GovernanceAssessment`, corresponding to the
charter's `Judge.assess : (Call) -> Assessment`. The operation is `once`: one
assessment may resume each captured call at most once.

The standard handlers validate every assessment before resumption. `Risk`,
`List Text` reasons, and `Code` evidence are closed typed fields; the trust
boundary additionally rejects a directly constructed assessment whose
confidence is NaN, infinite, or outside `[0,1]`. Refusal is the explicit
`Throw Text` effect, so validation is never hidden:

```text
judge.rules    : (() ->{Judge, Throw | e} a,
                  (GovernanceCall) ->{} GovernanceAssessment)
                 ->{Throw | e} a
judge.fixed    : (() ->{Judge, Throw | e} a, GovernanceAssessment)
                 ->{Throw | e} a
judge.scripted : (() ->{Judge, Throw | e} a,
                  List GovernanceAssessment)
                 ->{Throw | e} a
judge.model    : (() ->{Infer, Judge, Throw | e} a,
                  (GovernanceCall) ->{Infer} GovernanceAssessment)
                 ->{Infer, Throw | e} a
```

`judge.rules` accepts only a pure rule function; an attempted `Fs`, `Net`,
`Secret`, or other raw-world dependency is a type error rather than authority
laundered behind `Judge`. `judge.fixed` repeats one validated value, while
`judge.scripted` consumes assessments in operation order and throws
`judge.scripted: out of assessments` without resuming when exhausted.
`judge.model` is an explicit `Infer` adapter returning the same v0 point
assessment. Posterior representations, `Dist`, and uncertainty policy belong
to the separate G5 phase.

### Canonical governance proposals

GM.2 adds the successor `GovernanceProposal` carrier in
`prelude/22-governance-identity.jqd` without changing the frozen ET.6
`Proposal` or `Approval` identities. `governance.make-proposal` accepts the
validated `GovernanceCall`, `BoundPolicy LivePolicy`, and
`GovernanceAssessment` values plus the reviewed rendering, summary, and
optional `GovernanceOutcomeSummary`. It derives the call, policy, and
assessment IDs and copies the exact authority envelope from the Call; callers
do not repeat those security-sensitive fields. Its proposal ID is HASH_V0 over
one `governance-proposal-v0` Code value ordered as version, call ID, policy ID,
assessment ID, authority, preview, rendering, and summary. The carried ID is
excluded. `governance.validate-proposal` recomputes that hash, while
`governance.validate-proposal-artifacts` also rejects any call, policy,
assessment, or authority mismatch. All encoding reuses `code.hash` and the GM.1
authority, assessment, policy, and outcome encoders; no second serializer is
introduced.

GM.3 adds the validated execution boundary in
`prelude/23-governance-policy.jqd` without changing any GM.1 or GM.2 carrier or
identity. `governance.validate-{live,dry}-policy` reapply the safe-constructor
checks to directly represented values. Safe StoredPolicy constructors and the
`stored-policy-v0` canonical Code encoding provide one exact HASH_V0 identity
for registry/file values, while `governance.bind-stored-policy` and
`governance.validate-bound-stored-policy` reject forged carried hashes.

Execution uses `governance.live-policy-verdict` and
`governance.dry-policy-verdict`. Both require an exactly validated BoundPolicy.
The live boundary also rejects non-finite or out-of-range observed confidence
as `InvalidDecision`, then applies `Low < Medium < High < Forbidden`, with
Forbidden always blocked and under-confidence never allowed. The dry boundary
always blocks Forbidden; otherwise it returns Simulate exactly when a pure
simulator exists and `NoSimulation` when none exists. It has no Allow or Ask
path and does not reinterpret the retained DryPolicy confidence field as a
gate.

### World-free dry governance gate

GM.6 releases `governance.gate-dry` in
`prelude/24-governance-gate-dry.jqd`. Its checker-visible contract accepts an
`AuditSequence`, exact `BoundPolicy DryPolicy`, validated `GovernanceCall`, pure
simulator thunk, and pure outcome summarizer. It returns the frozen disposition;
the facade clause retains its affine continuation locally:

```text
governance.gate-dry :
  forall a.
  ( AuditSequence
  , BoundPolicy DryPolicy
  , GovernanceCall
  , Option (() ->{} Result ToolError a)
  , (Result ToolError a) ->{} GovernanceOutcomeSummary
  ) ->{State, Judge, Audit} DryDisposition a
```

The gate validates the call and exact bound policy, obtains its assessment
only through `Judge.assess`, and records `Evaluated` before simulation or
refusal. `Forbidden` produces `ToolBlocked`; every other risk either invokes
the pure simulator or produces `NoSimulation`. A simulator's explicit
`DriverFailed` is preserved and never falls through to a live action. The
result is summarized without reflection, `Completed` is recorded, and the
disposition is returned. The facade clause then consumes its locally bound
affine continuation exactly once on ordinary paths.

Malformed directly represented `GovernanceCall` or `BoundPolicy` values are a
defensive precondition refusal: the gate returns `InvalidDecision` before
`Judge`, `Audit`, simulation, summarization, or any live/approval authority.
Such verifier-input refusals are intentionally unaudited because no trustworthy
call ID or policy ID exists to place in an exact AuditEntry.

The simulator and summarizer rows are closed, and the gate's outward row is
closed over only `State`, `Judge`, and `Audit`; it cannot carry `Approval`,
`Secret`, `Eval`, `Fs`, `Net`, or another world effect. The caller supplies the
run-scoped `AuditSequence`; `governance.with-sequence` is the sole API that
installs and discharges its shared `State` effect. Public signatures still
expose only `State` and `Int` positions, while the private handler payload is
`(run-id: Hash, counter: Int)`. Each invocation receives a fresh trusted run
ID, and `next`/`accept` reject a token whose ID differs from the active handler.
The constructor and private generator/check markers are absent from both public
name and derived-hash lookup, including after store reopen; only already-resolved
owner code has the private construction path. Audit refusal is fail-closed.
Failure to record `Evaluated` prevents simulation and summarization; failure to
record `Completed` occurs after simulation but before a disposition can reach
the facade clause.

### Secret references and deliberate exposure

`SecretRef(name: Text, version: Option Text)` identifies confidential material;
it never carries the material itself. `Secret` is an opaque runtime value with
no public constructor, `Show` instance, Code conversion, or Audit encoder. Its
marker constructor is removed from both the public name and derived-hash
indexes. Both `secret.read : (SecretRef) -> Secret` and
`secret.expose : (Secret) -> Text` are `once` operations, so the authority to
obtain plaintext remains visible in the `Secret` effect row.

The standard library deliberately does not invent a credential store or select
a vault provider. `Prelude.install_secret_fixed` supplies deterministic exact
fixtures for hermetic tests. `Prelude.install_secret_vault` accepts an injected
adapter whose closed failure type cannot carry backend text or values.
`--allow secret` is the explicit live grant for the environment adapter; it
looks up collision-free keys derived from the UTF-8 bytes of the safe
`SecretRef`. Dry-run ignores that live grant, installs no Secret handler, and
refuses the remaining row before lookup. Native and interpreter values retain
distinct opaque tags. Generic rendering, runtime errors, traces, and
`debug.inspect` always use the fixed marker `<secret redacted>`. This is an
opacity boundary, not taint tracking: after explicit exposure the result is
ordinary Text and code can copy or leak it. Keep exposure late and typed Audit
inputs separate from plaintext.

### debug.inspect

One reflection escape hatch, because agents debugging themselves need it. This
single line is a signature without its builtin implementation, not a complete
term declaration.

```text
debug.inspect : (a) ->{} Text
```

It prints ordinary values structurally and breaks their abstraction, which is
why it is documented as a debugging tool and banned by convention from library
code. Secret is the hard exception: inspection returns exactly
`<secret redacted>` and never touches its payload.

## 8. Names, versions, and the index

Every convention in one place:

- Dotted lowercase names, subject first: `list.map`, `map.get`.
- Subject-first argument order everywhere; the surface pipe threads the first
  argument, Elixir-fashion, so `xs |> list.map(f) |> list.sort(int.ord)` reads
  left to right without any library change.
- `?` suffix for predicates returning `Bool`. `!` suffix for the `Abort`/`Throw`
  variant of a total function. Both marks are visible at call sites and verified by
  types and rows respectively.
- Full words over abbreviations: `length`, `reverse`, `with-default`.
- The bare verb is the effect-transparent one; there are no `map` versus `mapM`
  splits anywhere in the library.

Because names are metadata over hashes, "the standard library" is precisely a set of
hashes plus a curated name index. Publishing a new version means publishing a new
index; old code keeps referencing old hashes and cannot break. Deprecation is a note
in the index, migration is a semantic diff away, and a rename ships without a major
version, because at the object layer there is no such thing as a breaking rename.

### Executable surface examples

These four examples pin the readability cases found during the surface-syntax
field exercise. They deliberately use the currently shipped prelude names; the
D39 comparison and arithmetic renames are not assumed.

A closed signature can accept a computation carrying two effects while the
outer function remains pure:

```jacquard doctest=stdlib-multi-effect-signature mode=check fixture=stdlib-multi-effect-signature.jac stdout=stdlib-multi-effect-signature.stdout stderr=empty exit=0
type Fleet = | MkFleet

simulate : (Fleet, () ->{Net, Clock} Int) ->{} Int
simulate(fleet, purchase) = 1
```

The pipe threads its left value into the first argument of each current
subject-first library function:

```jacquard doctest=stdlib-pipe-transformation mode=run fixture=stdlib-pipe-transformation.jac stdout=stdlib-pipe-transformation.stdout stderr=empty exit=0
[1, 2, 3] |> list.reverse |> list.reverse
```

A handler can read as policy wrapped around a workflow.
`approval.make-proposal` safely constructs the exact review artifact and
computes its canonical `proposal-v1` hash. All four canonical handlers
recompute that identity before resuming the workflow. `approval.console`
renders the exact hash and ordered authority before prompting;
`approval.scripted` consumes explicit, hash-bound test Decisions;
`approval.policy-auto` approves only a policy verdict already equal to
`Allow`; and `approval.dry-run` always returns `Escalate`, so simulation cannot
fabricate consent:

```jacquard doctest=stdlib-handler-policy mode=run fixture=stdlib-handler-policy.jac stdout=stdlib-handler-policy.stdout stderr=empty exit=0
parsed-hashes = (
  hash.parse("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
  hash.parse("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"),
  hash.parse("cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"))

match parsed-hashes {
  | (Ok(subject-hash), Ok(policy-hash), Ok(assessment-hash)) -> {
      let proposal-value = approval.make-proposal(
        subject-hash,
        policy-hash,
        assessment-hash,
        [],
        quote { "ship" },
        "ship?",
        None)
      let proposal-hash = approval.proposal-id(proposal-value)
      throw.catch(
        fn () -> approval.dry-run(fn () -> match `op:ask`(proposal-value) {
	  | Escalate(returned, _) ->
		  if code.eq?(code.of-hash(returned), code.of-hash(proposal-hash)) then 42 else 0
	  | Approved(_, _, _) -> 0
	  | Denied(_, _, _) -> 0
        }),
        fn (message) -> 0)
    }
  | _ -> 0
}
```

Nested tuple destructuring stays visible inside a constructor pattern:

```jacquard doctest=stdlib-nested-tuple-destructure mode=run fixture=stdlib-nested-tuple-destructure.jac stdout=stdlib-nested-tuple-destructure.stdout stderr=empty exit=0
first-child-head(value) = match value {
  | Some((head, children)) -> head
  | None -> 0
}

first-child-head(Some((7, [8, 9])))
```

## 9. Decisions this document creates or touches

Continuing the dev plan's table:

| ID | Decision | Default assumed here | Needed before |
|----|----------|----------------------|---------------|
| D7 | `Defect` effect, auto-granted | exists, used twice (root `observe`, division builtin) | M2 diagnostics |
| D8 | keep `debug.inspect` | yes, convention-banned in libraries | ring 0 freeze |
| D9 | text unit and grapheme layer | codepoints now, grapheme layer later, no `Char` | ring 2 |
| D10 | `Result e a` argument order (errors left) | as written | ring 0 freeze |
| D11 | `then` as the sequencing verb (over `and-then`, `bind`, `flat-map`) | as written | ring 0 freeze |

## 10. A worked example: everything composing

Word frequency of a line of input, top three by count. Chosen because it crosses all
four rings without ceremony.

```text
count-words : (Text) ->{} Map Text Int
count-words = fn (line) ->
  list.fold(text.split(text.trim(line), " "), map.empty(text.ord),
    fn (acc, w) ->
      map.update(acc, w, fn (n) ->
        Some(option.with-default(option.map(n, fn (k) -> add(k, 1)), 1))))

top : (Map Text Int, Int) ->{} List (Text, Int)
top = fn (m, k) ->
  list.take(list.sort(map.fold(m, Nil, fn (acc, w, n) -> Cons((w, n), acc)),
                      ord.reverse(ord.on-second(int.ord))), k)

main : () ->{Console} ()
main = fn () ->
  list.each(top(count-words(console.ask("text> ")), 3),
    fn (pair) -> println(text.concat(pair.0, text.concat(": ",
                   text.from-int(pair.1)))))
```

This is deliberately pseudocode, retained as an architecture sketch rather than
claimed as implemented source. It uses tuple projections such as `pair.0`, which
the v0 surface grammar does not implement; replacing those projections with tuple
destructuring would be required before promotion to a doctest.
The signatures tell the review story by themselves: two pure functions and one
`Console` function, so `jac run demos/tooling/word-count.jac --allow console` and nothing else. `count-words`
uses the grid three times (`fold`, `update`, `map`) with the exact schemas from §3,
`top` passes dictionaries where ordering is needed and composes them with `ord.
reverse` and `ord.on-second`, and no effect appears anywhere it was not announced.

## 11. Reconciliation with the dev plan

This document supersedes the type and function list inside W2.6. Task mechanics
(loading, hash pinning, DoD) stand unchanged. Ring 0 and the `Abort`/`Throw`/
`State`/`Emit` declarations land in W2.6 as written; their handlers are already the
test subjects of W2.4 and graduate into prelude files there. Ring 2's `Map`/`Set`
and the full `Text` set are new scope, sized M, slotting cleanly between M2 and M3
(they exercise the checker and are needed by `dist.tally`). Ring 3 declarations land
with W2.6 but stay stub-handled until their milestones; `fs.read-only` joins the M4
docs as the interposition tutorial. The laws in §5 become qcheck properties in the
corpus, folded into each ring's landing task.

Ring 0 freezes (names and signatures, not hashes) at the M2 gate, after the checker
has elaborated every signature in this document and proven the notation honest.

## 12. Implementation errata (SL.9)

Collected divergences between this document and the shipped implementation, so the doc
and the code agree in writing. None of these change the design's shape; each is either a
documented approximation or a deliberate narrowing.

**Row erasure generalizes handler payload types.** Effect rows are name-sets: effect
ARGUMENTS are erased, so a payload type does not flow from a perform site to its handler.
This makes the shipped ring-1 handlers looser than their ideal signatures — e.g.
`state.run : forall a b | e. (() ->{State | e} a, b) ->{| e} (a, b)` ties the state type only
to the initial value, so `state.run(fn () -> { put("hi"); get() }, 0)` elaborates as
`(a, Int)` but returns `("hi", "hi")` at runtime. The same holds for `throw.to-result`'s
error type and `emit.collect`'s element type, and it is the long-standing shape of
`eval-code : (Code) -> a`. The future fix direction is parameterized effect instances; until
then the approximation is documented at the checker's `op_scheme`.

**`dist.enumerate` has no error channel.** When every branch is impossible (total mass 0),
the in-language enumerate returns `+nan.0` weights — Jacquard code cannot signal E0901. The
OCaml driver (`jacquard infer enumerate`) reports E0901 for the same model.

**`Map k v` displays as `map.t k v`.** Elaborated signatures print the store name of the
wrapper type; the doc's display-syntax `Map k v` is the same type.

**`--allow fs` is the whole filesystem.** The grant is the only boundary in this draft —
no path confinement. Attenuate with in-language handlers (`fs.read-only`); path-scoped
grants are future work.

**`eval` bypasses interposed handlers.** Eval'd code runs at root authority with a fresh
continuation, so wrapping handlers (including `fs.read-only`) do not attenuate `eval-code`
payloads; only root grants apply. Owner decision pending (M1 note).

**Smaller narrowings.** `text.trim` strips ASCII whitespace only. `uniform-int`
enumeration support caps at 10000 outcomes (pmf and sampling work on any range).
`emit.pipe` forces its callback to return unit (the doc's signature, enforced).
Top-level definitions get closed rows, so passing one where an open row is needed takes an
eta-expansion at the use site (`fn () -> agent()`) — see `infer.scripted`'s cram.
