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
- Handlers are deep and resumptions are reusable, including multi-shot use.

This file is self-contained for public use. A repository checkout is needed
only to develop the OCaml implementation, not to install or write Jacquard.

## Install

The release installer downloads a checksum-verified binary, the standard
prelude, demos, and the C runtime used by native builds. It does not require
OCaml, opam, or Dune.

```sh
curl -fsSL https://raw.githubusercontent.com/jbwinters/jacquard-lang/jacquard-core-0.1-rc3/scripts/install.sh | sh
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

# Content store, canonical-structure diff, traces, and tiers.
jac store add STORE PROGRAM.jac
jac store rename STORE old-name new-name
jac diff STORE_A STORE_B
jac replay TRACE.jqd PROGRAM.jqd --to 12
jac replay TRACE.jqd PROGRAM.jqd --fork '4=(response 503 "down")'
jac tiers PROGRAM.jac

# Native AOT currently consumes the kernel carrier.
jac build PROGRAM.jqd -o program
./program --allow console
```

`check --manifest` checks the inferred requirements against the supplied grant
set and never runs the program. `run` loads declarations, then evaluates each
bare top-level expression in order. Important exit codes are:

- `0`: success
- `1`: checker or ordinary diagnostic failure
- `2`: runtime failure
- `3`: unhandled or ungranted effect
- `124`: command-line usage error

Use stderr for diagnostics and stdout for successful program output. Always
provide an explicit seed for reproducible sampling and property tests.

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

Reserved words are `type`, `effect`, `fn`, `let`, `rec`, `match`, `handle`,
`return`, `resume`, `quote`, `unquote`, `if`, `then`, `else`, `as`, `where`,
`forall`, and `jqd`.

### Values, Calls, And Definitions

Calls are uncurried. A function declared with two parameters is called with
two arguments in one call.

```jacquard
limit = 100

add-tax(amount, rate) = real.mul(amount, real.add(1.0, rate))

increment = fn (n) -> add(n, 1)

answer : () ->{} Int
answer() = increment(41)

answer()
```

Top-level `name = value` and `name(args) = body` create definitions. A
signature immediately before the matching definition is optional. Bare
top-level expressions are legal and run in document order. Top-level
definition bodies must be pure values; put effectful work in a function and
call it from a top-level expression.

Application may chain, so `make-adder(1)(2)` is valid when the first call
returns a function. Zero-argument functions are thunks and are called with
`()`. Parentheses group expressions.

### Blocks, Let, And Recursion

A block is one expression. Each `let` scopes over the rest of the block. A
non-final expression is sequencing whose value is discarded; the final
expression is the block's value.

```jacquard
factorial(n) = {
  let rec go(k, acc) =
    match k {
      | 0 -> acc
      | remaining -> go(sub(remaining, 1), mul(acc, remaining))
    }
  go(n, 1)
}

greet(name) = {
  console.print(text.concat("hello ", name))
  text.length(name)
}
```

Local recursive bindings must bind functions. Jacquard is strict and
evaluates arguments left to right.

### Conditionals And Matches

`if` requires both branches and is an expression:

```jacquard
sign(n) =
  if int.lt?(n, 0) then "negative"
  else if eq(n, 0) then "zero"
  else "positive"
```

`match` must be exhaustive. Patterns include `_`, fresh lowercase binders,
literals, constructors, tuples, and `as` patterns. Constructor patterns start
uppercase; a lowercase pattern always binds a new variable.

```jacquard
type Option a =
  | None
  | Some a

head(xs) =
  match xs {
    | Nil -> None
    | Cons(x, rest) as whole -> Some((x, rest, whole))
  }
```

Use a braced block when an arm sequences work:

```jacquard
report(result) =
  match result {
    | Ok(value) -> {
        console.print("ok")
        value
      }
    | Err(message) -> {
        console.print(message)
        0
      }
  }
```

Lambda and `let` patterns must be irrefutable. Match arms may use refutable
patterns. Duplicate binders are rejected. There are no guards or or-patterns.

### Tuples, Lists, And Pipe

`()` is both the unit value and unit type. `(a, b)` is a tuple. List literals
lower to `Cons`/`Nil`.

```jacquard
top-three(xs) =
  xs
  |> list.filter(fn (n) -> int.gt?(n, 0))
  |> list.map(fn (n) -> mul(n, n))
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

```jacquard
type Decision =
  | Ship
  | Canary(percent: Int)
  | Hold(reason: Text)

