# The Weft Standard Library — Design, Draft 0.1

Companion to the kernel spec, the whitepaper, and the dev plan. This document
supersedes the prelude sketch in dev plan task W2.6; a reconciliation table sits at
the end.

Signature notation used throughout (display form, per the checker's elaborated
output): `name : (args) ->{row} result`. An empty row `->{}` means pure. An open row
`->{Abort | e}` means Abort plus whatever `e` turns out to be. This is documentation
notation; source remains bootstrap s-expressions until a surface language exists.

---

## 1. What beauty means here

A standard library is the vocabulary a language actually speaks, and for Weft the
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
4. **Handlers ship with effects.** An effect declaration without its canonical
   handlers is a hole. Every effect in this library arrives with the handlers that
   discharge it, so the library teaches its own control flow.
5. **Combinators are row-transparent.** A higher-order function performs what its
   argument performs and nothing else. `for-each` with a pure function is pure; the
   same `for-each` with `println` carries `Console`. The library never hides an
   effect and never adds one.

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
| 3 | World | `Console`, `Clock`, `Fs`, `Net`, `Eval`; root handlers installed only by the runtime under grants | authority; these rows in `main` are the program's manifest |

The placement of `Dist` in ring 2 is a deliberate statement: inference is pure.
Enumeration needs no world at all, and likelihood weighting needs only a seed, which
is a number. Only entropy acquisition (a fresh seed) touches ring 3.

Naming convention: dotted lowercase, `list.map`, `text.split`, subject type first.
Names live in the metadata index, so all of this is curation rather than structure,
and renames are free (§8 returns to what that buys).

## 3. Ring 0: the axioms

### Core types

```
type Bool      = False | True
type Ordering  = Less | Equal | Greater
type Option a  = None | Some a
type Result e a = Err e | Ok a          -- errors on the left
type List a    = Nil | Cons a (List a)
```

`Unit` is the empty tuple `()`, native to the kernel. Pairs and wider products are
kernel tuples. There is no `Char` in this draft (§9, D9).

### Dictionaries: ad-hoc polymorphism, honestly deferred

Weft has no traits yet (kernel spec §10.3), and the library refuses to fake them
with builtin structural equality, which OCaml regrets, or compiler-magic
`comparable`, which Elm regrets. Instead, capabilities like equality are ordinary
values: single-constructor data with labeled fields, passed explicitly.

```
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

Uniform schemas, with `List` as the exemplar:

```
list.map    : (List a, (a) ->{e} b) ->{e} List b
list.filter : (List a, (a) ->{e} Bool) ->{e} List a
list.fold   : (List a, b, (b, a) ->{e} b) ->{e} b
list.each   : (List a, (a) ->{e} ()) ->{e} ()
```

Note every one of these accepts an effectful function and threads its row through
untouched, per principle 5. There is no separate `mapM`; the map is the map.

### List, the rest of it

```
list.head     : (List a) ->{} Option a          list.head!    : (List a) ->{Abort} a
list.last     : (List a) ->{} Option a          list.nth      : (List a, Int) ->{} Option a
list.reverse  : (List a) ->{} List a            list.append   : (List a, List a) ->{} List a
list.concat   : (List (List a)) ->{} List a     list.range    : (Int, Int) ->{} List Int
list.zip      : (List a, List b) ->{} List (a, b)
list.sort     : (List a, Ord a) ->{} List a      -- stable
list.contains?: (List a, a, Eq a) ->{} Bool
list.find     : (List a, (a) ->{e} Bool) ->{e} Option a
```

### Option and Result

```
option.map          : (Option a, (a) ->{e} b) ->{e} Option b
option.then         : (Option a, (a) ->{e} Option b) ->{e} Option b
option.with-default : (Option a, a) ->{} a
option.get!         : (Option a) ->{Abort} a

result.map        : (Result e a, (a) ->{f} b) ->{f} Result e b
result.map-error  : (Result e a, (e) ->{f} d) ->{f} Result d a
result.then       : (Result e a, (a) ->{f} Result e b) ->{f} Result e b
result.with-default : (Result e a, a) ->{} a
result.get!       : (Result e a) ->{Throw e} a
result.of-option  : (Option a, e) ->{} Result e a
option.of-result  : (Result e a) ->{} Option a
```

`then` is the sequencing verb (Elm's `andThen`, Rust's `and_then`); the word `bind`
is avoided as jargon, and there is no monad abstraction to name because there is no
mechanism to abstract it with yet. When traits land, `then` is the method they will
collect.

### Bool, strictly

Weft is strict, so `bool.and : (Bool, Bool) ->{} Bool` evaluates both arguments.
The short-circuit forms take thunks and say so in their types:

```
bool.and-then : (Bool, () ->{e} Bool) ->{e} Bool
bool.or-else  : (Bool, () ->{e} Bool) ->{e} Bool
```

A future surface `&&` desugars to `match`, costing nothing. Until then the library
refuses to pretend strict application short-circuits.

## 4. Ring 1: control effects and their handlers

Four effects cover pure control. Each is shown with its declaration and the handlers
it ships with. An idiom appears here worth naming once: an operation whose handler
never resumes may promise any result type, so `abort : () -> a` needs no bottom type.

```
effect Abort where  abort : () -> a
effect Throw e where throw : (e) -> a
effect State s where get : () -> s
                     put : (s) -> ()
