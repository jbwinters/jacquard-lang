---
name: jacquard
description: Install and use Jacquard; write, check, run, format, hash, infer, test, and compile effect-typed, content-addressed .jac programs. Use for Jacquard surface syntax, capability manifests, handlers, discrete Dist models, Code values, Warp tests, canonical identity, replay, and native AOT builds.
---

# Jacquard Standalone Guide

Jacquard is a research language for model-written, human-reviewed programs.
Its central promise is that effects, uncertainty, and program identity remain
visible to the checker and tools:

- Function arrows carry effect rows, such as `(Text) ->{Net, Console} Int`.
- A runnable expression's inferred row is its authority manifest. The runtime
  installs world handlers only for explicit `--allow` grants.
- Probability is the ordinary `Dist` effect. Exact enumeration and likelihood
  weighting run the same model under different handlers.
- Definitions are content-addressed from canonical resolved structure after
  comments, formatting, spans, provenance, and ordinary local or term names
  are erased. This structural identity is not arbitrary program equivalence.
- Handlers are deep. `multi` operations bind reusable continuations; `once`
  operations bind affine `Resume` values with static and runtime reuse checks.

This file is self-contained for public use. A repository checkout is needed
only to develop the OCaml implementation, not to install or write Jacquard.

This guide describes the current `main` branch. Where it differs from the
latest release (0.3.0), the difference is marked **Since 0.3.0**. Every
`jacquard` example in this file is run or checked by the repository's
documentation tests (`test/docs-doctest`).

## Install

The release installer downloads a checksum-verified binary, the standard
prelude, demos, and the C runtime used by native builds. It does not require
OCaml, opam, or Dune.

```sh
curl -fsSL https://raw.githubusercontent.com/jbwinters/jacquard-lang/jacquard-core-0.3.0/scripts/install.sh | sh
export PATH="$HOME/.local/bin:$PATH"
jac --version
jac run "$HOME/.local/share/jacquard/demos/basics/m1-fact.jac"
sh "$HOME/.local/share/jacquard/demos/case-studies/release-risk/run.sh"
```

The `jac run` command prints `120`; the final command runs the larger release
risk narrative. The published targets are Linux x86-64,
macOS Intel, and macOS Apple Silicon. Set `JACQUARD_INSTALL_PREFIX` to choose a
different prefix and `JACQUARD_INSTALL_VERSION` to choose another release tag.
The long command is `jacquard`; `jac` is its installed short alias.

Shipped `*.sh` demo launchers work without a source checkout. Use them for
models that require an inference driver and for multi-file narratives; directly
running an `observe` model under `jac run` correctly fails with E0904.

In a source checkout, use the repository-local opam switch:

```sh
eval "$(opam env)"
export JACQUARD_PRELUDE=$PWD/prelude
opam exec -- dune build @all
opam exec -- dune exec jac -- --version
```

When this guide writes `jac`, source developers may substitute
`opam exec -- dune exec jac --`.

## Command Reference

Public source files use `.jac`. The CLI chooses the surface parser from that
extension.

```sh
# Check without executing.
jac check PROGRAM.jac
jac check PROGRAM.jac --print-sigs
jac check PROGRAM.jac --manifest fs,net,console

# Run, granting only named root effects.
jac run PROGRAM.jac
jac run PROGRAM.jac --allow console --allow net
jac run PROGRAM.jac --dry-run
jac run PROGRAM.jac --fuel 1000000   # bounded: running out is E0919, exit 2

# Local projects (project.jqd): compose several files, pin dependencies,
# bundle; see docs/designs/project-structure.md.
jac project check --project DIR
jac project run --project DIR ENTRY --allow console
jac project test --project DIR --seed 42 --no-cache
jac project build --project DIR ENTRY -o OUT
jac project pin --project DIR

# Public API identity: emit a source's interface-v1 manifest, verify a store
# against one, or classify a change between two manifests.
jac interface emit LIB.jac
jac interface verify LIB.jqi STORE
jac interface diff OLD.jqi NEW.jqi

# Since 0.3.0: compare two checked versions of an entry point over declared
# cases and report where behavior differs (docs/behavior-review.md).
jac review run --old OLD.jac --new NEW.jac --cases CASES.jac --entry NAME --domain NAME

# Compare complete transcripts under schedule/Secret variation, or only result
# values under one live grant versus the dry world.
jac relate PROGRAM.jac --vary schedule=8 --seed 42
jac relate PROGRAM.jac --vary schedule=8 --seed 42 --allow console
jac relate PROGRAM.jac --vary secret=deploy-token --seed 42 --allow secret
jac relate PROGRAM.jac --vary grant=net --seed 42

# Format and identify code.
jac fmt PROGRAM.jac
jac fmt PROGRAM.jac --write
jac hash PROGRAM.jac

# Discrete probabilistic inference.
jac infer enumerate MODEL.jac
jac infer lw MODEL.jac --seed 42 --samples 100000
jac dist-diff MODEL_A.jac MODEL_B.jac

# Warp tests.
jac test TESTS.jac --seed 42
jac test TESTS.jac --seed 42 --exhaustive --budget 10000
jac test TESTS.jac --cache-dir .jacquard-test-cache
jac test TESTS.jac --allow fs --allow net --allow clock --allow console

# Content store, canonical-structure diff, traces, and tiers. A store keeps the
# prelude and every installed declaration and records which prelude files
# (names and bytes) it was created with: reopening with that prelude is a
# no-op, so separate entry points can run against one installed model, and
# reopening with a different prelude is refused (E0705) without changes. A
# `store add` that refuses any declaration leaves the store exactly as it was.
jac run MODEL.jac --store STORE
jac run ENTRY.jac --store STORE
jac store add STORE PROGRAM.jac
jac store rename STORE old-name new-name
jac diff STORE_A STORE_B
jac replay TRACE.jqd PROGRAM.jqd --to 12
jac replay TRACE.jqd PROGRAM.jqd --fork '4=(response 503 "down")'
jac tiers PROGRAM.jac

# Audit-chain and governed Workspace review tools.
jac audit genesis
jac audit append AUDIT_LOG.audit AUDIT_ENTRY.jqd --previous HASH
jac governance check WORKSPACE.jac --output-format json-v1
jac governance verify-log AUDIT_LOG.audit --head HASH
jac governance verify-run RUN_BUNDLE.jqd
jac governance reconcile RECONCILIATION_BUNDLE.jqd
jac governance explain PROPOSAL_ID --bundle RECONCILIATION_BUNDLE.jqd
jac host worker --store DIR
jac why-effect Net --source WORKSPACE.jac --output-format json-v1

# Native AOT accepts public surface input directly.
jac build PROGRAM.jac -o program
jac export PROGRAM.jac -o PROGRAM.jqd  # explicit evidence/debug carrier only
./program --allow console
```

