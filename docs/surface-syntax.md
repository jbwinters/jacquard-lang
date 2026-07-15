# Jacquard Surface Syntax — Design and Implemented Charter

Companion to the kernel spec, stdlib design, testing framework, package manager
CLI, and the native compilation plan. This document decides whether Jacquard
gets a human-facing syntax, what it optimizes for, and what it looks like,
form by form, with the desugaring of each.

Short version: yes, after task 74, printer-first, delimiter-based, and one
infix operator total. Executable display examples migrate to this grammar and
become doctests when it lands; deliberately schematic snippets stay labeled
as pseudocode rather than being claimed as compilable source.

Draft 0.2 folds in the first field feedback: two independent implementations
translated an existing kernel-level program plus the full demo corpus, and
wrote two new programs directly against Draft 0.1, before any parser work
began. Nine gaps would have blocked a parser (§4-§5); the load-bearing ones
among them are now decisions D34-D40 in §10. Five more are printer/formatter
exactness questions (§5); the rest is prelude pressure and two diagnostics,
both out of scope for a syntax document. None of it reopened the delimiter
stance, the single operator, or printer-first — the spine held across
roughly 1,900 lines written by two different models.

## 0. Implementation charter

Draft 0.2 supplied the reviewed design for the completed SS.0-SS.22
implementation arc. This document now records both that design and the exact
shipped boundary; it is not a claim that the whole surface grammar is stable or
frozen. Decisions D27-D40 in section 10 remain the design record, with D36
formally partial as described below. Any later revision must record and review
its decision change rather than quietly choosing different syntax.

This work is post-0.1 and follows the completed native differential harness
(task 74). It is a projection onto the existing kernel, not a kernel revision.
In particular, it does not change the 27 kernel forms, canonical serialization,
HASH_V0, store objects, evaluator semantics, native semantics, or permanent
support for bootstrap `.jqd` files. D38 and D39 completed in SS.22 as
standard-library work without expanding the grammar. D36 generated accessors,
D36 label validation, and Tier-F remain separate follow-ups.

There is one explicit compatibility reservation in the generic pre-resolution form layer:
`(surface-ref-v0 con name)` and `(surface-ref-v0 op name)`. Surface lowering uses these forms to
retain constructor/operation intent in quoted data. They are accepted reserved `Form.t` aliases,
not typed AST constructors, so the kernel count remains 27 and the canonical V0 format is unchanged.

The implementation gates are:

```sh
eval "$(opam env)"
opam exec -- dune build @all
opam exec -- dune runtest
opam exec -- dune fmt
git diff --exit-code
```

Surface-specific gates additionally prove printer totality, formatter
idempotence, `.jac`/`.jqd` hash equivalence, documentation doctests, and at
least one public `.jac` demo. The surface release memo records those commands
and the status of laws L1-L7 before `.jac` is advertised as supported.

### One-page grammar

This summary is intentionally compact. It is both the implementation handout
and the L7 grammar-growth tripwire.

