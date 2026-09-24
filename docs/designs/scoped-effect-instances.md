# TS.1 Scoped, Parameterized Effect Instances

- Status: design with an executable model; no language change is made by this
  document. Implementation is TS.2 (task 211).
- Date: 2026-09-24
- Base: `main` after TS.0 (effect-payload containment, PR #112).
- Model: `test/scoped_instances_model.ml`, checked by
  `test/test_scoped_instances_model.ml` (`scoped_instances_focused.exe`).

## 1. Where TS.0 Left Us

TS.0 closed a type-safety hole: operation and handler payload types were
erased because rows carried only effect hashes, so
`state.run(fn () -> { put("hi"); get() }, 0)` checked at `(Text, Int)` and
returned `("hi", "hi")`. The repair (`docs/effect-payload-containment.md`)
keeps checker-only payload constraints in rows: one constraint per effect per
handled region, preserved through arrows, aliases, annotations, and
higher-order transport; a nested complete handler starts an independent one.
It deliberately did not introduce source-level instances.

Two facts of the shipped system bound what is possible today:

1. **One payload per effect label.** `Types.row` maps each effect hash to at
   most one payload; merging unifies them (`src/types.ml`). Two `State`
   stores of different types cannot both be live in one row.
2. **Dispatch by operation identity.** A clause matches an operation by hash
   and the runtime serves an operation at the *nearest* handler covering that
   hash (`src/eval.ml`, deep handlers). There is no instance identity at run
   time, so an inner `State` handler also answers operations meant for an
   outer one.

So a program that keeps a counter and a log (an `Int` store and a `Text`
store) must declare two distinct effects today. That is the expressiveness gap
TS.1 addresses.

## 2. Requirements

- Two independent instances of one parameterized effect, with different
  payload types, usable in one scope.
- Lexical selection: an operation names the instance it targets; the nearest
  handler of the same effect does not capture it.
- Payload agreement between an instance's operations and its handler, as TS.0
  guarantees per region today.
- Polymorphic generalization of functions that take instances.
- Non-escape: an instance cannot be used after its handler has returned, by
  any route (result value, closure, list, resumption).
- Multi-shot resumptions keep the existing once/multi contracts
  (`docs/effect-linearity.md`: E0816, E0817, E0906) and Async non-laundering
  (SC.4, `docs/concurrency.md`).
- The displayed authority manifest stays a set of effect names; resource
  refinements stay with CAP.1 (task 202).

## 3. Two Candidates

**A. Explicit typed instances.** A scoped combinator introduces a fresh
instance and passes its capability to a callback:

```jacquard
report() = state.scoped(0, fn (count) ->
  state.scoped("start", fn (log) -> {
    state.put-at(count, add(state.get-at(count), 1))
    state.put-at(log, "done")
    state.get-at(count)
  }))
```

`count : StateRef<i1> Int` and `log : StateRef<i2> Text`, where `i1` and `i2`
are rigid instance labels introduced by each `state.scoped`. Rows carry
`State<i>` labels, so the two stores are distinct row entries with their own
payloads, and each `state.scoped` handles exactly its own label.

**B. Conservative monomorphic handling (status quo).** Keep one payload per
effect label and dispatch by operation identity; programs needing two stores
declare two effects (`effect Counter`, `effect Log`) or nest handlers so that
only one store is live at a time.

## 4. Decision: A, With B Kept As The Ambient Default

Existing unnamed operations (`get()`, `put(x)`, `throw(e)`, `emit(w)`) keep
their current meaning exactly: TS.0's per-region rule and nearest-handler
dispatch. They form the *ambient* instance of their effect. Instance
capabilities are opt-in and live beside them. (The sketches below write the
instance effect as `State<i>` for readability; it is the separate
`state-instance` declaration described under "Which effect".)

### Typing rules (the model's `Instances` mode)

- `state.scoped(init, fn (c) -> body)`: with `init : s`, check `body` with
  `c : StateRef<i> s` for a fresh rigid label `i`. The body's row may contain
  `State<i>`; the result row removes it. **Non-escape:** the result type must
  not mention `i` (in a capability, an arrow's latent row, or any component).
- `state.get-at(c) : s ! {State<i>}` and `state.put-at(c, v : s) : () !
  {State<i>}` for `c : StateRef<i> s`.
- Rows are sets of labels. Function types carry latent rows; a function whose
  latent row names `State<i>` can only be called where `i` is in scope, and a
  thunk over one instance is not a thunk over another.
- Generalization: a let-bound function's free instance labels are generalized
  like row variables (`bump : forall i. (StateRef<i> Int) ->{State<i>} ()`);
  inside `state.scoped` the new label is rigid, never generalized, which is
  what enforces non-escape (the runST argument).
- Display: an instance label is shown as its effect name (`state-instance`), so the
  authority manifest stays a name set. Checker diagnostics may name the
  capability binder when two instances disagree.

### Which effect the instance operations belong to

The instance operations are a **new effect declaration**, `state-instance`
(and `throw-instance`, `emit-instance`), not new operations on `State`:
adding operations to `(defeffect state …)` would change State's hash and every
identity built on it. The ambient `State` declaration and its hash are
untouched. The new effects are private in the sense scheduler carriers are:
user `handle` blocks cannot name their operations (resolution refuses them), so
only the blessed `*.scoped` combinators handle them. Without that rule a user
handler between an operation and its instance handler would capture an
operation on a capability it does not own, with its own payload type, breaking
both lexical selection and payload agreement. In rows the new effect displays
under its own name, so the authority manifest remains a set of names.

### Annotations, polymorphism, and the scoped form

- `state.scoped(init, fn (c) -> body)` is a **checker form** recognized at a
  direct call whose second argument is a literal lambda, like the frozen
  `async.spawn` rule; it is not an ordinary rank-1 function. A wrapper that
  forwards its callback (`with-counter(f) = state.scoped(0, f)`) is refused
  with a diagnostic naming the rule; this is the price of non-escape without
  rank-2 types, and it is recorded rather than inferred.
- In source annotations `StateRef s` stands for a fresh instance variable per
  occurrence, and an instance effect in a row annotation is written by effect
  name only, meaning "the instance of the capability parameter it is unified
  with". An annotation cannot name a particular instance; inference does, which
  is how a thunk over one instance is refused where a thunk over another is
  expected (the model's crossed-thunk case uses explicit labels only because
  the model has no inference). In a row annotation the effect name covers every instance
  determined by the function's capability parameters.
- **Row determinacy.** An instance label enters a row only through a value of
  capability type, so every instance variable in a row is determined by the
  type of some capability in scope. Row unification therefore never has to
  choose between `State<α>` and `State<β>` against `State<i>`: `α` and `β` are
  already unified with the labels of the capabilities that introduced them. A
  row containing an instance variable not determined this way is refused. A
  consequence, recorded as a limit: a function that takes only a thunk over an
  instance, with no capability parameter, is refused; pass the capability
  too. Aliasing a `*.scoped` combinator (`my-scoped = state.scoped`) is refused
  like a forwarding wrapper.
- **Generalization.** A let-bound function's instance variables are
  generalized like row variables when they are not free in the environment
  (`bump : forall i. (StateRef<i> Int) ->{state-instance<i>} ()`), under the
  existing value restriction (E0818); inside `state.scoped` the new label is
  rigid and is never generalized.
- Stored signatures keep instance variables quantified, so a separately
  loaded function taking a capability remains usable; a rigid label cannot
  appear in any stored signature because it cannot escape its scope.

### Spawned work (Async non-laundering)

`async.spawn`'s child runs under the scheduler, outside every handler that was
in scope where it was spawned. A spawned thunk whose row contains an instance
label would therefore perform the operation after, or outside, the instance's
handler. The rule extends SC.4: **the row of a spawned thunk may not contain an
instance label**; the spawn is refused at check time. Values read from an
instance may be handed to spawned work; capabilities may not. The model checks
this with `detach`, which runs its body after the whole program with no
handler in scope.

### Dispatch rule

An instance handler serves exactly the operations on its own capability. Each
`state.scoped` creates a runtime instance token, the capability carries it, and
the handler's clauses compare the token: a matching operation is served, any
other is re-performed outward (forwarding). An operation whose instance has no
live handler cannot occur in a well-typed program; the runtime still traps it
as a stale capability, defence in depth like E0906. The instance handler holds
its store the way `state.run` does, as the state threaded through its clauses;
a forwarding clause re-performs the operation outward with the same arguments
and resumes its continuation once with the result, leaving its own store
untouched. Dispatch costs one comparison per instance handler between an
operation and its own handler.

### Rejected counterexamples (all pinned by the model)

1. **Instance typing over operation-identity dispatch is unsound.** Typing
   the two-store program above with instance labels while the runtime still
   serves `get-at(count)` at the nearest `State` handler returns the `Text`
   store where an `Int` was promised. Generated search finds such programs
   (10 in the pinned run). Instance typing therefore *requires* instance
   dispatch; the two cannot be adopted separately.
2. **Escape through the result, a closure, a list, or a resumption result** —
   `state.scoped(0, fn (c) -> c)`, `… -> fn () -> state.get-at(c)`,
   `amb(… c …)` — is rejected by the rigid-label check; the same programs run
   under a permissive checker and hit a stale capability.
3. **A thunk over instance `a` passed where a thunk over `b` is expected** is
   rejected by row subsumption on labels.
4. **Mono only (candidate B) is rejected as the only answer**: it is sound
   (the model confirms TS.0's rule with nearest dispatch), but it cannot type
   the two-store program, and with same-typed stores it is *instance-blind*:
   a `put` meant for an outer `Int` store lands on an inner one, type-safely
   but wrongly. Programs that need two instances deserve a checked way to say
   so.

### Multi-shot and once

State operations are `multi` today. A multi-shot resumption copies the frames
it resumes: an instance scoped *inside* the resumed region is copied per
branch (each branch owns a store), and an instance scoped *outside* is shared
and threaded through the branches in order. The forwarding clause of an
instance handler resumes its continuation exactly once, so instance handlers
for `once` effects (`Emit`) satisfy E0816/E0817 unchanged, and the capability
is an ordinary value, so storing it is governed by the non-escape rule, not by
resumption affinity.

## 5. The Executable Model

`test/scoped_instances_model.ml` is a calculus of about 400 lines,
independent of the implementation. It has integers, booleans, text, lists,
annotated lambdas, `let`, `if`, one parameterized effect (State with
`scoped`/`get`/`put`), and one multi-shot effect (`amb`/`flip`, whose
continuation is resumed twice and whose results are collected). It provides
two checkers (`Instances`: rigid labels and non-escape; `Mono`: TS.0's rule
with the payload carried in the label) and a frame machine with two dispatch
rules (`By_instance`, `Nearest`). Frames are immutable, so a multi-shot
resumption copies inner handler frames exactly as the design specifies.

What a run establishes (seed 210, 20,000 type-directed programs, sizes 2–12,
mean program size 22.9 nodes, maximum 185; a run takes about 0.3 s). These are
bounded, seeded tests, not proofs:

| property | result |
|---|---|
| `Instances` + `By_instance`: every well-typed program runs without getting stuck, and its value has the checked type | 7,382 well-typed programs, 0 stuck, 0 out of fuel |
| `Mono` + `Nearest` (TS.0 today): same property | 7,400 well-typed programs, 0 stuck |
| the escape and spawn checks are load-bearing: programs they reject, run anyway | 6,421 reach a stale capability |
| `Instances` + `Nearest`: unsound | counterexamples found (at least one in the pinned run, plus the hand-written two-store case) |
| coverage among well-typed programs | 418 with nested scopes, 231 with a scope under `amb`, 343 with a closure over a capability; the generator also produces capability- and thunk-typed parameters, payload mismatches, and spawned work |

Targeted cases pin the two stores, same-typed instance blindness, mixed
payloads (each instance keeps its own), spawned work, each escape route,
higher-order transport and crossed thunks, and branch-local versus shared state
under multi-shot resumption.

Limits: bounded random testing, not a proof. The model has one parameterized
effect, no row variables (rows are closed sets with subsumption), monomorphic
lambdas (no let-generalization of instance labels, and annotations name
instances explicitly where the language would infer them), no `once` effects,
and no Throw/Emit. It models TS.0's unnamed operations through capabilities
whose label carries the payload, which is equivalent for typing because TS.0
keeps one payload per effect label per region. One divergence: the model's
Mono mode also refuses spawned work with a non-empty row, whereas shipped TS.0
charges the ambient effects of spawned work to the caller under SC.4; the
spawn rule this design adds concerns instance labels only. Generalization, row
determinacy, the wrapper refusal, and once-affinity are argued in §4, not
exercised by the model.

## 6. Compatibility Freeze

| surface | change |
|---|---|
| kernel | none: 27 forms unchanged; instance labels are checker-internal |
| `HASH_V0` and existing identities | unchanged: the instance operations live in new effect declarations (`state-instance`, …), so `State`, `Throw`, `Emit`, and everything built on them keep their hashes |
| `.jac` syntax | none: the API is prelude combinators (`state.scoped`, `state.get-at`, `state.put-at`, and Throw/Emit counterparts); `*.scoped` is a checker form at a direct call with a literal lambda, and forwarding wrappers are refused |
| type annotations | `StateRef s` is written without an instance; the checker generalizes instance labels |
| store and `names.jqd` | none |
| displayed signatures and manifests | instance labels erased to effect names |
| native | an intrinsic for the instance token and the forwarding comparison; until it lands, `jac build` refuses programs that use instances with E1101 |
| host protocol v0 | unchanged: capabilities are not first-order values and are already refused at the boundary |

## 7. Migration Matrix

| program today | after TS.2 |
|---|---|
| ambient `get`/`put`/`throw`/`emit` under one handler | unchanged: same checking, same dispatch, same hashes |
| two stores declared as two effects | unchanged; may migrate to two `state.scoped` instances |
| nested handlers used to keep one store live at a time | unchanged; may migrate |
| a program TS.0 rejects for a payload conflict between two intended stores | expressible with two instances |

No existing program changes meaning, and nothing is deprecated.

## 8. Implementation Slices For TS.2 (task 211)

1. **Checker**: row entries keyed by (effect, instance) with the ambient
   instance as today; rigid-label introduction for the blessed `*.scoped`
   combinators (a checker rule like the frozen `async.spawn` special case) and
   the wrapper refusal; non-escape; row determinacy; instance generalization;
   the spawn rule; refusal of user clauses for the instance effects. Regression: every
   TS.0 case and the model's rejected counterexamples as checker tests.
2. **Runtime and prelude**: an instance-token builtin, forwarding instance
   handlers for State, Throw, and Emit, and the stale-capability trap.
   Interpreter tests mirror the model's targeted cases.
3. **Native**: the intrinsic and differential tests; E1101 until then.
4. **Docs**: stdlib entries, a migration note, and the two-store example.

Each slice lands independently; slice 1 alone must refuse the instance
combinators (they do not exist yet) and change nothing else.