`check` typechecks every declaration. `run` loads declarations, then evaluates
each bare top-level expression in order, and typechecks only what those
expressions reach, so run `check` to catch errors in code nothing calls yet.
`check --manifest` checks the inferred requirements of the file's bare top-level
expressions against the supplied grant set and never runs the program. A file of
declarations only still typechecks but passes the authority comparison
trivially; include the entry call (for example `main()`). Important exit codes
are:

- `0`: success
- `1`: checker or ordinary diagnostic failure
- `2`: runtime failure, including running out of `--fuel` (E0919)
- `3`: unhandled or ungranted effect
- `124`: command-line usage error

`tiers` reports handler syntax and native lowering as separate tables. A
tail-resumptive source shape is tokenless only for a `multi` operation; every
`once` clause materializes the shared affine resume token, including a
syntactically tail-resumptive clause.

Use stderr for diagnostics and stdout for successful program output. Always
provide an explicit seed for reproducible sampling and property tests.
`relate` success stdout is one verdict line; constituent values and Console
output are captured rather than printed. Console input is read from the process
only during run 1, captured by call ordinal, and replayed from a fresh cursor in
every later run; calls beyond the captured list receive EOF (`""`). A completed
transcript difference is Warp diagnostic E1003 and status 1. Constituent
diagnostic, runtime, and authority failures retain statuses 1, 2, and 3.
Secret variation runs exactly twice with distinct deterministic latest-version
payloads for the named Secret while holding the scheduler and Dist seed fixed.
It compares the raw transcripts, then redacts either derived payload from all
text, JSON, runtime, and unexpected-error output. This exact-byte scrubber is
not taint tracking and does not detect transformed or fragmented payloads. Use
`jacquard relate FILE --vary secret=NAME --seed S --allow secret` only as
bounded evidence for that selected program, name, and seed.
Grant variation runs exactly twice with no extra `--allow`: one live
`net`, `infer`, or nonzero-seeded `dist` grant, then the released dry world.
It compares only ordered rendered result values, not routed events, Console
output, audits, calls, costs, latency, or external consequences. Forwarded,
mixed read/write, unsupported, and unknown effects are usage errors.
The `audit` commands append canonical hash-chained entries and publish their
heads. The `governance` and `why-effect` commands verify frozen Workspace v0
artifacts or conservatively analyze declaration-only source; they do not
execute that source or turn review evidence into host authorization.

## Surface Syntax

`.jac` is delimiter-based and indentation-insensitive. Newlines or semicolons
separate top-level and block items. `--` starts a line comment; `--|` starts a
documentation comment for the next declaration. There is no import or module
syntax. Free names resolve through the loaded prelude/store.

Names follow these rules:

- Terms, operations, variables, and type variables are lowercase kebab-case:
  `with-default`, `empty?`, `head!`.
- Dotted names are single global names, not field access: `list.map`,
  `text.contains?`, `dist.enumerate`.
- Types, effects, and constructors are PascalCase: `Option`, `Net`, `Some`.
- A local `code` and a global `code.diff` do not conflict.
- The only infix operator is `|>`. Arithmetic is called by name.
- Strings support `\\`, `\"`, `\n`, `\t`, `\r`, and `\xNN` escapes.
- Integers are signed 63-bit values and wrap. Division truncates toward zero.
- Reals are floating point. Text is UTF-8 and indexed by codepoint, not
  grapheme cluster.

Reserved words are `type`, `effect`, `once`, `multi`, `fn`, `let`, `rec`,
`match`, `handle`, `return`, `resume`, `quote`, `unquote`, `if`, `then`,
`else`, `as`, `where`, `forall`, `jqd`, `try`, and `with`. `opaque` is a
contextual keyword, special only before a top-level `type`.

### Values, Calls, And Definitions

Calls are uncurried. A function declared with two parameters is called with
two arguments in one call.

```jacquard doctest=skill-definitions mode=run fixture=skill-definitions.jac stdout=skill-definitions.stdout stderr=empty exit=0
limit = 100

add-tax(amount, rate) = real.mul(amount, real.add(1.0, rate))

resize(image, scale: ratio) = (image, ratio)

increment = fn (n) -> add(n, 1)

answer : () ->{} Int
answer() = increment(41)

answer()

resize("photo.png", scale: 2)
```

An eligible callable may declare an unlabeled positional prefix followed by an
explicitly labeled suffix. At a call, positional arguments must likewise come
first; labeled arguments may then appear in any order. Calls remain uncurried
and exact-arity: every slot is supplied exactly once, with no defaults, label
puns, partial application, or positional argument after a label. Arguments
always evaluate once, left to right in source order; resolution inserts local
`let` bindings when declaration-order application would otherwise reorder
them.

Named calls are deliberately direct and fail closed. A top-level equation
parameter declares a label with `label: binder`, an effect operation declares
one with `label: Type`, and a constructor reuses its field label. The label is
external API and need not equal its binder. Locals, anonymous functions,
higher-order callees, patterned parameters, and unlabeled declarations accept
only positional calls; attempting a named call reports E0309. Unknown,
duplicate/overlapping, missing, malformed-declaration, and ambiguous-schema
cases report E0310-E0314.

Term and operation labels are persisted as a versioned `call-abi-v1`
companion keyed by the exact callable hash. Renaming the callable or its local
binder leaves that companion intact. Publishing different labels for the same
hash is E0612, so never infer labels from binder names or replace a stored ABI.
Constructor labels already belong to the constructor schema and content
identity. Named syntax lowers to ordinary positional `App`/`Let`, so a valid
named call hashes and runs like its explicit positional twin.

For review, when a direct term or operation publishes a usable companion label for the hotspot,
the checker warns on two still-valid positional shapes: W1206 for a direct
`True`/`False` argument, and W1207 for a definite adjacent run of same-typed
parameters. Prefer the callable's explicit labels.
If a boolean controls behavior rather than reporting a predicate, prefer a
purpose-specific sum such as `type Mode = | Live | DryRun`. These are advisory
warnings, not type errors, and the checker emits neither warning for a named
call.