```text
file          := seps? [top-item (seps top-item)*] seps?
top-item      := signature | definition | type-decl | effect-decl | expr | raw-top
signature     := term-name ":" cont type
definition    := term-name ["(" patterns? ")"] "=" cont expr
type-decl     := "type" type-name type-vars? "=" cont "|"? constructor (seps? "|" cont constructor)*
constructor   := con-name type-atom*
| con-name "(" fields? ")"
field         := [term-name ":" cont] type
effect-decl   := "effect" effect-name type-vars? "where" "{" seps? op-signature (seps op-signature)* seps? "}"
op-signature  := op-name ":" cont "(" types? ")" "->" cont type
raw-top       := "jqd" raw-bootstrap-form

expr          := call (cont "|>" cont call)*
call          := primary ("(" exprs? ")")*
primary       := literal | value-name | internal-ref | paren | tuple | list | block | fn
| match | if | handle | quote | unquote | annotation
paren         := "(" expr ")"
tuple         := "()" | "(" expr "," exprs? ")"
list          := "[" exprs? "]"
block         := "{" seps? block-item (seps block-item)* seps? "}"
block-item    := "let" ["rec"] pattern ["(" patterns? ")"] "=" cont expr | expr
fn            := "fn" "(" patterns? ")" "->" cont expr
match         := "match" expr "{" seps? match-arm (seps? match-arm)* seps? "}"
match-arm     := "|" pattern "->" cont arm-body
if            := "if" expr cont "then" cont expr cont "else" cont expr
handle        := "handle" (atomic | block) "{" seps? return-clause (seps? op-clause)* seps? "}"
atomic        := literal | value-name | atomic-call
atomic-call   := value-name "(" exprs? ")" ("(" exprs? ")")*
return-clause := "|" "return" pattern "->" cont arm-body
op-clause     := "|" op-name "(" patterns? ")" "resume" resume-name "->" cont arm-body
quote         := "quote" "{" seps? (expr | raw-form) seps? "}"
raw-form      := "jqd" raw-bootstrap-form
internal-ref  := "#group[" unsigned-integer "]"
unquote       := "unquote" "(" expr ")"
annotation    := "(" expr ":" cont type ")"
arm-body      := expr | block

pattern       := pattern-atom ["as" binding-name]
pattern-atom  := "_" | binding-name | literal | con-name ["(" patterns? ")"]
| "(" patterns? ")"
type          := type-app | "(" types? ")" row cont type
| "forall" forall-vars? "." cont type
type-app      := type-atom type-atom*
type-atom     := type-name | type-var | "()" | "(" type ")"
| "(" type "," ")" | "(" types ")"
row           := "->{" cont effects? [cont "|" cont row-var] cont "}"
patterns      := pattern ("," pattern)*
fields        := field ("," field)*
types         := type ("," type)*
exprs         := expr ("," expr)*
effects       := effect-name ("," cont effect-name)*
type-vars     := type-var+
row-vars      := row-var+
forall-vars   := type-vars ["|" row-vars] | "|" row-vars

binding-name  := lower-name | escaped-term
resume-name   := binding-name | "_"
value-name    := lower-name | upper-name | escaped-term | escaped-con
| escaped-op | hash-term | hash-con | hash-op
term-name     := lower-name | escaped-term | hash-term
op-name       := lower-name | escaped-op | hash-op
type-name     := upper-name | escaped-type | hash-type
con-name      := upper-name | escaped-con | hash-con
effect-name   := upper-name | escaped-effect | hash-effect
type-var      := lower-name | escaped-tvar
row-var       := lower-name | escaped-rvar
name-part     := [a-z][a-z0-9]* ("-" [a-z][a-z0-9]*)*
lower-name    := name-part ("." name-part)* ["?" | "!"]
upper-name    := [A-Z] ([a-z0-9]* [A-Z])* [a-z0-9]*
kernel-name   := a symbol accepted by Reader.valid_symbol
escaped-term  := "`term:" kernel-name "`"
escaped-op    := "`op:" kernel-name "`"
escaped-type  := "`type:" kernel-name "`"
escaped-con   := "`con:" kernel-name "`"
escaped-effect:= "`effect:" kernel-name "`"
escaped-tvar  := "`tvar:" kernel-name "`"
escaped-rvar  := "`rvar:" kernel-name "`"
hash-term     := hash ":term"
hash-op       := hash ":op"
hash-type     := hash ":type"
hash-con      := hash ":con"
hash-effect   := hash ":effect"
hash          := "#" hex-digit{64}
literal       := integer | real | special-real | string
integer       := "-"? unsigned-integer
unsigned-integer := [0-9]+
real          := "-"? unsigned-integer ("." [0-9]* ([eE] [+-]? unsigned-integer)? | [eE] [+-]? unsigned-integer)
special-real  := "+inf.0" | "-inf.0" | "+nan.0" | "-nan.0"
string        := '"' (UTF-8-scalar | "\\" ["\\" | '"' | "n" | "t" | "r"] | "\\x" hex-digit hex-digit)* '"'
comment       := "--" characters-to-newline
doc-comment   := "--|" characters-to-newline
sep           := newline | ";"
seps          := sep+
cont          := newline*
raw-bootstrap-form := "{" balanced bytes for exactly one Reader.parse_one form "}"
```

The lexer emits newlines. `seps` consumes them where they separate top-level
or block items; `cont` consumes them only after an explicit continuation token
such as `=`, `:`, `->`, `then`, `else`, `|>`, a row comma/bar, or `forall .`.
Parenthesized/bracketed lists treat newlines as whitespace.
Leading and trailing separators are legal inside braced item/clause lists and
quote bodies. Indentation never carries meaning.

Spaces and tabs are skipped outside strings and raw mode. `--|` is recognized
before `--`; both consume through (but not including) the newline, so that
newline remains available as a separator. `hex-digit`, `UTF-8-scalar`,
`characters-to-newline`, and `newline` are lexical primitives with their
ordinary meanings. Strings use exactly the escapes accepted by the bootstrap
reader.

The lexer does not expose whitespace tokens. After parsing, byte gaps between its existing
significant, comment, newline, separator, invalid, and EOF spans are partitioned into the structured
metadata atoms specified in `ast.md` §3. This keeps parser lookahead unchanged while retaining exact
spaces, tabs, CRLF/LF, blank lines, semicolons, and comment bytes. Leading trivia belongs to the next
sibling in its container; a same-line comment after a completed node belongs to that node; closing
delimiter trivia belongs to the container; and final bytes belong to the last top or the file anchor.
Recovery tokens and holes are hard ownership boundaries.

The escaped and hash productions are printer fallbacks. They preserve legal
kernel names that are keywords or do not round-trip through D34, and resolved
references whose display metadata is unavailable. Canonical source uses
ordinary names. `#group[n]` preserves an internal `GroupRef`. `jqd { ... }`
enters a raw mode that balances bootstrap parentheses/strings/comments and
then requires exactly one form from `Reader.parse_one`; it preserves arbitrary
`DefTerm` grouping and quoted triples. It is an inversion escape, not general
mixed-syntax authoring.

