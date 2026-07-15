# Jacquard Kernel AST — M0, Draft 0.1

Status: proposal for review. Everything here is arguable; the count accounting and open
questions at the end mark where I expect the argument.

---

## 1. The two-layer design

The single most important decision in this document is that "the AST" is two things, cleanly
separated:

**Layer 1: the representation.** Every Jacquard form is one uniform shape, a triple:

```
(head, meta, args)
```

This is Elixir's `{form, meta, args}` generalized. It is what `quote` produces, what macros
will eventually see, what gets serialized, and what gets content-addressed. There is exactly
one shape. A model that learns it has learned the entire physical syntax of the language.

**Layer 2: the grammar.** An ASDL-style refinement over triples that says which heads exist
and what their argument shapes must be. A triple that satisfies the grammar is a *kernel form*;
one that doesn't is just data. This is precisely the relationship Lisp has between
S-expressions (data) and special forms (programs), made explicit and machine-checkable.

Why both layers, given the survey:

- Elixir proved the uniform triple gives Lisp-grade metaprogramming without S-expression
  syntax, and that a three-part shape is enough.
- Python's `Python.asdl` and the WebAssembly spec are the two existence proofs that a formal
  abstract-syntax file keeps a language honest across a decade of evolution.
- Roslyn proved the AST-as-public-API bet pays off, but full-fidelity trees fight
  content-addressing if fidelity lives in the structure. Our answer: fidelity (trivia,
  spans, formatting) lives in `meta`, and `meta` is excluded from hashes. We get
  Roslyn-grade round-tripping and Unison-grade stable identities from the same tree.

## 2. The triple, concretely

```
form   ::= (head, meta, args)
head   ::= symbol                      -- one of the grammar's node names, lowercased
meta   ::= map                        -- open-keyed; see §3
args   ::= list of (form | scalar)
scalar ::= int | real | text | symbol | hash
```

Scalars appear only as leaves inside `args`. Everything else is a triple. Example, the
application `add 1 2` after name resolution:

```
(app, {span: 4:1-4:9},
  [ (ref, {name: "add"}, [#7f3a…, term])
  , (lit, {span: 4:5},   [1])
  , (lit, {span: 4:7},   [2]) ])
```

Note `meta` retains the human name `"add"` for display even though identity is the hash.

## 3. The metadata contract

`meta` is an open map. The kernel defines the semantics of a few reserved keys and guarantees
one law:

**Law: content hashes are computed over the canonicalized tree with `meta` erased.**
Two forms differing only in metadata are the same definition.

Reserved keys (all optional):