Top-level `name = value` and `name(args) = body` create definitions. A
signature immediately before the matching definition is optional. Bare
top-level expressions are legal and run in document order. Top-level
definition bodies must be pure values; put effectful work in a function and
call it from a top-level expression.

Application may chain, so `make-adder(1)(2)` is valid when the first call
returns a function. Zero-argument functions are thunks and are called with
`()`. Parentheses group expressions.

Marked text interpolation keeps conversions explicit:

```jacquard doctest=skill-interpolation mode=run fixture=skill-interpolation.jac stdout=skill-interpolation.stdout stderr=empty exit=0
count = 3

$"total: {text.from-int(count)} of {{limit}"
```

Each embedded expression must be `Text` and is evaluated exactly once from
left to right. `{{` produces one literal opening brace. Keep the marked literal
and its embedded expressions on one physical source line; use `\n` for a
newline in the resulting text.

### Blocks, Let, And Recursion

A block is one expression. Each `let` scopes over the rest of the block. A
non-final expression is sequencing whose value is discarded; the final
expression is the block's value.

```jacquard doctest=skill-blocks mode=check fixture=skill-blocks.jac stdout=skill-blocks.stdout stderr=empty exit=0
factorial(n) = {
  let rec go(k, acc) =
    match k {
      | 0 -> acc
      | remaining -> go(sub(remaining, 1), mul(acc, remaining))
    }
  go(n, 1)
}

greet(name) = {
  println(text.concat("hello ", name))
  text.length(name)
}
```

Local recursive bindings must bind functions. Jacquard is strict and
evaluates arguments left to right. A local `let rec` whose body performs an
effect can fail row inference (E0801, a known checker bug) when nothing fixes
the recursive binder's row. Annotating the recursive call, as in
`(go : (Int) ->{Console} ())(k)`, or defining the function at top level avoids
it.

`try` propagates a `Result` error out of the enclosing block. `let p = try e`
binds the `Ok` payload; `try e` alone requires `Ok` and discards it. When `e` is
`Err(x)`, the rest of the block is skipped and the block's value is `Err(x)`.
The scope is the innermost `{ ... }` block, the error type must match exactly,
and `try` adds no effect (it is sugar for a `match`). A block cannot end with a
`try` item (E1243); its final expression is already the block's `Result`.

```jacquard doctest=skill-try mode=run fixture=skill-try.jac stdout=skill-try.stdout stderr=empty exit=0
parse-age(raw) =
  match text.to-int(raw) {
    | Some(n) -> if int.between?(n, 0, 150) then Ok(n) else Err($"out of range: {raw}")
    | None -> Err($"not a number: {raw}")
  }

total-age(a, b) = {
  let x = try parse-age(a)
  let y = try parse-age(b)
  Ok(add(x, y))
}

total-age("30", "12")

total-age("30", "abc")
```

### Conditionals And Matches

`if` requires both branches and is an expression:

```jacquard doctest=skill-if mode=check fixture=skill-if.jac stdout=skill-if.stdout stderr=empty exit=0
sign(n) =
  if int.lt?(n, 0) then "negative"
  else if eq(n, 0) then "zero"
  else "positive"
```

`match` must be exhaustive. Patterns include `_`, fresh lowercase binders,
literals, constructors, tuples, and `as` patterns. Constructor patterns start
uppercase; a lowercase pattern always binds a new variable.

```jacquard doctest=skill-match mode=check fixture=skill-match.jac stdout=skill-match.stdout stderr=empty exit=0
type Option a =
  | None
  | Some a

head(xs) =
  match xs {
    | Nil -> None
    | Cons(x, rest) as whole -> Some((x, rest, whole))
  }
```

For constructors with labeled fields, a match may select only the fields it
needs:

```jacquard doctest=skill-labeled-patterns mode=check fixture=skill-labeled-patterns.jac stdout=skill-labeled-patterns.stdout stderr=empty exit=0
type Snapshot =
  | Snapshot(id: Int, error: Int, vendor: Text)

describe(snap) =
  match snap {
    | Snapshot(vendor: vendor, error: problem) -> (problem, vendor)
  }
```

Write every selection as `label: pattern`. There are no label puns, and one
constructor pattern cannot mix labeled and positional fields. Selection order
is free; resolution places fields in declaration order and treats omissions as
`_`. Unknown or repeated selections fail, as do labeled patterns against an
unlabeled or ambiguously labeled constructor. Nested and `as` patterns are
valid after `:`. `Ctor(name)` remains an ordinary positional binder pattern.
Labeled constructor patterns are refutable, just like positional constructor
patterns, so they are not valid lambda parameters or `let` binders.
Inside `quote { ... }`, constructor patterns must remain positional; labeled
patterns there fail with E1237 because quoted code cannot carry their labels
semantically.

Use a braced block when an arm sequences work:

```jacquard doctest=skill-match-block mode=check fixture=skill-match-block.jac stdout=skill-match-block.stdout stderr=empty exit=0
report(result) =
  match result {
    | Ok(value) -> {
        println("ok")
        value
      }
    | Err(message) -> {
        println(message)
        0
      }
  }
```

Lambda and `let` patterns must be irrefutable. Match arms may use refutable
patterns. Duplicate binders are rejected. There are no guards or or-patterns.

### Tuples, Lists, And Pipe

`()` is both the unit value and unit type. `(a, b)` is a tuple. List literals
lower to `Cons`/`Nil`.

```jacquard doctest=skill-pipe mode=run fixture=skill-pipe.jac stdout=skill-pipe.stdout stderr=empty exit=0
top-three(xs) =
  xs
  |> list.filter(fn (n) -> int.gt?(n, 0))
  |> list.map(fn (n) -> int.mul(n, n))
  |> list.sort(int.ord)
  |> list.take(3)

top-three([-2, 4, 1, 3])
```

Pipe is left-associative and inserts its left side as the first argument.
`xs |> list.map(f) |> list.sort(int.ord)` means
`list.sort(list.map(xs, f), int.ord)`. There are no arithmetic, comparison,
boolean, or custom infix operators.

### Types And Rows

Function types are uncurried and the effect row is part of the arrow:

```text
(Int, Int) ->{} Int
(Text) ->{Net} Response
(() ->{Abort | e} a) ->{| e} Option a
forall a b | e. (List a, (a) ->{| e} b) ->{| e} List b
```

`{}` is a pure row. `{Net, Console}` contains named effects. `{Abort | e}`
contains `Abort` plus an open row variable. `forall a b | e.` quantifies type
variables before `|` and row variables after it.