For constructors, unlabeled fields print with whitespace (`Some a`,
`Pair a b`). If any field is labeled, all fields print in parentheses and
only labeled fields carry a colon (`MkFleet(inv: SvcMood, pay: SvcMood)`).
The parser accepts exactly those two shapes; `Some(a)` is not a second
canonical spelling for `Some a`.

Names make pattern intent explicit: `Up` is a constructor pattern while `up`
is a fresh binding pattern. Labeled-field declarations ship, while generated
accessors remain a D36 follow-up:

```jacquard
type Fleet = | MkFleet(inv: SvcMood, pay: SvcMood, shp: SvcMood)
-- fleet.inv(fleet) is not generated by the current implementation
```

Effect parameters may be unused by an operation:

```jacquard
effect Choice a where {
  choose : () -> Bool
}
```

An operation clause that aborts writes an intentionally unreferenceable
continuation binder:

```jacquard
handle risky() {
  | return x -> Some(x)
  | abort() resume _ -> None
}
```

Non-atomic handled bodies use the unambiguous two-brace form, and a bare
top-level expression remains a top-level item:

```jacquard
handle { match direction { | Up -> risky() | up -> fallback(up) } } {
  | return x -> x
  | abort() resume _ -> None
}
```

Dotted names are atomic and may share a root with a local binding:

```jacquard
inspect(code) = code.un-form(eval-code(code))
```

## 1. Whether, and when

The machine does not need this. The kernel, the corpus, the differential
harness, and the native backend run on s-expression bootstrap files today and
would forever. The need is external contact: the registry's web pages, the
README, a contributor reading a diff, a reviewer approving an agent's patch.
Every one of those is a person looking at code, and each one pays the
s-expression tax.

So the trigger is the registry and the contributor story, and the slot is
after task 74 (the differential harness as CI law), for two reasons. The
harness is the right verification substrate for syntax: surface and bootstrap
twins of every corpus program must produce identical hashes, which turns the
projection laws below into CI checks. And the native backend is the current
critical path; syntax work before 74 stabilizes would compete for the same
attention.

One compounding payoff worth naming: the display notation used throughout the
stdlib, testing, and package manager docs is the starting point for the real
grammar. Phase S3 migrates every executable example to its canonical spelling
and makes it a doctest; non-executable type sketches are marked explicitly.

## 2. The inversion that drives the design

Prior surface languages were designed writer-first, because the writer was a
person. Jacquard's thesis says models write most code and people review it,
which inverts the methodology:

**The surface is primarily a rendering, secondarily an input format.** The
grammar is therefore defined printer-first: the canonical printer (the M4
formatter, extended) defines what Jacquard code looks like, and the parser's
job is to invert the printer, plus tolerate human and model sloppiness that
the formatter then normalizes away.

**Text files are carriers, not truth.** The hash is computed from the tree,
always. A `.jac` file is a faithful transport of a tree through git, an
editor, or a chat window. The laws in §3 are what make that safe.

**The parser must recover.** Model-generated text arrives malformed at some
rate. The parser produces the best partial tree it can, with explicit hole
forms at damage sites, so diagnostics can say "expected a pattern here" with
a span instead of giving up at the first bad token. For an agent loop, the
quality of the error on malformed input is a feature with a feedback-loop
multiplier on it.

## 3. Laws

Each is a CI property, not a goal.

- **L1, printer totality and inversion.** `parse(print(k)) ~= k` for every
  kernel tree `k`, where `~=` is structural equality after erasing metadata
  (`Form.equal_ignoring_meta`, lifted through `Kernel.to_form`). Spans,
  provenance, and other non-surface metadata cannot be reconstructed from
  rendered text; supported surface trivia/provenance has the stronger L5/L6
  obligations below. Every kernel form has a surface rendering; a printer
  that cannot print something is a bug in this spec.
- **L2, formatter idempotence.** `print(parse(t)) = t` for canonically
  formatted text `t`.
- **L3, hash equivalence.** A surface file and its bootstrap twin produce
  identical hashes. The differential harness enforces this over the corpus.
- **L4, local desugaring.** Every sugar has a specified, purely local
  desugaring given in this document. No whole-program transforms hide in the
  parser.
- **L5, diagnostics speak surface.** Sugar records provenance in metadata
  (like trivia, hash-excluded), so an error inside an `if` is reported in
  terms of `if`, never the underlying `match`. The printer likewise re-emits
  the form the author wrote when provenance says so.
- **L6, trivia round-trips.** Parse retains comment and layout bytes exactly in
  metadata. Trivia-aware formatting preserves comments, documentation, order,
  and ownership while canonicalizing layout; it need not reproduce tabs, CRLF,
  blank-line counts, semicolons, or spacing byte-for-byte. Canonical printing
  remains metadata-insensitive.