type Result e a =
  | Err e
  | Ok a
```

Labels document constructor fields but do not create record syntax, labeled
patterns, or generated accessors. Construct values with `Canary(5)` and match
positionally with `Canary(percent)`.

### Effects And Deep Multi-Shot Handlers

Effects declare operations. Calling an operation looks like an ordinary call;
there is no `perform` keyword.

```jacquard
effect Choice where {
  choose : () -> Bool
}

effect Abort a where {
  abort : () -> a
}
```

A handler has one mandatory return clause and operation clauses. `resume`
binds the captured continuation as an ordinary function. Calling it zero times
aborts that path, once resumes normally, and more than once forks execution.

```jacquard
all-choices(body) =
  handle body() {
    | return value -> [value]
    | choose() resume continue ->
        list.append(continue(True), continue(False))
  }
```

Handlers are deep: operations performed after `continue(...)` re-enter the
same handler. The operation-clause body itself runs outside that handler, so
performing the same operation directly in its own clause forwards outward.
The return clause also runs outside the completed handled region.

Use `resume _` when a clause deliberately never resumes:

```jacquard
to-option(body) =
  handle body() {
    | return value -> Some(value)
    | abort() resume _ -> None
  }
```

If the handled expression is not an atomic call, use two braces:

```jacquard
handle { match direction { | Up -> risky() | Down -> safe() } } {
  | return value -> Some(value)
  | abort() resume _ -> None
}
```

Handling subtracts only the handled effect from the row and forwards all other
effects. This is why one unchanged policy can run under real, replay, dry-run,
scripted, hostile, or probabilistic handlers.

### Quote, Unquote, And Code

`quote` captures unresolved surface structure as a `Code` value. `unquote`
splices a `Code` value while inside a quote.

```jacquard
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

`jqd { (bootstrap form) }` is the surface escape for a kernel form that cannot
be represented without preserving an internal grouping. It is not general
mixed-syntax authoring.

### Compact Grammar

This practical grammar covers ordinary public source:

```text
file        := top-item*
top-item    := signature | definition | type-decl | effect-decl | expression
signature   := name ":" type
definition  := name ["(" patterns? ")"] "=" expression
type-decl   := "type" Type type-vars? "=" ("|" constructor)+
effect-decl := "effect" Effect type-vars? "where" "{" op-signature* "}"

expression  := call ("|>" call)*
call        := primary ("(" expressions? ")")*
primary     := literal | name | tuple | list | block | fn | match | if
             | handle | quote | unquote | annotation
block       := "{" (let-item | expression)* "}"
let-item    := "let" ["rec"] pattern ["(" patterns? ")"] "=" expression
fn          := "fn" "(" patterns? ")" "->" expression
match       := "match" expression "{" ("|" pattern "->" expression)+ "}"
if          := "if" expression "then" expression "else" expression
handle      := "handle" (atomic | block) "{" return-clause op-clause* "}"
quote       := "quote" "{" expression "}"
unquote     := "unquote" "(" expression ")"
annotation  := "(" expression ":" type ")"

pattern     := "_" | name | literal | Constructor ["(" patterns? ")"]
             | "(" patterns? ")" | pattern "as" name
type        := type-application | tuple-type | function-type | forall-type
function-type := "(" types? ")" "->{" effects? ["|" row-var] "}" type
```

Indentation never determines structure. Calls, lists, tuples, and braced forms
allow line breaks. After `=`, `:`, `->`, `then`, `else`, and `|>`, a newline is
continuation rather than item separation.

## Capabilities And Root Authority

World effects are `Console`, `Clock`, `Fs`, `Net`, `Eval`, and `Infer`.
`Dist` is pure inference rather than world authority. Root handlers exist only
when explicitly granted:

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
- Evaluated code runs with root grants, not under an interposed attenuation
  handler. Audit its inferred requirements and grants accordingly.
- Top-level rows are closed. When an API expects an open-row thunk, eta-expand
  a named computation: `fn () -> model()`.

Never infer authority from a hand-written manifest or comment; use the checked
row. Never add a grant merely to silence a refusal without reviewing why the
row contains that effect.

## Discrete Probability With Dist