Tuples use `(A, B)`, unit uses `()`, and type application is whitespace-based:
`List Int`, `Option (Pair Text Real)`. `(T,)` is the rare singleton tuple type.

Algebraic data types are declared with constructors. Constructor fields may
be positional or labeled:

```jacquard doctest=skill-types mode=check fixture=skill-types.jac stdout=empty stderr=empty exit=0
type Decision =
  | Ship
  | Canary(percent: Int)
  | Hold(reason: Text)

type Result e a =
  | Err e
  | Ok a
```

Positional constructor fields are written like type application, separated
by spaces: `| Leaf Int`, `| Branch Tree Tree`, `| Cons a (List a)`.
Parentheses after a constructor introduce labeled fields, `| Leaf(value: Int)`;
positional types in parentheses (`| Leaf(Int)`) are refused with E1225.

Labels do not create records. A label that every constructor carries
generates an accessor named after the type: `type Pair = | Pair(left: Int,
right: Int)` gives `pair.left` and `pair.right`, so `pair.left(Pair(1, 2))` is
`1`. It also generates a setter, `pair.with-left(p, left: 5)`, which returns a
copy with that field replaced. To replace several fields of a value built by
one constructor, name the constructor: `Pair(p with left: 5, right: 6)`
evaluates `p`, then each new field once in source order, and hashes as the
explicit `let`-and-`match` that rebuilds it. On a sum type a `with` update
covers only the constructor it names and is refused as a non-exhaustive match
(E0813) that points at the total setter. A label on only some constructors has
no accessor or setter; select it with a pattern. Construct values either positionally with `Canary(5)` or by label with
`Canary(percent: 5)`; match either positionally with
`Canary(percent)` or by selection with `Canary(percent: value)`.
Prelude types declared in `.jqd` (such as `Request` and `Response`) have no
generated accessors; read their fields with a match.

`opaque type` seals a type's constructors to the source file or project that
declares it. Other code must go through the owner's functions, so the owner can
enforce an invariant. Accessors are still generated, setters are not, and a
value prints as `<opaque name>` (see `demos/abstract-types`).

```jacquard doctest=skill-opaque mode=check fixture=skill-opaque.jac stdout=skill-opaque.stdout stderr=empty exit=0
opaque type Percent = Percent(value: Int)

percent.of-int(n) =
  if int.between?(n, 0, 100) then Ok(Percent(n)) else Err("out of range")
```

Comma-separated surface groups accept an optional final comma. Compact
formatting removes it, except for singleton tuples such as `(T,)`; when a
group wraps, Jacquard prints one item per line and a comma after every item.
The punctuation is erased before kernel validation and never changes hashes
or `.jqd` behavior.

### Effects And Deep Mode-Aware Handlers

Effects declare operations. Calling an operation looks like an ordinary call;
there is no `perform` keyword.

```jacquard doctest=skill-effects mode=check fixture=skill-effects.jac stdout=empty stderr=empty exit=0
multi effect Choice where {
  choose : () -> Bool
}

once effect Abort a where {
  abort : () -> a
}

once effect Sending where {
  send : (path: Text, body: Text) -> Text
}
```

A handler has one mandatory return clause and operation clauses. For a `multi`
operation, `resume` binds a reusable continuation: calling it zero times aborts
that path, once resumes normally, and more than once forks execution. For a
`once` operation, it binds an affine `Resume` that may be dropped or consumed
once on each possible execution path. The bounded syntactic affine analysis
reports E0816 for a possible double consumption and E0817 for an unsupported
escape; it is engineering enforcement, not a formal proof. The interpreter and
native runtime independently report E0906 if one captured `once` instance is
resumed twice.

```jacquard doctest=skill-multi-handler mode=run fixture=skill-multi-handler.jac stdout=skill-multi-handler.stdout stderr=empty exit=0
multi effect Choice where {
  choose : () -> Bool
}

all-choices(body) =
  handle body() {
    | return value -> [value]
    | choose() resume continue ->
        list.append(continue(True), continue(False))
  }

all-choices(fn () -> (choose(), choose()))
```

Handlers are deep: operations performed after `continue(...)` re-enter the
same handler. The operation-clause body itself runs outside that handler, so
performing the same operation directly in its own clause forwards outward.
The return clause also runs outside the completed handled region.

For governed Workspace code, use the shipped
`workspace.forward-layer(sequence, policy, simulators, body)` for that pattern.
It forwards only the exact same once-mode Workspace operation and unchanged
arguments, shares the caller's `AuditSequence`, and retains `Workspace` rather
than introducing raw authority. Put one `workspace.live-layer` outside the
forwarding chain to terminate it in real drivers. Do not create another
sequence owner inside a layer or infer support for argument transforms.

Use `resume _` when a clause deliberately never resumes. A handler in quoted
code must name its continuation instead (E1245), because quoted code is
name-addressed; a handler inside a live `unquote` may still use `resume _`. **Since 0.3.0:** the 0.3.0 checker can crash on `resume _` in
some handlers (internal error `Bug_unprintable`, exit 125), including quoted
ones; with that release, bind a name you never use, such as `resume ignored`.

```jacquard doctest=skill-resume-wildcard mode=check fixture=skill-resume-wildcard.jac stdout=skill-resume-wildcard.stdout stderr=empty exit=0
to-option(body) =
  handle body() {
    | return value -> Some(value)
    | abort() resume _ -> None
  }
```

If the handled expression is not an atomic call, use two braces:

```jacquard doctest=skill-two-brace-handler mode=run fixture=skill-two-brace-handler.jac stdout=skill-two-brace-handler.stdout stderr=empty exit=0
type Direction =
  | Up
  | Down

risky() = abort()

safe() = 1

attempt(direction) =
  handle { match direction { | Up -> risky() | Down -> safe() } } {
    | return value -> Some(value)
    | abort() resume _ -> None
  }

attempt(Up)

attempt(Down)
```

Handling subtracts only the handled effect from the row and forwards all other
effects. This is why one unchanged policy can run under real, replay, dry-run,
scripted, hostile, or probabilistic handlers.

### Quote, Unquote, And Code

`quote` captures unresolved surface structure as a `Code` value. `unquote`
splices a `Code` value while inside a quote.

```jacquard doctest=skill-quote mode=check fixture=skill-quote.jac stdout=skill-quote.stdout stderr=empty exit=0
make-call(argument) = quote { add(unquote(argument), 1) }

candidate = quote { fn (x) -> add(x, 1) }

run-candidate() = {
  let function = `op:eval-code`(candidate)
  function(41)
}
```