- **L7, one grammar page.** The grammar stays small enough to print on a
  page and hand-parse by recursive descent. This is a law rather than an
  aspiration because grammar growth is the failure mode of every syntax
  project, and L7 is the tripwire.

## 4. Lexical ground rules

Identifiers are kebab-case with optional `?` and `!` suffixes, matching the
stdlib conventions (`with-default`, `empty?`, `head!`), plus dotted paths
(`list.map`). The only infix token is `|>`, so no infix operator competes with
`-` inside a name. Negative literals (`-3`) are handled at the lexer, since a
leading minus can only start a number.

The canonical printer escapes a legal kernel name that collides with a
reserved surface keyword, or whose D34 case projection would not invert, by
wrapping its kind and kernel name in backticks: a bootstrap term named
`match` prints as `` `term:match` ``, while a constructor named `a--b` prints
as `` `con:a--b` ``. Backticks are an identity-preserving fallback, not a
second identifier namespace; the parser removes the wrapper before
resolution. This escape is required by L1 because the bootstrap grammar
predates the surface keyword set and permits repeated or trailing hyphens.

**Case marks the sort (D34).** A capitalized head (`MkFleet`, `Up`, `Bool`)
names a type, a constructor, or an effect; a lowercase head (`mk-fleet`, `up`,
`bool.and`) names a term or an operation, including as a dotted namespace
prefix. The distinction is load-bearing rather than stylistic: in pattern
position (§5, Match) the capital is the only signal that `Up` is a nullary
constructor pattern and not a fresh variable binding that matches everything,
exactly Haskell's rule. The bootstrap corpus already stores every
user-declared constructor, type, and effect name lowercase-kebab, the same as
every other identifier in that format (`defeffect choice`, `deftype bad`,
`(pcon mk-pair ...)`, `(pcon true)`/`(pcon false)`), because the bootstrap
s-expression syntax tags constructor position explicitly (`pcon` versus
`pvar`) and has no case-based ambiguity left to resolve. The kernel spec's
own worked example already draws the surface/kernel line at exactly this
boundary: docs/ast.md §8 labels `type Bool = False | True` "surface,"
contrasted against the kernel form referencing `#Bool.True`/`#Bool.False` by
hash and ordinal. docs/stdlib.md's display notation assumes the same split
throughout (`type Option a = None | Some a`, `Bool`/`Ordering`/`Option`/
`Result` in prose, next to lowercase `bool.and`/`list.head`). D34 states the
rule those docs were already leaning on: the surface projects a stored name
to PascalCase by capitalizing each hyphen-delimited segment and dropping the
hyphens (`mk-fleet` -> `MkFleet`, `option` -> `Option`); the parser's
resolver inverts it by splitting at each internal capital, lowercasing, and
re-joining with hyphens, before doing the same store-index lookup the
bootstrap reader already performs by name. Canonical identity stays
hash-plus-ordinal (docs/ast.md §5.2: `PCon` references by hash, never by
name), so the projection is a lookup-and-display convenience, not a hashing
concern; SS.17 pins it over real programs. The two directions invert cleanly
only if stored names avoid embedded acronym segments (`http-request`, not a
name that would fold to `HTTPRequest`); acronym-safe folding is out of scope
for v0.

**Namespace puns are permanent (D37).** A dotted path is one atomic token
resolved as a whole against the store's name index (there is no
field-access operator to split it apart), so a local binding may reuse a
namespace root as its own plain name in the same scope with no collision:
`let code = eval-code(code)` beside globals `code.un-form`, `code.form`, and
`code.diff` in the same function parses today and keeps parsing, because
`code` and `code.un-form` are unrelated tokens to the lexer. Both field
exercises produced this pun unprompted and repeatedly (`repair.jac`'s
`eval-code(code)`; a second program's `plan.summary(plan)` and
`let ticket = ticket.open(...)`), which is convergent enough to settle rather
than fight: the pun is blessed forever, and if record or module field access
gets its own surface syntax later, it uses an operator other than `.`.

The operator stance deserves its paragraph, because it is the most tempting
thing to compromise on. `k + 1` requires either a monomorphic `+` bound to
one numeric type (the exact OCaml `+.` regret the whitepaper catalogs) or
type-directed operator resolution (which is ad-hoc polymorphism smuggled in
before the trait decision, prejudging it). Both are worse than the pain they
relieve. So v0 ships exactly one infix form, the pipe, and arithmetic stays
dotted (`int.add(k, 1)`) until the trait decision lands, at which point
operators arrive as method sugar on whatever that mechanism is. Dotted
arithmetic is also, honestly, more reviewable: the type is in the name.

Reserved keywords, the complete list: `type effect fn let rec match handle
return resume quote unquote if then else as where forall jqd`. Comments are `--` to end
of line; `--|` is a doc comment attaching to the next declaration's `doc`
metadata. Strings are `"..."` with the usual escapes, UTF-8 per D3. Numbers
are `Int` and `Real` literals. Blocks separate items by newline or `;`,
interchangeably; the printer always emits newlines. A clause body is one
expression, so sequencing there uses an explicit braced block.

