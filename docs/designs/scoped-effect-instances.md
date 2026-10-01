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
  `State<i>`; the result row removes it. **Non-escape:** neither the result
  type nor the payload type of any effect left in the body's row may mention
  `i` (in a capability, an arrow's latent row, or any component). The second
  half closes the route through an outer handler: in
  `emit.collect(fn () -> state.scoped(0, fn (c) -> emit(c)))` or
  `throw.to-result(fn () -> state.scoped(0, fn (c) -> { throw(c); () }))` the
  result is `()`, yet the outward `Emit`/`Throw` payload carries
  `StateRef<i> Int` to a handler that returns it after the scope has ended.
  The same holds for payload constraints the body's row propagates to the
  surrounding environment: an instance label may not appear in any of them.
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
   (2 in the pinned run). Instance typing therefore *requires* instance
   dispatch; the two cannot be adopted separately.
2. **Escape through the result, a closure, a list, a resumption result, or an outward effect payload** —
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

`test/scoped_instances_model.ml` is a calculus of about 430 lines plus a 180-line type-directed generator,
independent of the implementation. It has integers, booleans, text, lists,
annotated lambdas, `let`, `if`, one parameterized effect (State with
`scoped`/`get`/`put`), one payload-carrying effect whose values leave through
an outer handler (`emit`, gathered by `collect`), and one multi-shot effect (`amb`/`flip`, whose
continuation is resumed twice and whose results are collected). It provides
two checkers (`Instances`: rigid labels and non-escape; `Mono`: TS.0's rule
with the payload carried as a structured row entry) and a frame machine with two dispatch
rules (`By_instance`, `Nearest`). Frames are immutable, so a multi-shot
resumption copies inner handler frames exactly as the design specifies.

What a run establishes (seed 210, 20,000 type-directed programs, sizes 2–12,
mean program size 23.9 nodes, maximum 204; a run takes about 0.6 s). These are
bounded, seeded tests, not proofs:

| property | result |
|---|---|
| `Instances` + `By_instance`: every well-typed program runs without getting stuck, and its value has the checked type | 7,192 well-typed programs, 0 stuck, 0 out of fuel |
| `Mono` + `Nearest` (TS.0 today): same property | 7,137 well-typed programs, 0 stuck |
| the escape and spawn checks are load-bearing: programs they reject, run anyway | 6,405 reach a stale capability; 135 are rejected for an escape through an outward `emit` payload alone |
| `Instances` + `Nearest`: unsound | counterexamples found (at least one in the pinned run, plus the hand-written two-store case) |
| coverage among well-typed programs | 388 with nested scopes, 235 with a scope under `amb`, 316 with a closure over a capability, 909 with a `collect`; the generator also produces capability- and thunk-typed parameters, payload mismatches, and spawned work |

Targeted cases pin the two stores, same-typed instance blindness, mixed
payloads (each instance keeps its own), spawned work, each escape route,
escape through an outward effect payload, structural Mono payloads (a
string encoding of payload types in labels was not injective and let a
confused program type-check), higher-order transport and crossed thunks, and branch-local versus shared state
under multi-shot resumption.

Limits: bounded random testing, not a proof. The model has one parameterized
effect, no row variables (rows are closed sets with subsumption), monomorphic
lambdas (no let-generalization of instance labels, and annotations name
instances explicitly where the language would infer them), no `once` effects,
and `emit` as its only outward payload effect (Throw is argued from it, not
modelled). It models TS.0's unnamed operations through capabilities whose row
entry carries the payload, which is equivalent for typing because TS.0 keeps
one payload per effect label per region. One divergence: the model's
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

## 9. Amendment A1 (TS.2 implementation findings)

- Status: amendment to the approved design, from two review rounds of the
  slice-1 checker plan against the shipped checker. It refines how §4 is
  implemented and records two limits; it does not change the API, the dispatch
  rule, or the compatibility freeze.
- Date: 2026-10-01.

§4 assumed that every instance label in a row is fixed by unifying a
capability before the row is compared ("row unification never has to choose").
The shipped checker is Hindley-Milner with level-based generalization and
unifies in a fixed order, so that assumption does not hold by itself. The
amendment states what the implementation guarantees instead.

### A1.1 Representation

- A row keeps its ambient part exactly as today and gains instance entries
  `(instance effect, label, payload)`. A label is a rigid label minted per
  checked `*.scoped` call, a label variable (generalizable like a type
  variable), or a label skolem in a rigid annotation proof. Label positions
  (a capability's first type argument and an entry's label) only ever hold
  labels: binding one to a constructor, tuple or arrow is a type error.
- Two entries are the same entry when their effects are equal and their labels
  are identical after resolution. Normalization merges identical entries and
  unifies their payloads, repeating until no two entries are identical
  (merging can make labels nested in payloads identical). A payload conflict
  found there is an ordinary type error, never an internal one: unification is
  not transactional, so an earlier failed unification can leave such a state,
  and diagnostic rendering must survive it.
- Each label determines one payload because a label enters a row only through
  a capability (the operation schemes below), capability types are invariant
  (never joined, only unified), and capabilities are opaque.

### A1.2 Instance operations and capabilities

- An instance operation has a scheme at every reference, not only at direct
  calls: `get-at : forall l s. (StateRef<l> s) ->{state-instance<l>:[s]} s`.
  Aliases and higher-order transport keep the label. No ambient row entry for
  an instance effect is ever formed.
- Programs cannot construct, destructure or pattern-match a capability, and a
  capability type may not appear in a nominal constructor field or an effect
  operation signature, except in the instance effect's own operations. A
  generic container instantiated with a capability (`Box a` with
  `a := StateRef<i> s`) keeps the label visible and stays under non-escape.

### A1.3 Deferred instance-row constraints

When two rows are compared and an entry carries a label variable that is not
yet identical to an entry of the same effect on the other side, the comparison
of those rows is deferred: it is queued and retried at the next drain point
(the end of an application's argument checking, the end of a binding's
inference, before a scoped subtraction and its escape check, and before
generalization). A queued comparison whose labels are still undetermined at a
drain point is solved with the entries kept distinct. Programs with no
instance entries are unaffected: nothing is ever queued for them.

**Limit L1 (pinned by a test).** A capability whose label is determined only
after the drain point of the row that needs it, for example a lambda-bound
capability passed through a higher-order function before the thunk using it is
compared against a closed annotated row, is refused although the program is
safe. Supplying the capability first, or leaving the row unannotated, is
accepted.

### A1.4 Spawn

The thunk row of `async.spawn` carries a persistent "no instance entries"
constraint on its row variable. It survives generalization, aliases, wrappers
and returned spawners, and any binding that would add an instance entry to
that row is refused (E0823).

**Limit L2 (pinned by tests).** Under SC.4 the spawn operation's row is the
child's row, and a spawning body's ambient row shares that tail. Therefore a
callback invoked synchronously in a body that also spawns (`par(k1, k2) = {
let t = async.spawn(k1); k2(); async.await(t) }`) cannot use an instance
either, although it runs in the parent. Splitting the child's exclusion from
the parent's inclusion needs a directional row constraint and is future work.

### A1.5 Annotations

- `StateRef s` in an expression annotation (`Ann`) gets a fresh label
  *variable*, so annotating an existing capability (`(c : StateRef Int)`)
  works. Label skolems are used only in a definition's rigid signature proof,
  which proves label polymorphism; the published signature is the flexible one.
- An instance effect named in a row annotation stands for one entry per
  capability label of that effect among the parameters of the annotated arrow
  and of enclosing arrows, allocated before the rows are converted. If there is
  none, the annotation is refused (E0820).
- An annotation around the `*.scoped` head is refused; an annotated callback is
  checked against its annotation with flexible labels.

### A1.6 Determinacy

A published scheme whose instance entries mention a quantified label variable
that occurs in no capability type of the scheme is refused (E0820). This is
reachable from ordinary inference (`read-unknown() = state.get-at(loop())`),
so it is a normal refusal, not an assertion. Ordinary row polymorphism is
unaffected: `apply(k) = k()` mentions no instance label when published and
remains usable with a scoped thunk while its scope is live.

### A1.7 Row consumers

Authority display, manifests, purity checks (including governance, host
protocol and tier classification), and the exact-row predicate used by Warp's
`VaryWorld` treat instance entries explicitly: display and authority use the
deduplicated effect identities; exactness and purity compare instance entries
too, so a row of instance entries only is never pure.

### A1.8 Slice-1 evidence

Slice 1 registers the instance declarations only on test checker contexts;
production contexts have an empty registration, which a test asserts. Slice 1
is checker evidence only; runtime dispatch soundness is slice 2's.