Evaluation is authority: `eval-code` adds `Eval` to the row and requires
`--allow eval`. Granting `Eval` does not grant `Net`, `Fs`, or any other world
effect used by evaluated code. Constructed resolved hash references are
validated rather than trusted as a capability bypass.

Useful structural operations include:

- `code.eq?(a, b)`: metadata-erased structural equality
- `code.diff(a, b)`: text describing the smallest disagreeing subtrees
- `code.form(head, children)` and `code.un-form(code)`
- `code.of-int`, `code.to-int`, `code.of-text`, `code.to-text`

`unquote` outside `quote` is invalid. A splice must produce `Code`. Nested
quote levels are significant. `(expression : Type)` is a type annotation.
Named calls are rejected with E1238 anywhere inside a surface quote, including
inside a live `unquote`, because labels have no durable quoted carrier. Use a
positional call in quoted code. Labeled constructor patterns are independently
rejected there with E1237.

`jqd { (bootstrap form) }` is the surface escape for a kernel form that cannot
be represented without preserving an internal grouping. It is not general
mixed-syntax authoring.

### Compact Grammar

This practical grammar covers ordinary public source:

```text
file        := top-item*
top-item    := signature | definition | type-decl | effect-decl | expression
signature   := name ":" type
definition  := name ["(" ([label ":"] pattern ("," [label ":"] pattern)*)? ")"] "=" expression
type-decl   := ["opaque"] "type" Type type-vars? "=" ["|"] constructor ("|" constructor)*
effect-decl := mode "effect" Effect type-vars? "where" "{" uniform-op-signature+ "}"
| "effect" Effect type-vars? "where" "{" mode-op-signature+ "}"
uniform-op-signature := name ":" "(" ([label ":"] type ("," [label ":"] type)*)? ")" "->" type
mode-op-signature := mode name ":" "(" ([label ":"] type ("," [label ":"] type)*)? ")" "->" type
mode        := "once" | "multi"

expression  := call ("|>" call)*
call        := primary ("(" call-items? ")")*
call-items  := [label ":"] expression ("," [label ":"] expression)*
             | expression "with" label ":" expression ("," label ":" expression)*
primary     := literal | marked-text | name | tuple | list | block | fn | match | if
             | handle | quote | unquote | annotation
marked-text := '$"' ("{{" | "{" expression "}" | character-or-escape)* '"'
block       := "{" (let-item | try-item | expression)* expression "}"
let-item    := "let" ["rec"] pattern ["(" patterns? ")"] "=" expression
try-item    := ["let" pattern "="] "try" expression
fn          := "fn" "(" patterns? ")" "->" expression
match       := "match" expression "{" ("|" pattern "->" expression)+ "}"
if          := "if" expression "then" expression "else" expression
handle      := "handle" (atomic | block) "{" return-clause op-clause* "}"
quote       := "quote" "{" expression "}"
unquote     := "unquote" "(" expression ")"
annotation  := "(" expression ":" type ")"

pattern     := "_" | name | literal | Constructor ["(" (patterns | labeled-patterns)? ")"]
             | "(" patterns? ")" | pattern "as" name
labeled-patterns := label ":" pattern ("," label ":" pattern)* [","]
type        := type-application | tuple-type | function-type | forall-type
function-type := "(" types? ")" "->{" effects? ["|" row-var] "}" type
```

Indentation never determines structure. Calls, lists, tuples, and braced forms
allow line breaks. After `=`, `:`, `->`, `then`, `else`, and `|>`, a newline is
continuation rather than item separation.

## Capabilities And Root Authority

The complete `--allow` vocabulary is `clock`, `console`, `dist`, `eval`, `fs`,
`infer`, `net`, and `secret`. `Console`, `Clock`, `Fs`, and `Net` describe the
ordinary external world (`console` also grants `ConsoleInput`, whose `next-line`
returns `Option Text` and reports end of input as `None`, unlike `read-line`); `Eval` is dynamic-code authority, `Infer` delegates to
an unverified model boundary, `Secret` uses the environment adapter, and `Dist`
installs seeded sampling. `Dist` is computationally pure rather than outside-
world authority, but selecting its root sampling handler is still an explicit
grant. These root handlers exist only when granted:

```sh
jac check agent.jac --print-sigs
jac check agent.jac --manifest console,net
jac run agent.jac --allow console --allow net
```

Rules to rely on:

- The checker propagates effects through higher-order functions, returned
  closures, tuples, and polymorphic rows.
- A handler removes only its own effect.
- An ungranted world effect refuses before that effect executes.
- `check --manifest` never runs user code.
- `--dry-run` forwards reads and console/clock observation as documented,
  audits writes and network actions, and performs no audited world mutation.
- `--allow fs` currently grants the whole filesystem. Authority is effect-level,
  not path- or domain-level object capability.
- The interpreter's `--allow net` handler is a deterministic stub. Scripted and
  recording handlers ship, but a real socket/HTTP adapter does not.
- Evaluated code runs with root grants, not under an interposed attenuation
  handler. Audit its inferred requirements and grants accordingly.
- Top-level rows are closed. When an API expects an open-row thunk, eta-expand
  a named computation: `fn () -> model()`.

The world operations are called directly:

- Console: `print(text)` writes without a newline; `println(text)`, a prelude
  function over `print`, writes a line; `read-line()` returns `Text` (`""` at
  end of input). The `ConsoleInput` operation `next-line()` returns
  `Option Text`.
- Fs: `read(path)`, `write(path, text)`, `list-dir(path)`.
- Net: `fetch(MkRequest(url: u, body: b))` returns a `Response`, whose
  constructor is `MkResponse(status, body)`.
- Clock: `now()` returns an `Int`; `sleep(ms)`.
- Secret: `secret.read(SecretRef(name: n, version: None))` returns an
  unprintable `Secret`; `secret.expose(s)` returns its `Text` and is itself a
  `Secret` operation.

```jacquard doctest=skill-world-operations mode=check fixture=skill-world-operations.jac stdout=skill-world-operations.stdout stderr=empty exit=0
ask-name() = {
  println("name?")
  match next-line() {
    | Some(name) -> println($"hello {name}")
    | None -> println("no input")
  }
}

status-of(url) =
  match fetch(MkRequest(url: url, body: "")) {
    | MkResponse(status: status) -> status
  }

token() = secret.expose(secret.read(SecretRef(name: "deploy-token", version: None)))
```