`_` is a legal, non-referencable binder name anywhere the grammar takes a
plain binder rather than a pattern: currently only `resume`'s continuation
slot in an `opclause` (§5, Handlers), since that slot is a kernel `name`, not
a `pat` (docs/ast.md: `opclause = (hash op, pat* params, name resume, expr
body)`). Writing `resume _` for a clause that never resumes, as the spec's
own `abort` example already does, is an ordinary binder that happens to be
unreferenceable, not a wildcard pattern match.

## 5. The forms

Everything below shows surface, then the kernel desugaring. Signatures use
the row notation already standard across the docs (`->{}`, `->{Net | e}`),
now the actual grammar: inference means rows are rarely written, elaboration
means they are always displayable.

### Top-level items

A `.jac` file is a sequence of top-level items, in document order:
definitions (below) and bare expressions (D40). A bare expression is legal
wherever a definition is, and is evaluated in order when the file runs,
exactly what `jacquard run` already does for bootstrap files. This needed a
one-line rule, not a new form: a driver program routinely has several bare
top-level expressions, and a handler demo's entire payoff can be a bare
top-level `handle`.

### Definitions

Equation style is canonical for functions; `fn` is the anonymous form;
plain `=` binds values.

```
head : (List a) ->{} Option a
head(xs) = match xs {
  | Nil -> None
  | Cons(x, _) -> Some(x)
}

increment = fn (n) -> int.add(n, 1)
limit = 100
```

Desugaring: a signature line becomes the binding's annotation; `name(p, q) =
body` becomes `binding name (Lam [p q] body)` inside a `DefTerm` group;
adjacent definitions that reference each other form the group. Local
recursion: `let rec go(n) = ...` desugars to `Let(rec, ...)` under the
kernel's lambda-only restriction.

The parser computes strongly connected components within each uninterrupted
run of term definitions. A recursive component becomes one `DefTerm`; a
nonrecursive definition becomes a singleton `DefTerm`. Existing bootstrap
trees are not required to obey that normalized grouping, so the total printer
uses the documented top-level `jqd { (defterm ...) }` escape when a group of
independent bindings would otherwise lose its boundary on reparse.

A signature attaches to the next definition of the same name; comments and
blank lines may appear between them, and nothing else may. Field-exercise
code routinely put a blank line there, so the grammar has to allow it
explicitly rather than reject it by accident.

### Blocks, let, sequencing

```
run(request) = {
  let ok = approval.ask("Run this?")
  console.print("checked")
  if ok then console.print("yes") else console.print("no")
}
```

Braces delimit an expression block. `let p = e` scopes over the remainder of
the block; a bare expression line desugars to `Let(false, PWild, e, rest)`;
the final expression is the block's value. There is no statement anywhere,
per the kernel.

### Match

```
match xs {
  | Nil -> None
  | Cons(x, rest) as whole -> Some((x, whole))
}
```

Every arm starts with `|`, ends at the next `|` or `}`. This is the
indentation-insensitivity decision (D27) doing its work: arm boundaries are
tokens, so nesting never needs indentation rules, models cannot produce
whitespace-ambiguous matches, and the parser is trivial. Patterns cover the
whole kernel sort: `_`, names, literals, constructors, tuples, and `as`
(kernel `PAs`, per L1). Multi-line arm bodies use braces.

Precisely: an arm body is braced only if it sequences (contains a `let` or
another statement-position expression before its final value); a single
expression stays unbraced no matter how many lines it wraps (an `if`-chain,
for instance). This is now the rule, not a formatting choice left open per
arm.

Literal patterns cover `Text` exactly as they cover `Int` and `Real` (`PLit`
doesn't distinguish); `| "operator" -> 3.0` and `| "ok" -> 200` are ordinary
literal patterns, nothing special.

Constructor patterns stay positional in v0; a labeled pattern syntax
(matching D36's labeled fields, below) is deferred. A positional match past
four fields is exactly the readability failure labeled patterns exist to fix
(`Snapshot(_, error-rate, p95, _, db-lag, _, vendor, _)` is the canonical bad
case), so the checker lints it rather than letting it accumulate silently;
see §7.

When the scrutinee itself is a large multi-line expression, the printer does
not hoist it into a preceding `let` on the author's behalf; an automatic
hoist would be exactly the whole-program-shaped rewrite this design avoids
everywhere else (L4). v0's answer is a lint past a line-count threshold that
recommends the author hoist by hand, not an automatic transform.

### If

```
if c then a else b
```

Desugars to the two-arm `Bool` match, exactly as the kernel spec blessed.
Provenance metadata records that the author wrote `if`, so diagnostics and
the printer stay in `if` terms (L5). The two branch constructors resolve via
the same D34 case-fold as any other constructor reference (`True` ->
`true`, `False` -> `false`); nothing about `if` bypasses that rule.

Chained conditionals print flat: each `else if` stays at the same indent as
the `if` it continues, rather than nesting one level deeper per branch. The
kernel sees only nested two-arm matches either way; flatness is a rendering
choice, and it is the one that stays readable: one field exercise nested
each `else if` a level deeper and the result marched off the right margin,
while the other kept chains flat, which is the printer's rule now.

### Tuples, unit, lists

`(a, b)` and `()` are kernel tuples. `[1, 2, 3]` is sugar desugaring by name
to `Cons(1, Cons(2, Cons(3, Nil)))`, resolved like any other names (D32), so
the sugar carries no hard-coded hashes.

### Pipe

```
xs |> list.map(f) |> list.sort(int.ord)
```

The one infix. Left-associative, lowest precedence, threads the left operand
as the first argument: `list.sort(list.map(xs, f), int.ord)`. This is the
subject-first convention the stdlib promised, cashed in.

### Types and effects

```
type Option a = | None | Some a