| key | contents | why it exists |
|---|---|---|
| `span` | file, line/col range | diagnostics, Elm-grade errors |
| `scopes` | scope-set for identifiers | hygiene, per Racket's sets-of-scopes (Flatt, POPL 2016) |
| `name` | source name for a hash-resolved ref | human/model legibility of resolved trees |
| `trivia` | comments, exact whitespace | full-fidelity round-tripping (Roslyn lesson) without hash instability (Go's CommentMap lesson, learned in the negative) |
| `origin` | provenance record: human id, model id, tool | agent-era requirement: who wrote this node, signable, and it rides outside identity |
| `doc` | attached documentation | docs travel with code |

The `origin` key is the quiet agent-specific move: provenance and even signatures attach to
any subtree without perturbing what the code *is*.

### Trivia encoding and ownership

Surface trivia uses an ordered `List` of atom maps under the reserved keys `trivia`,
`trivia-trailing`, `trivia-inner`, and `trivia-eof`. Each atom has exactly two fields:

```
{kind: layout|comment|doc, text: exact-source-bytes}
```

`layout` includes spaces, tabs, CR/LF bytes, blank lines, and surface semicolon separators.
`comment` and `doc` include the `--` or `--|` introducer and all bytes through, but not including,
the following LF. `doc` metadata uses the same ordered atom representation under `doc`.
`Meta.trivia`, `Meta.docs`, `Meta.with_trivia`, and the append/merge helpers are the decoding and
mutation boundary. They also accept the bootstrap formatter's legacy `Text` and `List [Text ...]`
comment representation, so consumers must not match these values ad hoc.

The metadata retains those source bytes exactly; the canonical printer is not required to replay
layout bytes. Trivia-aware formatting preserves comments, documentation, ordering, and ownership,
but may normalize spaces, tabs, line endings, blank lines, and semicolon separators to canonical
layout. Canonical printing and canonical hashing remain insensitive to every trivia channel.

Ownership is deterministic within the smallest enclosing container. Inter-item trivia leads the
next sibling; a comment after a completed node on the same line trails that node; trivia before a
closing delimiter is `trivia-inner`; and bytes after the last top are `trivia-eof`. A recovered
file supplies a file-level metadata anchor when there is no top (including comment-only files).
Invalid tokens and recovery holes remain boundaries, so ownership never crosses lexical damage,
an arm/clause boundary, or a top-level synchronization point. Consecutive own-line `--|` comments
also appear under `doc` only when their next owner is a signature, definition, type, or effect
declaration. Same-line and orphan doc comments remain ordinary trivia.

## 4. The kernel grammar

ASDL-ish; liberties noted inline. Four sorts: `expr`, `pat`, `type`, `decl`. Auxiliary
products (clause shapes, rows, specs) are structures, not forms, exactly as Python's ASDL
treats `arguments` and `keyword`.

```asdl
-- Jacquard kernel, M0 draft 0.1
-- Every constructor below is realized as a triple (head, meta, args)
-- with head = the constructor name, lowercased.

module Jacquard
{
  expr = Lit(lit value)
       | Var(name id)                        -- local, lexically bound
       | Ref(hash target, refkind kind)      -- resolved global: term, constructor, or effect op
       | Lam(pat* params, expr body)         -- n-ary; params are irrefutable patterns
       | App(expr fn, expr* args)
       | Let(bool rec, pat binder, expr value, expr body)
       | Match(expr scrutinee, clause+ arms) -- exhaustive, checker-enforced
       | Tuple(expr* items)                  -- Tuple([]) is unit
       | Handle(expr body, ret return, opclause* ops)
       | Quote(expr form)                    -- suppress evaluation; yields a Code value
       | Unquote(expr splice)                -- legal only within Quote
       | Ann(expr subject, type ascription)

  pat  = PWild
       | PVar(name id)
       | PLit(lit value)
       | PCon(hash con, pat* args)
       | PTuple(pat* items)
       | PAs(name id, pat inner)

  type = TRef(hash target)
       | TVar(name id)
       | TApp(type head, type* args)
       | TArrow(type* params, row effects, type result)
       | TTuple(type* items)
       | TForall(name* tyvars, name* rowvars, type body)

  decl = DefTerm(binding+ group)             -- a mutually recursive SCC, hashed as a unit
       | DefType(name id, name* vars, conspec+ constructors)
       | DefEffect(name id, name* vars, opspec+ operations)

  -- auxiliary products (structures, not forms)
  clause   = (pat pattern, expr body)
  ret      = (pat binder, expr body)                       -- Handle's return clause
  opclause = (hash op, pat* params, name resume, expr body)
  binding  = (name id, type? annotation, expr value)
  conspec  = (name id, field* fields)
  field    = (name? label, type ty)                        -- labels generate accessor fns
  opmode   = Multi | Once
  opspec   = (name id, opmode mode, type* params, type result)
  row      = (hash* effects, name? var)                    -- effect set + optional row variable
  lit      = Int(int) | Real(real) | Text(text)
  refkind  = Term | Con | Op
}
```

Operation-mode compatibility encoding follows the kernel extension rule: `Multi` is absent in
bootstrap notation and contributes no bytes to `HASH_V0`, so the legacy
`(op name (params...) result)` carrier and every existing hash remain unchanged. `Once` prints as
`(op name once (params...) result)` and appends discriminator byte `0x01` after the result type in
canonical serialization. Explicit `multi` is rejected to keep the absence encoding unique.

**Count: 12 expr + 6 pat + 6 type + 3 decl = 27 forms.** The stated target was roughly 25.
Section 10 names the two cheapest cuts if we want the number exactly.

## 5. Commentary, sort by sort

### 5.1 Expressions

**What is deliberately absent** matters as much as what's present. Four eliminations, each
with a receipt from the survey:

- **No `If`, no primitive `Bool`.** `Bool` is a library data type; `if c then a else b` is
  surface sugar for `Match` over its constructors. Haskell precedent. One fewer branching
  construct for exhaustiveness checking, for tooling, and for a model to learn.
- **No `Seq` / block / statement of any kind.** `e1; e2` desugars to
  `Let(rec=false, PWild, e1, e2)`. This is the whole "expression orientation wins"
  verdict of the survey, enforced by the grammar rather than by convention.
- **No `Perform`.** Effect operations are ordinary values of arrow type whose row names their
  effect, so invoking one is plain `App` of an `Op`-kind `Ref`. Unison's abilities work
  exactly this way. The probabilistic layer inherits this for free: `sample` and `observe`
  are library-declared operations, and **the entire `Dist` story costs zero kernel forms**
  (validated in §8).
- **No guards on match clauses.** Guards weaken exhaustiveness checking, and exhaustiveness
  is a headline feature for code written by models and reviewed by humans. Surface syntax may
  later add guards that desugar; the kernel stays checkable.

Decisions within what remains:

- **`Lam`/`App` are n-ary, not curried.** Judgment call, could flip. Uncurried gives a
  clearer cost model, crisp arity errors, and one obvious place for the effect row on each
  arrow. Unison is curried and makes it work; Koka is uncurried. Currying remains available
  the ordinary way (a lambda returning a lambda). Zero-ary `Lam`/`App` doubles as
  thunk/force, which a strict language needs (§7).
- **`Lam` params are patterns** (commitment: patterns everywhere), restricted to irrefutable
  ones; the checker enforces irrefutability, semantics is `Match`.
- **`Let` carries a `rec` flag** rather than spending a second form. `rec` restricts the
  binder to a variable and the value to a `Lam`. Mutually recursive *local* functions are
  not directly expressible; lift them to a `DefTerm` group, which content-addressing makes
  cheap and natural.
- **`Handle` uses deep handlers with a mandatory return clause.** Deep is the
  Koka/Eff default and the easier one to reason about. Each `opclause` binds the operation's
  arguments as patterns plus a named continuation (`resume`). A `Multi` operation gives it
  ordinary reusable arrow type; a `Once` operation gives it the built-in affine `Resume` type.
  Both use ordinary `App` syntax.
- **`Quote` yields a value of library type `Code`** whose payload is the triple form
  *before* name resolution (macros need names and structure), with hygiene scope-sets in
  `meta`. `eval : Code ->{Eval} a` is a library effect operation, which means evaluation is
  capability-gated like everything else: code can't run code unless something above it
  handles `Eval`. Typing of eval results is a dynamic check at the boundary in M0; typed
  staging (MetaOCaml-style `Code a`) is an open question (§10).
  The source/quote encoding reserves `(surface-ref-v0 con name)` and
  `(surface-ref-v0 op name)` to preserve non-term namespace intent in pre-resolution data.
  `(var name)` remains the legacy unqualified/term-oriented spelling, including its existing
  value-kind fallback for old `.jqd` files. The versioned encoding is a `Form.t` alias decoded
  at expression boundaries to `Var` plus a resolver hint, not a 28th typed kernel form. In
  quoted data it remains structural. Its kind, arity, and argument sorts are validated at every
  quote depth, and metadata remains wholly excluded from identity. The exact compatibility
  grammar and diagnostics are normative in `spec/jacquard-kernel-ast-m0.md` §4.1.
- **`Ann`** exists so bidirectional checking has an anchor and so a model can state intent
  inline. Signatures carrying the whole story is the design thesis; `Ann` is its local form.

### 5.2 Patterns

The ML lesson, adopted whole: patterns are a first-class sort appearing in `Lam`, `Let`,
`Match`, `Handle` clauses. `PCon` references constructors by hash (a constructor reference is
canonically the type's hash plus the constructor's ordinal; the grammar folds this into
`hash`). `PAs` (as-patterns) is the one convenience admitted; it costs a form and does not
weaken exhaustiveness. Or-patterns and guards are deliberately out.

`Match` exhaustiveness is a checker obligation, and with no null in the language (the
survey's unanimous verdict) and no guards, exhaustiveness is actually decidable and honest.
The only escape from a match is an effect (an `Abort`-style operation), which the signature
then displays. Nothing fails silently; everything that can fail says so in its row.

### 5.3 Types

Small and structural. The load-bearing form is `TArrow(params, row, result)`: **the effect
row lives on the arrow**, Unison/Koka style, because "a function's signature carries its
entire story" is the design thesis and the row is most of the story. Pure functions have
the empty row. `TForall` binds type variables and row variables together; row polymorphism
is what lets higher-order functions say "I perform whatever my argument performs."

Ergonomics warning, inherited from Koka's scars: full row *inference* in the surface language
is mandatory. Humans and models should rarely write rows; they should always be able to
*read* them, fully elaborated, in displayed signatures. Inference for writing, elaboration
for reading.

Records beyond labeled constructor fields (true row-typed records) are deferred; `field`
labels on `DefType` constructors generate accessor functions at zero kernel cost, which
covers the common case.

### 5.4 Declarations

Three forms, and the third is where two commitments become one mechanism:

- **`DefTerm` takes a mutually recursive group**, because content-addressing forces it:
  a definition cannot contain its own hash. Unison's solution, adopted here: hash the
  strongly connected component as a unit, members in canonical order, self-references as
  bound indices (§6).
- **`DefType`** declares sums with optionally-labeled fields. Constructors are not forms;
  they are references (`Con`-kind) applied with ordinary `App`.
- **`DefEffect`** declares an effect and its operations' signatures. This single form is
  the doorway for IO, `Abort`, `Eval`, and `Dist` alike. Capabilities need **no** kernel
  surface at all: an effect names *what* a computation does; whether it *may* is decided
  by which handlers exist above it, and the runtime installs root handlers only for
  granted authorities. No ambient handlers, no ambient authority. Attenuation is handler
  interposition (wrap the child in a filtering handler). §10 flags the granularity caveat.

There is no module form. A codebase is a content-addressed map from hashes to declarations;
names, namespaces, and renames are metadata operations that never touch identity. This is
the Unison move, and it is what makes agent loops cacheable: re-typecheck and re-test keyed
on hashes, and an edit invalidates exactly its dependents.

## 6. Content addressing: the canonicalization pipeline

```
surface text
  └─ parse ─────────▶ triple form (names, trivia, spans in meta)
       └─ expand ───▶ triple form (macro-free; hygiene resolved via scope sets)
            └─ resolve ─▶ kernel form (Var for locals, Ref(hash) for globals)
                 └─ canonicalize ─▶ hash input
```

Canonicalization rules:

1. Erase all `meta`.
2. Replace local names with de Bruijn indices (alpha-invariance).
3. Hash `DefTerm` SCCs as a unit: order members canonically (by structure, ties broken
   deterministically), represent in-group references as bound indices, then hash;
   each member's individual hash is the group hash plus its index. (Unison's cycle
   treatment.)
4. Constructor and operation references canonicalize to (declaration hash, ordinal).
5. Serialize the canonical tree deterministically; hash with a fixed function
   (BLAKE3 is the working assumption; a named constant in the spec, not a commitment).

Consequences worth saying out loud: renames are free and history-preserving; formatting
and comments never dirty a build; a semantic differ falls out of comparing trees rather
than text; and provenance/signatures ride in `meta` at any granularity without forking
identities.

## 7. Semantic commitments the grammar assumes

The grammar only means something against these, so they're pinned here even though M0 is
a syntax document:

- **Strict, left-to-right evaluation.** The Haskell verdict: laziness bought composability
  and paid in space leaks nobody could predict. For agent-written code, predictability wins.
  Laziness on demand is zero-ary `Lam` (thunk) and zero-ary `App` (force), and a delayed
  computation's type honestly displays its row: `() ->{IO} a` is Unison's `'{IO} a` without
  new syntax.
- **Deep handlers with explicit resumption modes.** Multi-shot is not a luxury for `Multi`
  operations: exact enumeration inference for `Dist` resumes a reusable continuation once per
  element of a distribution's support. Resource-bearing `Once` operations instead expose an
  affine `Resume` that may be consumed at most once per possible path, with a per-instance
  runtime backstop. This is the standard effects-and-PPL construction with a linearity boundary.
  Honest correction to the earlier plan: **OCaml 5's native effect handlers are one-shot**, so
  the interpreter cannot lean on them directly for `Multi`. It uses CPS/defunctionalized
  continuations, retaining reusable values for `Multi` and guarded affine values for `Once`.
  OCaml remains a fine host; the free lunch just isn't there.
- **Exhaustive `Match`, no null, no exceptions.** Failure is an effect with a row entry.
- **No ambient handlers.** The runtime's root handler set is exactly the program's granted
  capabilities; `main`'s signature is the program's authority manifest.

## 8. Validation: the kernel eating its own cooking

**Bool and `if`** (surface, then kernel):

```
type Bool = False | True

if c then a else b
  ≡ Match(c, [ (PCon(#Bool.True,  []), a)
             , (PCon(#Bool.False, []), b) ])
```

**The entire probabilistic layer, declared with no new forms:**

```
type Distribution a = ...          -- library data: Bernoulli, Categorical, Normal, ...

multi effect Dist where
  sample  : Distribution a -> a
  observe : Distribution a -> a -> ()
```

which is one `DefType` and one `DefEffect`. A model is any expression whose row includes
`Dist`. An inference algorithm is a `Handle`: the enumeration handler resumes per support
element and weights; an SMC or gradient handler is a different `Handle` around the same
untouched model. Your fields intuition lands here too: composing two models multiplies
their weight functions, and the handler is where superposition becomes a posterior.

**Homoiconicity check.** `sample (bernoulli 0.5)` as its quoted triple:

```
(app, {},
  [ (ref, {name: "sample"}, [#d4c1…, op])
  , (app, {},
      [ (ref, {name: "bernoulli"}, [#99e0…, term])
      , (lit, {}, [0.5]) ]) ])
```

One shape, all the way down. That uniformity is also the answer to the zero-training-data
risk: there is very little language to learn.

## 9. What M0 deliberately excludes

Records with row types; guards and or-patterns; ad-hoc polymorphism (traits/classes);
macros beyond quote/unquote/eval; typed staging; numeric tower; ownership (GC assumed);
any performance story. Exclusion here means "not in the kernel grammar yet," not "never."

## 10. Open questions and honest flags

1. **The count is 27, not 25.** Cheapest cuts if the number matters: drop `PAs`
   (ergonomics only) and `TTuple` (encode as `TApp` of built-in tuple constructors).
   I'd keep both and let the target flex; forms should earn their place, and these do.
2. **Uncurried could flip.** If early macro or pipeline ergonomics favor currying, the
   change is contained: `Lam`/`App`/`TArrow` arities and the row placement convention.
   Decide before M2 (the checker), cheap before then.
3. **Ad-hoc polymorphism is the largest deferred design.** OCaml's biggest regret in the
   survey (`+.` forever). Options when it lands: Rust-style traits, modular implicits,
   or something abilities-flavored. It will touch `TForall` and `DefTerm` annotations.
4. **Typed staging.** `Code` is untyped in M0 and `eval` is dynamically checked at the
   boundary. Fine for a kernel; not fine forever if macros become central.
5. **Capability granularity.** Effects-as-capabilities controls authority per handled
   *region*, which is coarser than per-*value* object capabilities: within a region that
   handles `Net`, any callee can perform `Net`. Handler interposition (attenuating
   wrappers) covers much of the gap. If finer control proves necessary, capability
   *values* threaded as arguments compose with this design without new forms. Watch it
   in practice before adding machinery.
6. **Multi-shot performance.** CPS interpreters pay for resumability. Irrelevant at M1
   scale; a known cliff later (selective CPS and one-shot fast paths are the standard
   escape hatches).
7. **Row inference ergonomics** is a make-or-break surface-language obligation (Koka's
   scar). The kernel is ready for it; the checker has to deliver it.

## 11. Provenance of the design, in one paragraph

The triple is Elixir's. The grammar-as-ASDL discipline is Python's and WebAssembly's.
Hygiene is Racket's scope sets. Effects and their placement on arrows are Unison's and
Koka's; operations-as-functions is Unison's specifically. Content-addressing, cycle
hashing, and the nameless codebase are Unison's. Exhaustive matching and first-class
patterns are the ML family's. No-null is the survey's unanimous verdict. Strictness is
Haskell's lesson learned in the negative. Full fidelity in metadata is Roslyn's lesson
routed around Go's comment-map mistake. The zero-cost probabilistic layer is the
effects-and-PPL literature made load-bearing. What's ours is the combination, plus the
metadata contract that lets provenance and fidelity ride outside identity.