Never infer authority from a hand-written manifest or comment; use the checked
row. Never add a grant merely to silence a refusal without reviewing why the
row contains that effect.

`Approval`, `Audit`, `Judge`, `Workspace`, and `Channel` have implemented
language or embedding boundaries but are not ordinary `--allow` root names.
In particular, a governance verdict is evidence consumed by trusted host code;
it does not install ambient authority.

## Discrete Probability With Dist

The prelude defines distribution values such as `Bernoulli(p)`,
`Categorical(weighted-pairs)`, and `UniformInt(low, high)`. Models perform
`sample` and `observe` through the `Dist` effect.

```jacquard doctest=skill-dist mode=check fixture=skill-dist.jac stdout=skill-dist.stdout stderr=empty exit=0
coin-model : () ->{Dist} Bool
coin-model() = {
  let first = `op:sample`(Bernoulli(0.5))
  let second = `op:sample`(Bernoulli(0.5))
  `op:observe`(
    Bernoulli(if bool.or(first, second) then 1.0 else 0.0),
    True)
  first
}

coin-model()
```

Run the exact and approximate handlers over the same file:

```sh
jac hash coin.jac > before.hash
jac infer enumerate coin.jac
jac infer lw coin.jac --seed 42 --samples 100000
jac hash coin.jac > after.hash
cmp before.hash after.hash
```

Exact enumeration resumes once per support value, multiplies observation
likelihoods, prunes exact zero-weight paths, merges equal outcomes at the CLI,
and normalizes. Likelihood weighting is deterministic for the same seed and
sample count. `Categorical` weights are relative. `UniformInt` exact support is
capped at 10,000 outcomes.

Inside Jacquard, use `dist.enumerate(fn () -> model())`, then
`dist.tally(table, equality)` when equal outcomes should be merged. The
in-language all-impossible case may expose NaN weights; CLI enumeration reports
a diagnostic instead. An unhandled root `observe` is an error.

## Standard Prelude

Jacquard uses explicit dictionaries instead of implicit typeclasses. Operations
that need equality, ordering, rendering, or generic arithmetic receive `Eq`,
`Ord`, `Show`, or `Num` values:

```jacquard doctest=skill-dictionaries mode=run fixture=skill-dictionaries.jac stdout=skill-dictionaries.stdout stderr=empty exit=0
numbers = [3, 1, 2]

names = ["alice", "bob"]

three-numbers() = check.eq(list.length(numbers), 3, int.eq, int.show, "three numbers")

list.sort(numbers, int.ord)

list.contains?(names, "alice", text.eq)

num.add(int.num)(40, 2)
```

`int.num` and `real.num` are the standard numeric dictionaries. Alternate
instances are ordinary `MkNum` values and must be passed explicitly. The
concrete integer family is `int.add`, `int.sub`, `int.mul`, and `int.div`; bare
names remain for compatibility. There is no implicit instance search,
operator overloading, or numeric defaulting.

Core data and common functions:

- `Bool`: `True`, `False`; `bool.and`, `bool.or`, `bool.not`,
  `bool.and-then`, `bool.or-else`; flat conjunctions `bool.all([...])` and
  `bool.any([...])`; `list.all?(xs, p)` and `list.any?(xs, p)` (stop at the
  deciding item); closed intervals `int.between?(v, lo, hi)` and
  `real.between?(v, lo, hi)` (positional)
- `Option a`: `None`, `Some`; `option.map`, `option.then`,
  `option.with-default`, `option.get!`
- `Result e a`: `Err`, `Ok`; `result.map`, `result.map-error`,
  `result.then`, `result.with-default`, `result.get!`
- `List a`: `Nil`, `Cons`; `list.map`, `filter`, `fold`, `each`, `length`,
  `reverse`, `append`, `concat`, `range`, `zip`, `sort`, `find`, `take`
- Numeric: dotted `int.add`/`sub`/`mul`/`div` and `real.add`/`sub`/`mul`/`div`;
  compatibility `add`/`sub`/`mul`/`div`; `mod`, `eq`, and `lt`; `int.*` and
  `real.*` predicates/conversions; generic calls use an explicit `Num` value.
- Text: `text.concat`, `text.join(a, b, ...)` (variadic, no separator; join a
  list with a separator by folding with `text.join(acc, separator, part)`;
  `text.join-list(parts, separator)` still works but is a deprecated
  compatibility binding), `text.split`, `text.contains?`,
  `text.slice(t, start, end)` (codepoint indexes, end exclusive),
  `text.length`, `text.from-int`, `text.to-int` (`Option Int`),
  `text.from-real-fixed(x, decimals)`,
  the singleton-codepoint classes `text.ascii-digit?`/`ascii-letter?`/
  `ascii-space?`, `text.ascii-digit-value`, `text.codepoint` (`Option Int` for
  a one-codepoint text), direct
  predicate `text.eq?`, dictionary `text.eq`, and ordering dictionary
  `text.ord`; `real.from-int` converts directly
- Maps and sets carry their comparison dictionary in the value.
- Absent by design or not yet written: `text.starts-with?`, case conversion,
  codepoint-to-text, and `int.min` (`int.max` exists). Compose them from
  `text.slice`, comparisons, and `if`.

Control effects and handlers:

- `Abort`: `abort.to-option`, `abort.or`
- `Throw`: `throw.catch`, `throw.to-result`
- `State`: `state.run`, `state.eval`
- `Emit`: `emit.collect`, `emit.pipe`
- `Fault`: `fault.none`, `fault.random`, `fault.all`
- Scoped instances: `state.scoped`, `throw.scoped`, and `emit.scoped` pass
  their body a capability (`StateRef`, `ThrowRef`, `EmitRef`) and serve only
  operations made through it (`state.get-at(ref)`, `state.put-at(ref, v)`,
  `throw.throw-at(ref, x)`, `emit.emit-at(ref, w)`), so two stores of one type
  never confuse each other.

World fixtures include `net.scripted`, `net.record`, replay handlers,
`fs.in-memory`, `fs.read-only`, `clock.fixed`, `console.scripted`, and
`console.scripted-input` (one shared line list for both input operations). These
handlers discharge or interpose on effects; they are the testing seam usually
filled by mocks in other systems.

Naming is subject-first and data-first: `list.sort(xs, int.ord)`. Predicates
end in `?`; partial/effectful variants commonly end in `!`. `debug.inspect`
is for debugging output only, not library behavior.