type Fleet = | MkFleet(inv: SvcMood, pay: SvcMood, shp: SvcMood)

effect Approval where {
  ask : (Text) -> Bool
}

effect Choice a where {
  choose : () -> Bool
}
```

Direct renderings of `DefType` and `DefEffect`. Constructor fields may be
labeled (D36): `field: Type` inside a constructor's parens. SS.8 shipped this
syntax together with field metadata, trivia, lowering, and canonical printing.
It did not generate accessor definitions, so `fleet.inv` remains unresolved
unless declared explicitly. Both field exercises invented this exact
`Ctor(field: Type, ...)` notation independently. Labeled patterns are deferred
past v0 (§5, Match).

The braces after `where` are mandatory. Operation signatures and top-level
term signatures otherwise have the same lexical shape, so an unbraced effect
body would make its endpoint depend on indentation or blank lines. Mandatory
braces preserve D27 and give recovery a reliable synchronization token.

The original D36 design calls for each eligible field label to generate
`<type-kebab>.<label>` as an ordinary pure function. That generation contract
and its required validation did not ship in SS.8 or the completed SS.0-SS.22
arc. In particular, duplicate labels and labels that are missing or
type-inconsistent across constructors are not rejected, and explicit-term
collisions are not checked. These are deliberate partial follow-ups with a
separate acceptance gate in `docs/release/surface-syntax/FOLLOWUPS.md`, not
claims about current behavior.

`Choice`'s `a` is a phantom parameter: it never appears in `choose`'s
signature, and that is legal: an effect's type parameters scope over every
operation's signature whether or not a given operation happens to use them.

Constructor lists print inline with leading pipes while they fit one line
(`type Outcome = | Clear | Choppy | Blackout`) and one constructor per line
past the formatter's standard width, the same width row notation wraps at,
below.

Row notation prints tight, with no interior spaces (`->{Net, Clock}`, never
`-> { Net, Clock }`), and wraps one effect per line past that width.
`()` is the empty tuple type and `(T,)` is the singleton tuple type; the
trailing comma preserves every legal kernel `TTuple` arity. Quantification
prints `forall a b | e. T`, with type variables before `|` and row variables
after it. Either side may be empty, and `forall . T` is the exact inversion of
an explicitly empty `TForall` node (ordinary source omits that vacuous form).

### Handlers

```
to-option(body) =
  handle body() {
    | return x -> Some(x)
    | abort() resume _ -> None
  }
```

The clause grammar mirrors the kernel `opclause` exactly: operation, argument
patterns, `resume` binding the continuation as an ordinary variable, body.
`return` is the mandatory return clause. Nothing clever happens here on
purpose; handlers are where the unusual power lives, so the syntax is the
most literal in the language.

```
to-option(m) =
  handle { match m { | Up -> risky() | Down -> safe() } } {
    | return x -> Some(x)
    | abort() resume _ -> None
  }