effect Emit w where  emit : (w) -> ()
```

Canonical handlers:

```
abort.to-option : (() ->{Abort | e} a) ->{e} Option a
abort.or        : (() ->{Abort | e} a, a) ->{e} a
throw.to-result : (() ->{Throw err | e} a) ->{e} Result err a
throw.catch     : (() ->{Throw err | e} a, (err) ->{e} a) ->{e} a
state.run       : (() ->{State s | e} a, s) ->{e} (a, s)
state.eval      : (() ->{State s | e} a, s) ->{e} a
emit.collect    : (() ->{Emit w | e} a) ->{e} (a, List w)
emit.pipe       : (() ->{Emit w | e} a, (w) ->{e} ()) ->{e} a
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
| error | `result.get! : (Result e a) ->{Throw e} a` | `throw.to-result` |

The border is lawful, and the laws are corpus property tests, deliberately phrased
as round trips:

```
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

```
text.length   : (Text) ->{} Int                 text.concat  : (Text, Text) ->{} Text
text.join     : (List Text, Text) ->{} Text     text.split   : (Text, Text) ->{} List Text
text.slice    : (Text, Int, Int) ->{} Text      text.trim    : (Text) ->{} Text
text.contains?: (Text, Text) ->{} Bool          text.empty?  : (Text) ->{} Bool
text.from-int : (Int) ->{} Text                 text.to-int  : (Text) ->{} Option Int
text.from-real: (Real) ->{} Text                text.to-real : (Text) ->{} Option Real
```

### Map and Set

Ordered structures parameterized by a dictionary at construction; the dictionary is
stored inside the value, so it is supplied exactly once and cannot be mixed up
afterwards.

```
map.empty : (Ord k) ->{} Map k v
map.set   : (Map k v, k, v) ->{} Map k v
map.get   : (Map k v, k) ->{} Option v
map.update: (Map k v, k, (Option v) ->{e} Option v) ->{e} Map k v
map.fold  : (Map k v, b, (b, k, v) ->{e} b) ->{e} b
map.size  : (Map k v) ->{} Int
set.empty : (Ord a) ->{} Set a                   -- insert, member?, fold, size
```

### Dist

The declarations from the whitepaper, verbatim, plus the pure inference handlers.
Discrete only in this draft, matching milestone M3.

```
type Distribution a = Bernoulli Real
                    | Categorical (List (a, Real))
                    | UniformInt Int Int

effect Dist where  sample  : (Distribution a) -> a
                   observe : (Distribution a, a) -> ()

dist.pmf        : (Distribution a, a, Eq a) ->{} Real
dist.enumerate  : (() ->{Dist | e} a) ->{e} List (a, Real)     -- normalized, unmerged
dist.tally      : (List (a, Real), Eq a) ->{} List (a, Real)   -- merge equal outcomes
dist.sample-lw  : (() ->{Dist | e} a, Int, Int) ->{e} List (a, Real)  -- seed, count
```

Enumeration returns an unmerged weighted list so that it needs no equality; merging
is a separate step that asks for its `Eq` honestly. There is no separate random
number library. `sample(UniformInt(1, 6))` under the sampling handler is the die
roll, and randomness is just `Dist` without `observe`, one story instead of two.
Granting `Dist` at the root installs the entropy-seeded sampling handler; an
`observe` reaching the root is an error, since conditioning requires an inference
handler and the root has nothing to condition.

## 7. Ring 3: the world

World effects are declared like any other; what distinguishes them is that only the
runtime installs their root handlers, under explicit grants. The row of `main` is
the program's authority manifest, and this table is what a reviewer is reading when
they read it:

| effect | operations | granting it means |
|--------|------------|-------------------|
| `Console` | `print : (Text) -> ()`, `read-line : () -> Text` | the program talks to the terminal |
| `Clock` | `now : () -> Int` (ms since epoch), `sleep : (Int) -> ()` | the program observes and waits on time |
| `Fs` | `read : (Text) -> Text`, `write : (Text, Text) -> ()`, `list-dir : (Text) -> List Text` | the program touches the filesystem |
| `Net` | `fetch : (Request) -> Response` | the program reaches the network |
| `Eval` | `eval : (Code) -> a` | the program runs code, including code it constructed |

Convenience functions build on the ops in ordinary code: `println`, `console.ask :
(Text) ->{Console} Text`, `fs.read-lines`. Attenuation is handler interposition and
needs no library support beyond `Handle` itself, though ring 3 ships worked examples:
`fs.read-only`, a handler that forwards `read` and turns `write` into a `Throw`, is
twelve lines and doubles as the tutorial on interposition.

`Defect`, the pending owner decision D7 from the exhaustiveness discussion, would
live in this ring as the visible-but-auto-granted channel for invariant violations.
This document assumes it exists for exactly two library uses so far: `observe` at
root, and integer division by zero in `int.div!`'s underlying builtin. Both are
trivially reworded if D7 resolves the other way.

### debug.inspect

One reflection escape hatch, because agents debugging themselves need it:

```
debug.inspect : (a) ->{} Text
```

It ignores abstraction, prints anything structurally, and breaks parametricity,
which is why it is documented as a debugging tool, banned by convention from
appearing in library code, and flagged as owner decision D8 in case even this is
too much hole.

## 8. Names, versions, and the index

Every convention in one place:

- Dotted lowercase names, subject first: `list.map`, `map.get`.
- Subject-first argument order everywhere; the future surface pipe threads the first
  argument, Elixir-fashion, so `xs |> list.map(f) |> list.sort(int.ord)` will read
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

```
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

(Display syntax for readability; the corpus versions are bootstrap s-expressions.)
The signatures tell the review story by themselves: two pure functions and one
`Console` function, so `weft run --allow Console` and nothing else. `count-words`
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