## Warp Tests

Warp tests are ordinary typed Jacquard definitions. Discovery is by checked
type, not filenames, annotations, or a registry. Test files may contain
declarations but no bare top-level expressions.

```jacquard doctest=skill-warp mode=check fixture=skill-warp.jac stdout=skill-warp.stdout stderr=empty exit=0
double(n) = mul(n, 2)

unit-tests =
  Group("arithmetic", [
    Case("double", fn () ->
      check.eq(double(21), 42, int.eq, int.show, "double 21")),

    Prop("doubling is even", fn () -> {
      let n = sample(UniformInt(-100, 100))
      check.eq(mod(double(n), 2), 0, int.eq, int.show, "even")
    })
  ])
```

- `Case(name, fn () -> ...)` must close at `{Check}`. This proves hermeticity.
- `Prop(name, fn () -> ...)` closes at `{Dist, Check}`. The generator is a
  distribution; seeded mode samples it and `--exhaustive` enumerates support.
- `Group(name, tests)` nests tests.
- `WorldTest`/`WCase` may use `Fs`, `Net`, `Clock`, and `Console`; it runs only
  in the explicitly granted world lane, is never cached, and is never retried
  as a hermetic test.

Useful assertions include `check.true`, `check.eq`, `check.some`,
`check.fails`, `check.throws`, `check.posterior`, and `check.same-dist`.
A case that performs zero checks warns. In sampled property mode, `observe` is
not conditioning; use `--exhaustive` when the property depends on observation.

`check.posterior` and `check.same-dist` are testing laws, not governance
authorization. GM.21's decision-bearing uncertainty path is
`judge.posterior-exact-v1`: it resolves a stored
`(GovernanceCall) ->{Dist} Risk` model by content hash, obtains an independent
baseline from the next outer Judge, performs bounded exact enumeration, and
only raises the baseline risk. `posterior.replay-exact-v1` reruns that exact
evidence. Exact `observe` accepts transparent primitive, tuple, and constructor
data; closures and opaque runtime values fail closed rather than comparing
equal through their redacted rendering. Seeded `posterior.sample-evidence-v1` returns the distinct
`NonAuthorizingApproximateRiskEvidenceV1` carrier and cannot project an
assessment or reach the gate.

Discharge world/control effects inside a `Case` with scripted handlers. If the
resulting row is exactly `{Check}`, it is a hermetic test. `Eval` has no
in-language hermetic discharger, so eval-dependent behavior belongs in a CLI
transcript test rather than a Warp unit test.

Warp's cache keys on canonical content hashes and dependencies. A comment,
format, or ordinary term-rename-only edit reruns zero tests. A canonical
dependency-content edit reruns affected dependents. Use `--no-cache` for
demonstrations and a fixed `--seed` for repeatable sampled properties.

## Identity, Formatting, And Review

`jac hash` computes `HASH_V0` over canonical structure. It erases metadata,
alpha-normalizes local binders, and hashes recursive definition groups as
units. Consequently:

- Formatting and comments do not change identity.
- Alpha-equivalent local names hash equally.
- Reordering members of a recursive SCC is stable.
- Renaming a top-level display name changes the name index, not its object.
- Provenance can change without changing the approved content hash.
- Explicit term/operation call labels are a versioned, hash-bound companion
  ABI. Binder and callable renames preserve it; a conflicting relabel is
  E0612 rather than an identity-silent API change.

Use `jac fmt --write` for canonical layout. Within each uninterrupted run of
term definitions, the formatter orders definitions so each one follows the
definitions it uses (members of one mutually recursive group keep their relative
order), so adding a call to a later definition can move the caller. A term
cannot refer forward across a `type` or `effect` declaration or a bare top-level
expression (E0301); keep terms that use each other in one run. Use stores and
`jac diff` when you need rename classification, changed canonical subtrees, or
affected dependents. `jac diff` accepts two stores or two declaration-only
source files; a source file with a bare top-level expression is refused (E0610),
so diff a program without its entry call. Its output names callees by content
hash. Hash or diff equality establishes canonical structural identity, not
general behavioral equivalence.

Record/replay logs contain operation, argument, and result triples. Strict
replay fails closed on operation or argument drift. Counterfactual `--fork`
specifications replace an effect result at a trace index; malformed specs are
diagnostics, not permissive fallbacks.

## Native Compilation

`jac build` accepts `.jac` surface input directly as well as retained `.jqd`
kernel input. It uses the same parse/lower/resolution path as check and hash,
emits C for the reachable program, links the Jacquard runtime, and asks clang
or gcc to compile with optimization and LTO. It does not generate a persistent
bootstrap twin. For programs within the documented native subset, native and
interpreted behavior are expected to be byte-identical for stdout, stderr, and
exit status.

```sh
# Installed releases discover the runtime automatically. In a checkout only:
export JACQUARD_RUNTIME=/path/to/jacquard/runtime
jac build program.jac -o program
./program --allow console --seed 42
```

`jac export INPUT.jac -o OUTPUT.jqd` is the explicit conformance/debug escape
hatch. Under the same prelude context, repeated exports are byte-identical and
reparse to the same semantic top/member hashes; quoted constructor and
operation intent remains encoded with `surface-ref-v0`. Publication is atomic
and refuses an existing destination. The canonical bootstrap output erases
comments, formatting, spans, documentation, and provenance metadata by design.
It also contains only positional kernel applications and carries no
`call-abi-v1` companion, so an exported `.jqd` declaration cannot by itself
teach another surface source file its labels. The store companion is the
cross-file named-call boundary.
Export validates parsing, resolution, and canonical identity, but does not
typecheck; use `jac check`, `jac run`, or `jac build` for that guarantee.
Materialize stdin or other non-seekable input before export.

The backend supports deep handlers with both reusable `multi` continuations and
affine `once` resumptions, including the E0906 repeated-resume backstop. It also
supports Dist, quotes, splices, and structural Code operations. Its implemented
root grants are `console`, `clock`, `fs`, `dist`, and `infer`. Dynamic `eval`,
interpreter root Task scheduling, and typed Channels do not compile as native
execution features; `eval` reports E1102, while unsupported native grants are
refused with E1103. `--dry-run` and `--infer-cache` are interpreter tooling and
compiled binaries refuse them. A C toolchain is required. Deep non-tail
recursion uses the configured program stack; set `JACQUARD_STACK_MB` if needed.
Compiled units cache under `.jacquard-native/` by content hash.