The prelude defines distribution values such as `Bernoulli(p)`,
`Categorical(weighted-pairs)`, and `UniformInt(low, high)`. Models perform
`sample` and `observe` through the `Dist` effect.

```jacquard
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

Jacquard uses explicit dictionaries instead of typeclasses. Operations that
need equality, ordering, or rendering receive `Eq`, `Ord`, or `Show` values:

```jacquard
list.sort(numbers, int.ord)
list.contains?(names, "alice", text.eq)
check.eq(actual, expected, int.eq, int.show, "same value")
```

Core data and common functions:

- `Bool`: `True`, `False`; `bool.and`, `bool.or`, `bool.not`,
  `bool.and-then`, `bool.or-else`
- `Option a`: `None`, `Some`; `option.map`, `option.then`,
  `option.with-default`, `option.get!`
- `Result e a`: `Err`, `Ok`; `result.map`, `result.map-error`,
  `result.then`, `result.with-default`, `result.get!`
- `List a`: `Nil`, `Cons`; `list.map`, `filter`, `fold`, `each`, `length`,
  `reverse`, `append`, `concat`, `range`, `zip`, `sort`, `find`, `take`
- Numeric: `add`, `sub`, `mul`, `div`, `mod`, `eq`, `lt`; `int.*` and
  `real.*` predicates/conversions; real arithmetic uses `real.add` etc.
- Text: `text.concat`, `text.join`, `text.split`, `text.contains?`,
  `text.length`, `text.from-int`, direct predicate `text.eq?`, dictionary
  `text.eq`, and ordering dictionary `text.ord`
- Maps and sets carry their comparison dictionary in the value.

Control effects and handlers:

- `Abort`: `abort.to-option`, `abort.or`
- `Throw`: `throw.catch`, `throw.to-result`
- `State`: `state.run`, `state.eval`
- `Emit`: `emit.collect`, `emit.pipe`
- `Fault`: `fault.none`, `fault.random`, `fault.all`

World fixtures include `net.scripted`, `net.record`, replay handlers,
`fs.in-memory`, `fs.read-only`, `clock.fixed`, and `console.scripted`. These
handlers discharge or interpose on effects; they are the testing seam usually
filled by mocks in other systems.

Naming is subject-first and data-first: `list.sort(xs, int.ord)`. Predicates
end in `?`; partial/effectful variants commonly end in `!`. `debug.inspect`
is for debugging output only, not library behavior.

## Warp Tests

Warp tests are ordinary typed Jacquard definitions. Discovery is by checked
type, not filenames, annotations, or a registry. Test files may contain
declarations but no bare top-level expressions.

```jacquard
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

Use `jac fmt --write` for canonical layout. Use stores and `jac diff` when you
need rename classification, changed canonical subtrees, or affected
dependents. Hash or diff equality establishes canonical structural identity,
not general behavioral equivalence.

Record/replay logs contain operation, argument, and result triples. Strict
replay fails closed on operation or argument drift. Counterfactual `--fork`
specifications replace an effect result at a trace index; malformed specs are
diagnostics, not permissive fallbacks.

## Native Compilation

`jac build` currently accepts the `.jqd` kernel carrier. It emits C for the
reachable program, links the Jacquard runtime, and asks clang or gcc to compile
with optimization and LTO. Native and interpreted behavior are expected to be
byte-identical for stdout, stderr, and exit status.

```sh
# Installed releases discover the runtime automatically. In a checkout only:
export JACQUARD_RUNTIME=/path/to/jacquard/runtime
jac build program.jqd -o program
./program --allow console --seed 42
```

The backend supports deep and multi-shot handlers, Dist, quotes, splices, and
structural Code operations. Dynamic `eval` is interpreter-only and reports
E1102 when compiled. `--dry-run` and `--infer-cache` are interpreter tooling
and compiled binaries refuse them. A C toolchain is required. Deep non-tail
recursion uses the configured program stack; set `JACQUARD_STACK_MB` if needed.
Compiled units cache under `.jacquard-native/` by content hash.

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
native build input, and implementation fixtures. It is an s-expression
encoding of 27 fixed kernel forms. Ordinary users should write `.jac`.

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
  traits/typeclasses, string interpolation, or generated field accessors.
- No concurrency or enforced effect membranes in the shipped language.
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

## Recommended Agent Workflow

1. Write public code in `.jac`; use `.jqd` only for the explicit kernel/native
   boundaries above.
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
