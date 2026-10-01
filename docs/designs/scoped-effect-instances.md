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

(These rules, and the guarantees stated for them, cover the statically typed
fragment: programs that do not use the result of unchecked `eval`; see A1.2.)

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

- Status: amendment to the approved design, from review rounds of the slice-1
  checker plan and of this amendment against the shipped checker. It fixes how
  §4 is implemented and records the limits that follow; it does not change the
  API, the dispatch rule (§4), or the compatibility freeze (§6).
- Date: 2026-10-01.

§4's "Row determinacy" paragraph assumed every instance label in a row is fixed
by unifying a capability before the row is compared ("row unification never has
to choose"). The shipped checker is Hindley-Milner with level-based
generalization and a fixed unification order, so that does not hold by itself.
A1.3 and A1.6 supersede that paragraph.

### A1.1 Representation

- A row keeps its ambient part exactly as today and gains instance entries
  `(instance effect, label, payload)`. A label is a rigid label minted per
  checked `*.scoped` call, a label variable (generalized like a type
  variable), or a label skolem in a rigid signature proof. Labels are their own
  sort: a label position (a capability's first type argument, an entry's label)
  unifies only with labels, never with any type (constructors, tuples, arrows,
  type variables, type skolems, exact thunks).
- Two entries are the same entry when their effects are equal and their labels
  are identical after resolution. Normalization merges identical entries and
  unifies their payloads, repeating until no two entries are identical (a merge
  can make labels nested in payloads identical). A payload conflict found there
  is an ordinary type error, never an internal one: unification is not
  transactional, so a failed unification can leave such a state, and diagnostic
  rendering must survive it.
- Every walker covers instance labels and payloads: occurrence and level
  adjustment, instantiation, cloning, quantification, lonely-tail closing,
  `skolems` (so a clause skolem stored only in an entry's payload is still seen
  by the handler escape check), display, and the new label walker.
- Each label determines one payload because a label enters a row only through a
  capability (A1.2), capability types are invariant (unified, never joined; the
  join consults the checker's registration), and capabilities are opaque.

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
- **Unchecked evaluation is outside the static guarantee.** `eval` of quoted
  code is checked independently, and its result type is unconstrained and
  unrelated to its input. A program can therefore disguise one live capability
  as another (`eval-code(quote { fn (x) -> x })(count)` typed as `log`'s
  capability), or store an ill-typed payload in an instance
  (`state.put-at(c, eval-code(quote { "wrong" }))` in an `Int` store). The
  non-escape and payload-agreement guarantees of §4 and this amendment hold
  only for the statically typed fragment: programs that do not use the result
  of unchecked `eval`. The stale-capability trap still catches a capability
  whose handler has returned.

### A1.3 No inferred instance identification

Unification never decides that two distinct label variables, or a label variable
and a different label, name the same instance merely because two rows are
compared. After identical entries cancel, remaining instance entries are kept
distinct: an open row absorbs them, and a closed, rigid or same-tail row that
lacks a matching entry is a type error, exactly as for any other effect. Labels
are identified only by unifying capability types. There is no deferral or
constraint queue: every row comparison is solved where it happens, so every row
consumer (handler subtraction and skolem check, scoped subtraction and escape
check, exactness, purity, publication) sees a settled row.

**Limit L1 (pinned by tests).** Where a closed, rigid or same-tail row (or an
exact comparison, A1.8) would require two labels to be identified before the
capability types that relate them are unified, or where nothing ever relates
them, the program is refused although it may be safe. Examples, with an
annotated `use : (() ->{state-instance} (), StateRef Int) ->{state-instance} ()`:

- `state.scoped(0, fn (c) -> use(fn () -> state.put-at(c, 2), c))` is refused,
  because the thunk's row meets `use`'s closed parameter row before `c` meets
  the capability parameter; supplying the capability first (an API ordered
  capability-first) is accepted.
- `g(c, d) = use(fn () -> state.put-at(d, 1), c)` is refused: plain HM would
  identify `c` and `d`, but no capability unification relates them; only an
  unannotated callback row is accepted.
- A definition's own rigid signature proof unifies parameters left to right,
  so `run : ((() ->{state-instance} Int) -> Int, StateRef Int) -> Int` with
  `run(k, c) = k(fn () -> state.get-at(c))` is refused; ordering the
  capability parameter first is accepted.

### A1.4 Spawn

The thunk row of `async.spawn` carries a persistent "no instance entries" flag
on its row variable. Binding a flagged row variable to a row containing an
instance entry fails with E0823; the flag passes to the new tail of any bound
row and is OR-ed when two row variables are unified; instantiation and cloning
keep it. A flagged variable may be bound to a rigid tail during a rigid
signature proof or any other rigid tail (an expression annotation's `| e`);
a rigid tail can never gain entries, so the flag is discharged there soundly,
and in a definition it survives in the published signature through the
flexible unification of the inferred type. The flag is not shown in displayed
or interface-v1 signatures, so an API diff cannot see it; interface-v1 also
erases label sharing (`pick(c, d) = c` and `= d` display alike). With an empty
registration no instance entry exists and the flag never fires.

**Limit L2 (pinned by tests).** Under SC.4 the spawn operation's row is the
child's row, and the spawning body's ambient row shares that tail. Therefore a
callback invoked by a body that spawns, directly or through any callee whose
row shares the spawned child's tail (row-polymorphic helpers such as
`bg(k) = async.spawn(k)`, `state.scoped` or `async.scope` bodies that spawn),
cannot use an instance, although it runs in the parent; for example
`par(k1, k2) = { let t = async.spawn(k1); k2(); async.await(t) }` refuses a
`k2` that uses one. Separating the child's exclusion from the parent's
inclusion needs a directional row constraint and is future work.

### A1.5 Annotations

- `StateRef s` in an expression annotation (`Ann`) gets a fresh label
  *variable*, so annotating an existing capability (`(c : StateRef Int)`)
  works. Label skolems are used only in a definition's rigid signature proof,
  which proves label polymorphism; the published signature is the flexible one.
- An instance effect named in a row annotation stands for one entry per
  capability of that effect among the parameter types of the annotated arrow and
  of arrows enclosing it *within the same annotation* (not lexically enclosing
  lambdas), counting capabilities at any depth and variance (nested in tuples,
  constructors, callback parameters and callback results). The same rule governs
  declaration types where they are allowed (A1.2). Each entry's label is that capability's label and its payload is
  the capability's payload. If there is no such capability, the annotation is
  refused (E0820).
- An annotation around the `*.scoped` head is refused; an annotated callback is
  checked against its annotation with flexible labels.

**Limit L3.** Annotations are less expressive than inference for instances:

- a capability annotation gets an independent label per occurrence, so an
  annotation cannot state that two capability positions share an instance:
  `keep : (StateRef Int) ->{} StateRef Int` with `keep(c) = c` is refused by
  its rigid proof; inference, or a generic signature (`a -> a`), keeps it;
- an expression annotation cannot describe a thunk over a lexically bound
  capability: `(fn () -> state.get-at(c) : () ->{state-instance} Int)` names no
  capability (E0820), and an annotation's `| e` is rigid and cannot absorb the
  entry; omit the annotation or annotate a function taking the capability.

### A1.6 Determinacy

At every scheme publication (local `let`, local `let rec`, SCC publication, top
level), a scheme whose instance entries mention a quantified label variable that
occurs in no capability type of the scheme is refused (E0820). This is
reachable from ordinary inference (`read-unknown() = state.get-at(loop())`), so
it is a normal refusal. Ordinary row polymorphism is unaffected: `apply(k) =
k()` mentions no instance label when published and remains usable with a scoped
thunk while its scope is live. A top-level expression whose row still holds an
instance entry or an unbound label is refused.

### A1.7 Scoped rule obligations

The handler requirements of an application or scope never contain instance
entries: the fresh entry is never added to them, and the scoped body is checked
with empty requirements.

The `*.scoped` checker form infers the initializer in the caller's ambient (its
effects charge the caller), checks the body as a lambda body, subtracts exactly
the entries `(instance effect, fresh label)`, applies the caller's handler
requirements to the outward row (as an application's callee inclusion does)
before including it, and then refuses (E0822) if the fresh label occurs in the
result type, the outward row (labels, payloads, tails), the caller's ambient
after inclusion, the handler requirements' payloads, or the types of the
enclosing environment's variables, group members and group schemes.

### A1.8 Row consumers

Authority display, manifests, purity checks (the top-level definition body
check E0815, governance, host protocol and tier classification), the
review-diff row comparison and the
exact-row predicate used by Warp's `VaryWorld` treat instance entries
explicitly. Display and authority use the deduplicated effect identities.
Exactness compares the normalized sets of `(effect, resolved label)` in which a label
variable equals only itself, never effect identities, and never defers; purity
counts instance entries, so a row of instance entries only is never pure.
Errors raised inside unification for E0820, E0822 and E0823 carry a structured
reason, so existing handlers that relabel unification failures as E0801 do not
hide them.

### A1.9 Other refused programs

Pinned by tests:

- Capabilities are invariant, so choosing between two live instances
  (`if b then c1 else c2`, `[c1, c2]`) is refused.
- Lambda-bound operations and callbacks are monomorphic (rank-1), so
  `both(f, c1, c2) = { f(c1); f(c2) }` is refused when applied to distinct
  instances; likewise recursive calls within one definition group identify the
  labels they pass (the group is monomorphic until published), and annotations
  do not help there.
- No rank-2 (runST) callbacks: a lambda-bound callback cannot receive a
  capability, or a thunk over one, from a scope opened in the same function
  (`run(k) = state.scoped(0, fn (c) -> k(c))` is refused by E0822's environment
  check), beyond the wrapper refusal of §4 (E0821).
- Capabilities in nominal declarations (constructor fields, user effect
  operation signatures) are refused (E0826); a generic parameter
  (`type Counter r = Counter(r)`) carries a capability instead.

### A1.10 Slice-1 evidence

Slice 1 implements the State shape (`state-instance`, `get-at`, `put-at`,
`state.scoped`). The result and payload rules of `throw.scoped` and
`emit.scoped` are specified with slice 2, before they are registered.


Slice 1 registers the instance declarations only on test checker contexts;
production contexts have an empty registration, which a test asserts. Slice 1
is checker evidence only; runtime dispatch soundness is slice 2's.