Native binaries do not count `--fuel`; bound execution with the interpreter.
This is an AOT research backend, not a production optimizer, VM, or JIT. Do
not infer broad performance claims from a single benchmark.

## Licensing User Programs And Output

Jacquard itself is Apache-2.0. Jacquard claims no copyright in source
merely because it is written, checked, interpreted, or compiled with Jacquard.
Native executables link Jacquard runtime material, so the Jacquard Runtime and
Generated Output Permission explicitly permits user programs and compiled
output to use any license their authors choose, including proprietary terms.

The permission supplements Apache-2.0 for Runtime Material embedded in compiled
programs and generated output; the compiler and separately distributed runtime
source remain under Apache-2.0. See `RUNTIME-EXCEPTION.md`, `LICENSE`, and
`NOTICE`. This summarizes project licensing intent and is not legal advice.

## Bootstrap Carrier

`.jqd` is the permanent kernel/debug carrier used by the prelude, replay,
explicit export, and implementation fixtures. It is an s-expression encoding
of 27 fixed kernel forms. Native build also accepts `.jqd`, but ordinary users
should write and build `.jac` directly. Bootstrap calls are always positional;
there is no named-argument grammar in `.jqd`.

The expression heads are `lit`, `var`, `ref`, `lam`, `app`, `let`, `match`,
`tuple`, `handle`, `quote`, `unquote`, and `ann`; pattern heads are `pwild`,
`pvar`, `plit`, `pcon`, `ptuple`, and `pas`; declarations are `defterm`,
`deftype`, and `defeffect`. `;` starts a bootstrap comment.

```lisp
; add(1, 2)
(app (var add) (lit 1) (lit 2))

; fn (x) -> mul(x, x)
(lam ((pvar x)) (app (var mul) (var x) (var x)))
```

When both carriers exist, surface and bootstrap twins lower to the same kernel
and must hash equally. Ordinary programs and demos should not maintain a
hand-written `.jqd` twin; paired carriers are curated conformance fixtures.
Do not invent new kernel forms for surface sugar.

## Failure Modes And Limits

- No ambient authority: missing grants are expected refusals, not runtime
  configuration bugs.
- No null, records, modules/imports, guards, or-patterns, custom operators,
  or implicit traits/typeclasses (constructor field accessors and setters are
  generated only for labels every constructor carries; `Ctor(value with
  label: e)` is nominal, not a record update). Explicit
  dictionaries are ordinary values.
- The interpreter ships deterministic structured Tasks, cooperative
  cancellation, bounded schedule exploration/replay, and scoped typed
  Channels. It does not ship preemption, host threads, asynchronous host I/O,
  native Task scheduling, native Channels, select/timeouts, actors, or
  supervision.
- HB.0 documents the language-neutral host ownership and trust boundary, and
  HB.1 freezes `jacquard-host-v0` envelopes, provisional process framing,
  limits, stable failures, and schema/state vectors. `Host_protocol_v0`
  implements the strict framing/selection/shutdown codec for HB.2a and the
  shared-budget first-order type/value codecs for HB.2b1; reuse it instead of
  recreating framing or value semantics. HB.2b2 also preflights one exact
  public stored term closure, closed monomorphic interface, typed positional
  arguments, exact effect grants, and sorted unique public `once` operation
  registry. `Host_protocol_v0.Session` validates serial responses, accounts
  for bounded evidence, and returns request/resume/terminal actions
  (`host-session-v0.md`). HB.2c ships `jac host worker --store DIR`, the
  opt-in serial process carrier that evaluates one preflighted invocation over
  stdin/stdout frames (`host-worker-v0.md`). HB.3 publishes the executable
  conformance kit under `spec/host-protocol-v0/kit/` with its evidence pack in
  `docs/release/host-boundary/`. Independent Python, TypeScript, and Go
  adapters in the separate
  [jacquard-host](https://github.com/jbwinters/jacquard-host) repository share
  one pinned Core release and replay it in full. No stable foreign-host ABI,
  adapter, or HTTP server ships here.
  Internal evaluator-capture and host-readiness OCaml APIs are not supported
  embedding contracts; future adapters must consume the versioned protocol and
  its executable conformance fixtures, not those OCaml seams.
- The frozen Workspace v0 governed membrane ships as an evidence-backed
  research reference. It is not a general isolation mechanism, production
  authorization system, or operating-system sandbox; trusted host code still
  owns identity, persistence, live drivers, and final execution.
- Probability is finite/discrete: no continuous distributions or gradients.
- Quote/eval is untyped staging; there is no typed staging or macro expander.
- No Jacquard package manager, dependency solver, registry trust model, or
  self-hosting compiler.
- Row soundness and handler semantics have extensive executable evidence but
  no machine-checked formal proof.
- `--allow fs` and `--allow net` are coarse effect grants; use host sandboxing
  and interposed handlers when narrower authority is required.
- Eight or more structurally identical members in one definition group may be
  rejected as canonically ambiguous (E0505).
- Process substitution is not seekable input for `jac run`; use a real file.
- `jac test` rejects bare top-level expressions in test files (E1001).
- `--dry-run` refuses a program whose row includes `Eval` (E1002).
- A local `let rec` whose body performs an effect can fail row inference
  (E0801); annotate the recursive call with its type or use a top-level
  recursive definition.
- W1201 warns when a parameter is named like a constructor in scope (`job`
  for `Job`, `allow` for the prelude's `Allow`); rename the parameter.

## Recommended Agent Workflow

1. Write and build public code in `.jac`; use `.jqd` only for explicit
   export, replay, prelude, or implementation-fixture boundaries above.
2. Run `jac fmt --write FILE.jac`.
3. Run `jac check FILE.jac --print-sigs` and review every inferred effect.
4. For deployment, run `jac check FILE.jac --manifest ...` with the intended
   grant set before `jac run`.
5. Add hermetic behavior to Warp `Case`/`Prop` tests. Put real-world checks in
   the explicit world lane and eval/CLI behavior in transcript tests.
6. Fix seeds for every sampled run. Prefer exact enumeration for small finite
   models and exhaustive properties.
7. Use content hashes and canonical diff for approvals; do not approve mutable
   paths or source appearance alone.
8. Treat diagnostics as the contract. Do not catch broad failures, add grants,
   relax manifests, or update expected transcripts without understanding the
   semantic change.
9. Keep generated code's required authority no broader than necessary.
10. Preserve the fixed kernel and current non-goals unless a reviewed language
    decision explicitly changes them.