```

When the handled body is itself a braced or multi-line form, wrap it in an
explicit `{ }` block (D35): `handle { body } { clauses }`. An atomic call
like the first example's `body()` needs no wrapper, which is why that
example never exposes the ambiguity, but `handle match ... { arms } {
clauses }` is genuinely unparseable without a rule for where the match ends
and the clause list begins. The block form is the zero-new-keyword answer.

### Quote and unquote

```
make-call(f) = quote { unquote(f)(41) }
```

`quote { ... }` contains ordinary surface syntax (D33), parsed normally and
captured as the pre-resolution triple per the kernel spec. `unquote(e)`
splices. Both stay visually heavy on purpose, and `eval` remains a gated
effect elsewhere; the syntax adds no evaluation power.

At every non-live quote depth, a constructor such as `Some` is captured as
`(surface-ref-v0 con some)` and an explicitly operation-kind name such as `` `op:abort` `` is
captured as `(surface-ref-v0 op abort)`. This structure, rather than hash-excluded metadata,
preserves namespace intent. A live `unquote` payload remains an ordinary expression and resolves
in its surrounding lexical environment. Raw `quote { jqd { ... } }` input may contain the same
markers, but `surface-ref-v0` is a reserved head: malformed arity, argument sorts, or kinds are
validation errors even when nested as quote data. The normative grammar and diagnostics are in
`spec/jacquard-kernel-ast-m0.md` §4.1; byte-level compatibility is in `spec/serialization.md`.

For a large generated policy, factor stable quoted subtrees into named `Code` values and splice
those names into the outer quote. A short outer `quote` makes staging depth reviewable, gives each
sub-policy an independent hash and diff boundary, and reduces the number of closing braces an
author must balance at once. Keep a small expression inline when splitting it would hide the
policy's control flow; the recommendation is for substantial repeated or independently reviewed
fragments, not every nested quote.

Delimiter recovery is construct-aware for `quote`, `match`, `if`, `handle`, and expression blocks.
The primary diagnostic points at the token or EOF where closing became impossible and its hint
points back to the construct's opening span. The recovery tree receives a synthetic, metadata-marked
delimiter or hole so analysis can continue at a safe later top-level item. That marker is editor
state only: strict parsing, formatting, hashing, storage, and execution all continue to reject the
original malformed source.

### Annotation

`(e : T)` is kernel `Ann`.

That is the entire grammar. No precedence table exists because one infix
operator needs none; expressions are literals, names, calls `f(a, b)`,
parenthesized forms, and the constructs above. A recursive-descent parser
for this is a short week including recovery, which is L7 holding.

## 6. Excluded from v0

Operators beyond pipe (argued above). Guards, or-patterns (kernel-excluded).
Records beyond labeled fields. Modules and imports (names are store-level
objects; a `.jac` file's free names resolve against the store's index, and
the file format needs no import statements, though an editor will want to
display resolution). Do-notation and other monadic sugar (no mechanism to
abstract over yet). Custom operators, forever contentious, deferred with the
trait decision. Offside-rule layout (D27 alternative, revisit only with
evidence that braces measurably hurt).

Labeled constructor *patterns* (D36 defers them). Labeled declarations ship;
generated accessors and label validation remain parked D36 follow-ups.
Interpolation sugar for text (D38 ships a prelude-only `text.join` for now; a
real syntax form is a separate design pass against L4).
Predicate/comparison naming (D39: `?`-suffixed predicates beside bare
dictionary names, `gte?/lte?/gt?/lt?`, the `real.*` rename); both of these
are stdlib content, not grammar, and land in docs/stdlib.md rather than
here.

Two features get grammar headroom reserved without being designed:
linearity modes on effect declarations (one-shot versus multi-shot
operations; task 71's copy-on-resume is the runtime half, a declared mode
would be the static half) and resource-scoped row display (`Fs(read:
./config)`). Neither changes anything in this draft; both are noted so a
future row or effect-declaration change doesn't have to fight an unstated
assumption. Structured concurrency, scoped capabilities, traits, typed
staging, formal row soundness, and a blessed effect-name taxonomy are
recorded in the language-level backlog and are out of this document's scope
entirely.

## 7. Diagnostics and tooling mechanics

A recovery result retains the complete original source string for its lifetime,
an intentional O(source-size) memory cost. When errors or holes make the tree
non-strict, recovery printing replays those bytes exactly instead of formatting
the valid islands, so comments cannot migrate across damage or synchronization
boundaries.

The parser emits hole forms at recovery sites. In recovery/editor analysis only,
the checker assigns each hole a fresh type and no effect contribution so one
syntax error does not cascade into fifty type errors. A malformed effect row is
recorded as a row hole and projects to a fresh open row, so it behaves as any row
rather than retaining partially parsed effect constraints. Strict semantic
boundaries reject holes before checking, execution, storage, or hashing. Sugar provenance
(L5) is a reserved metadata key recording the
surface form; the canonicalizer ignores it like all metadata. The semantic
differ gains a surface renderer, so review diffs read as `.jac` while
comparing trees. The formatter and the printer are the same program, which
is what printer-first means operationally.

`jacquard diff` accepts either two source files or two store directories. Source files are parsed,
lowered, and resolved independently against the prelude before the existing store-backed semantic
differ runs; they must contain declarations only. The prelude remains available for resolution and
dependency traversal, but root comparison and dependent names are restricted to declarations owned
by each source operand. A source declaration that shares a name with a prelude declaration is thus a
source addition, change, or removal rather than a comparison against the prelude definition. Auto
syntax follows each file extension and uses surface rendering when either source is `.jac`;
`--syntax` overrides parsing and rendering for both operands. Mixed file/store operands, unreadable
operands, malformed source, and top-level source expressions are diagnostics with exit status 1.
Store/store comparison keeps its full-store, bootstrap-rendered default.

Two diagnostics belong to this slice specifically. First, a bare reference
passed where a thunk type is expected (`fn () -> naive-checkout()` is the
correct form; a bare `naive-checkout` where a `() ->{| e} T` is wanted is not,
since top-level definitions close their rows) should say so in surface
terms ("wrap in `fn () ->`") rather than surfacing the underlying
row-inference error; the wrapper is common enough in translated code that it
reads as a mistake a reviewer will "simplify" into a type error they will
not recognize. Second, a binding pattern that shadows a constructor name
differing only in case (D34: lowercase `up` beside constructor `Up`) changes
program meaning without raising an error: the pattern silently becomes an
always-matching binder, so it warrants its own warning rather than reporting
an unbound variable, or nothing at all.

## 8. Migration

Bootstrap s-expressions remain fully supported forever; they are the debug
format, the quote-literal format, and the format of record for the kernel
spec. The corpus gains a `.jac` twin for every `.jqd` program, and the
differential harness compares hashes across the pair (L3). Stdlib and
testing-doc examples migrate into doctest files. Nothing about the store,
hashing, or the native backend changes at all, which is the projection
thesis verified by construction.

The corpus twins and doctests this phase produces should include, verbatim,
the patterns the field exercise flagged as already working: a signature
that discharges a multi-effect argument to the empty row (`simulate :
(Fleet, () ->{Net, Clock} Purchase) ->{} ...`), a pipe-threaded
transformation, a handler clause that reads as policy plus workflow, and a
nested destructure like `Some((head, children))`. These already read as the
payoff case for the design; SS.17 and SS.19 pin them so they cannot regress
silently.

SS.20 applies the same projection to the public demo set: repair, synthesis,
agent dream mode, ambiguity preservation, clarifying-question VOI, two-coins
inference, word count, and the M1 programs have paired `.jac`/`.jqd` carriers.
Public commands use `jac` with `.jac`; demo crams compare complete hash output
across each pair and continue to execute selected `.jqd` kernel routes.

## 9. Phasing

The SS.0-SS.22 implementation arc below is complete. Completion means the
named parser, printer, formatter, checker, CLI, corpus, documentation, demo,
and SS.22 prelude work shipped to their recorded evidence boundaries. It does
not complete the partial D36 accessor/validation design or the parked Tier-F
ideas, and it does not freeze future surface revisions.

- **S0 (SS.0-SS.4, tasks 87-91), printer and spec, M.** Record the
  decisions, scaffold the modules, build the canonical printer over kernel
  trees, review this grammar against it, L1 and L7 tested. No parser yet;
  the printer alone already upgrades diagnostics, the differ, and the docs.
- **S1 (SS.5-SS.11 plus SS.16, tasks 92-98 and 103), parser and formatter,
  L.** Recursive descent with recovery, trivia capture, row notation,
  L2/L3/L6 in CI, corpus twins generated by printing and verified by
  parsing.
- **S2 (SS.12-SS.15, tasks 99-102), sugar and diagnostics, M.** `if`, lists,
  pipe, equation defs, provenance metadata, hole-tolerant checking, L4/L5
  golden tests.
- **S3 (SS.17-SS.21, tasks 104-108), migration, S.** Doc examples become
  doctests; README and registry surfaces switch to `.jac`; bootstrap
  demoted to internal in docs.

(Task numbers above are task-master IDs as of this revision, which drift when
the tracker is regenerated; the SS.x labels are stable and are what to cite
in commit messages and task dependencies.)

## 10. Decisions

| ID | decision | default |
|----|----------|---------|
| D27 | layout discipline | delimiter-based and indentation-insensitive; newline or `;` separates block items; printer-canonical; offside rule rejected for v0 |
| D28 | operators | none except `\|>`; arithmetic dotted until the trait decision |
| D29 | comments | `--` line, `--\|` doc |
| D30 | definition form | equation style canonical, `fn` anonymous |
| D31 | file extensions | surface `.jac`; bootstrap keeps `.jqd` so tasks 65 to 76 are untouched |
| D32 | list literal | name-resolved sugar to `Cons`/`Nil` |
| D33 | quote body | surface syntax inside `quote { }`, captured pre-resolution |
| D34 | case convention | PascalCase for types/constructors/effects, kebab-case for terms/operations; pattern-position capitals are constructors |
| D35 | handle delimiting | atomic body needs no wrapper; a non-atomic body takes an explicit `{ }` block; the clause list is always braced |
| D36 | labeled fields | partial: `Ctor(field: Type, ...)` parsing, metadata, trivia, lowering, and printing ship; generated accessors and label validation have a separate follow-up gate; labeled patterns remain deferred |
| D37 | namespace puns | blessed permanently: dotted names are one atomic token forever; a future field-access form will not use `.` |
| D38 | text building | a variadic `text.join` ships in the prelude now; interpolation sugar is a separate design note, not v0 |
| D39 | comparison naming | `?`-suffixed predicates beside bare dictionary names; prelude gains `gt? gte? lt? lte?`; the `add-real` family migrates to `real.*` |
| D40 | top-level items | a bare expression is a legal top-level item, evaluated in document order (ratifies existing `jacquard run` behavior) |
