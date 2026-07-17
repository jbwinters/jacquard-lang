# Structured Concurrency Contract

Status: SC.16 publishes the C0-C2 evidence and limits for SC.12 budgeted
exhaustive schedule enumeration and SC.11 seeded randomized schedule testing
over SC.10 versioned scheduler traces and strict replay, SC.9 deterministic
round-robin, SC.8 fail-fast/collect scope policies, SC.7 cooperative
cancellation, SC.6 structured-scope ownership, the SC.5
policy-independent lifecycle core, and the SC.4 generalized child-effect law
(D46-D50), July 2026. This document is authoritative for C1's static
non-laundering law, lifecycle and nested ownership, cancellation delivery, and
homogeneous scope aggregation, plus C2's record/replay and seeded decision
policies. SC.14 also ships the C3 scoped typed-Channel runtime through those
same deterministic, seeded, replay, exhaustive, and cached interpreter routes.
The default CLI, prelude-evaluation, and Warp Case paths drive real evaluator
states and affine continuations through the Async and Channel scheduler.
Native root scheduling, native Channel execution, host scheduling, host
asynchronous I/O, and actors remain outside this gate and are deferred to C4.

Structured concurrency is an effect interpreted by a scheduler handler. The
same program can therefore run under deterministic, seeded-random, exhaustive,
or replay scheduling without hiding world authority in a runtime API. All Async
operations are `once`, as required by the effect-linearity contract.

## 1. The one law

**Every child effect is charged to the parent row.** The exact bootstrap
interface is:

```text
(deftype task-id () (con task-id-opaque))         ; scheduler-private carrier
(deftype task ((tvar a)) (con task-opaque))       ; scheduler-private carrier
(deftype task-result ((tvar a))
  (con done (field value (tvar a)))
  (con failed (field message (tref text)))
  (con cancelled))
(defeffect async ((tvar a))
  (op async.spawn once
    ((tarrow () (row (eref async) e) (tvar a)))
    (tapp (tref task) (tvar a)))
  (op async.await once
    ((tapp (tref task) (tvar a)))
    (tapp (tref task-result) (tvar a)))
  (op async.cancel once ((tapp (tref task) (tvar a))) (ttuple))
  (op async.yield once () (ttuple)))
```

`task-id-opaque` and `task-opaque` are identity carriers in bootstrap data,
like the primitive opaque constructors. They are never installed in the public
constructor index; only the scheduler can create their runtime values.

In surface notation the law-bearing operation is exactly:

```text
async.spawn : (() ->{Async | e} a) -> Task a
```

Calling it contributes both `Async` and the solved child row `e` to the caller.
Merely checking the parameter type is insufficient: unification could absorb
`Net` into `e` and then discard it. SC.4 therefore gives the exact frozen
operation a dependent scheme whose thunk row and callable row are the same row
object. That dependency travels with the value through aliases, wrappers,
returned closures, tuples, and independent polymorphic instantiations. It is
not a syntax-directed application exception.

The identity guard applies only to the resolved operation whose complete
declaration is the exact four-operation interface above. The nominal HASH_V0
identities are `Task`
`07791255b44e18c3830038c51396bd3f80cf44a8e89222ff73dc90dd06ec3fb3`,
`TaskResult`
`915f69bd6fd8b34c2794b4b0e7ca88f5aafd0187e5c7c36a59091f6d031405ae`,
and `Async`
`4ff8ce05ab09968163492b3be40fc91381b47dee5fb4b2980f9416d50f38e66f`.
These are structurally derived identities, not name permissions: the checker
also validates the exact effect variable, operation order/names/modes,
parameter/result linkage, Task identities, and open self row. This executable
fixture pins both charging and handler subtraction. If a future checker change
makes that validated kernel shape disagree with its converted parameter type,
the checker fails closed with E0805 rather than raising an internal assertion.
`async.scope` here is
compile-only handler scaffolding. Its spawn clause terminates the synthetic
handler answer instead of constructing the scheduler-private `TaskOpaque`
carrier; the clauses are never executed and are not a Task runtime
implementation.

```jacquard doctest=concurrency-row-contract mode=check fixture=concurrency-row-contract.jac stdout=concurrency-row-contract.stdout stderr=empty exit=0
type Task a = | TaskOpaque
type TaskResult a = | Done(value: a) | Failed(message: Text) | Cancelled

once effect Async a where {
  async.spawn : (() ->{Async | e} a) -> Task a
  async.await : (Task a) -> TaskResult a
  async.cancel : (Task a) -> ()
  async.yield : () -> ()
}

async.scope(body) =
  handle body() {
    | return value -> Done(value)
    | async.spawn(_) resume continue -> Cancelled
    | async.await(_) resume continue -> continue(Cancelled)
    | async.cancel(_) resume continue -> continue(())
    | async.yield() resume continue -> continue(())
  }

spawn-net() = async.spawn(fn () -> net.get("https://example.invalid"))

spawn-alias = async.spawn

alias-net() = spawn-alias(fn () -> net.get("https://example.invalid"))

forward(spawner, child) = spawner(child)

wrapped-net() = forward(async.spawn, fn () -> net.get("https://example.invalid"))

make-spawner() = fn (child) -> async.spawn(child)

returned-net() = make-spawner()(fn () -> net.get("https://example.invalid"))

spawn-bundle = (async.spawn, 0)

tuple-net() = {
  let (spawner, _) = spawn-bundle
  spawner(fn () -> net.get("https://example.invalid"))
}

wrapped-fs() = forward(async.spawn, fn () -> read("child-effects.txt"))

scoped-net() =
  async.scope(fn () -> {
    let child = async.spawn(fn () -> net.get("https://example.invalid"))
    async.await(child)
  })

nested-scoped-net() =
  async.scope(fn () ->
    async.scope(fn () -> {
      let child = async.spawn(fn () -> net.get("https://example.invalid"))
      async.await(child)
    }))

fetch-all(urls) =
  async.scope(fn () -> {
    let tasks = list.map(urls, fn (url) -> async.spawn(fn () -> net.get(url)))
    list.map(tasks, fn (task) -> async.await(task))
  })
```

The mutation guard refuses the formerly laundering annotation:

```jacquard doctest=concurrency-row-laundering mode=check fixture=concurrency-row-laundering.jac stdout=empty stderr=concurrency-row-laundering.stderr exit=1
type Task a = | TaskOpaque
type TaskResult a = | Done(value: a) | Failed(message: Text) | Cancelled

once effect Async a where {
  async.spawn : (() ->{Async | e} a) -> Task a
  async.await : (Task a) -> TaskResult a
  async.cancel : (Task a) -> ()
  async.yield : () -> ()
}

launder : () ->{Async} Task Text
launder() = async.spawn(fn () -> net.get("https://example.invalid"))
```

The fixture is the SC.4 closure proof: every transport route retains `Async`
and the child's world effects. The two uses of `forward` independently solve
the shared row to `Net` and `Fs`; nested scopes remove only `Async`. The
documented aggregate therefore has the pinned signature:

```text
fetch-all : (List Text) ->{Net} TaskResult (List (TaskResult Text))
```

Negative checker and manifest crams use the same complete frozen four-operation
declaration to cover a misleading closed annotation through an alias and an
adversarial same-tail row cycle. The annotation diagnostic retains the
propagated `Net` effect, the row-cycle primary span identifies `async.spawn`,
and the missing-grant diagnostic preserves `net.get` as the child effect source.

## 2. Task identity and lifecycle

`Task a` is an opaque, scheduler-owned, run-local handle. It has no public
constructor, `Show`, canonical serialization, equality, or cross-run reuse.
`TaskResult a` is exactly `Done(value: a) | Failed(message: Text) | Cancelled`.
The failure payload is stable text, not an exception or an erased value.

Internally a task ID is `(scope-path, spawn-index)`. The root scope path is
`[0]`. A scope body has index 0; children receive one-based indices in spawn
creation order. Each nested scope appends its one-based scope-creation ordinal
within its parent. Components never depend on addresses, hashes, hash-table
iteration, or host timing. IDs appear in scheduler traces and diagnostics but
are not Jacquard values in C1. Their only stable text encoding is `path#spawn`,
with path components separated by `/`: root child 1 is `0#1`, and task 3 in
the second nested scope is `0/2#3`. Components and spawn indices are unsigned
32-bit values. A path has at most 65,532 components, matching the native
unsigned-16-bit block-length domain including its three metadata words.

SC.3 exposes no public evaluator or library constructor for Task values. A
private, unforgeable capability is required to wrap or unwrap the scheduler's
opaque handles. Every `Round_robin` invocation allocates a fresh Task run even
when it reuses an evaluator context, then dynamically binds validation to the
active run and scope while a scheduler step executes.
The run-identity, capability, and raw-handle modules are all absent from the
installed public CMI set; external OCaml clients can use `Round_robin` but
cannot name `Concurrency_owner.create`, `Task_capability.runtime`, or
`Task_handle.create_run`.
Every evaluator entry, native callback result, captured result, and terminal
machine result recursively validates Task ownership, including Tasks nested in
tuples, constructors, closures, and resumptions. Reusable validated states and
captured continuations are sealed to the exact evaluator context that validated
or captured them. Running or resuming them under another context fails with
E0907 before execution or affine-continuation consumption. Same-context
inference samples retain the scan-free validated-state path.

States are `runnable`, `suspended`, `done`, `failed`, and `cancelled`. A task has
one owning scope and at most one live affine continuation. Every task spawned in
a scope must reach a terminal state before that scope returns. Scope exit
cancels unfinished children and drains them to terminal states.

Returning or storing a Task beyond its creating scope, using it after scope
close, or using it in a different scope/run is the v0 dynamic defect:

```text
error[E0907]: a Task may not escape, outlive, or be used outside the structured scope that created it
```

Rank-2 static scoping is future work, not a C1 claim.

Any number of tasks in the same owning scope may await one Task. A terminal
result is immutable and every waiter receives that same typed `TaskResult`;
waiters wake in registration order. Awaiting an already terminal task returns
immediately. Self-await and a closed await cycle are scheduler-detected task
failures, never a host deadlock. The exact templates are
`async deadlock: task ID awaited itself` and
`async deadlock: await cycle ID -> ... -> ID`, using the stable ID encoding
above. Cross-scope or stale awaits are E0907 instead.

The SC.5 scheduler core implements this lifecycle as a policy-independent state
machine. Runnable and suspended tasks may own at most one opaque affine resume
token; destructive checkout transfers that ownership to the handler, and
yield/await suspension returns exactly one token. Terminal transitions clear
the token, retain one immutable `TaskResult`, remove the task's await edge, and
wake registered waiters in registration order. Scope cleanup clears every edge
and transfers any still-owned tokens for explicit destruction. Illegal state or
ownership transitions return E0908 diagnostics and never surface user-caused
OCaml exceptions. The core reports runnable task IDs but contains no runnable
queue, scheduling policy, host thread, host I/O, or root Async handler.
Cycle failure terminalizes every member and drops every member resume before
reporting wakeups, so only live external waiters can enter the runnable output.
Those external wakeups are grouped by cycle discovery order, with registration
order preserved within each member; cancelled or otherwise terminal waiters are
removed before the groups are emitted.

SC.6 layers `Structured_scope` over that core. A root opens path `[0]`; each
nested scope shares the same opaque run and appends its deterministic one-based
creation ordinal. Scope operations validate the exact open owner before
delegating to the lifecycle core. Normal return, result-level abort, and a host
exception all run the same recursive close: descendants close first, unfinished
tasks become cancelled, wait edges disappear, and every still-owned affine
resume is passed exactly once to an explicit destruction callback. Recursive
metrics count open scopes, live/runnable tasks, and owned resumes; every count
is zero before the bracket returns or re-raises. Thus no child continuation
remains scheduler-runnable after its owner returns.

The dynamic exit guard rejects E0907 even when a Task is hidden in a tuple,
constructor, closure cell, cyclic closure environment, or resumption. Closing a
scope rejects handles created at that path or any descendant path; an
enclosing-scope handle observed while a nested scope closes remains valid.
Cleanup completes before an escape diagnostic is returned. Every subsequent
operation through the closed scope reports E0907 rather than exposing an
internal lifecycle transition.

SC.7 adds an atomic cancellation boundary to the lifecycle core and explicit
cooperative operations to `Structured_scope`. Await checks before registering
a waiter, yield checks before returning a suspended continuation, and routed
effects check before invoking their action. Delivery terminalizes the task as
`Cancelled`, wakes existing waiters in registration order, and transfers the
boundary continuation exactly once to the destruction callback. The layer
still contains no runnable queue, scheduling policy, or root Async handler.
The cancellation regression pins the full waiter handoff: each registered
waiter becomes runnable in registration order, owns its resume again, and
observes the same immutable `Cancelled` result when it awaits the target again.

## 3. Scope APIs and failure shapes

The general handler and homogeneous convenience APIs are frozen as:

```text
async.scope : (() ->{Async | e} a) ->{| e} TaskResult a
async.scope-fail-fast : (List (() ->{Async | e} a)) ->{| e} TaskResult (List a)
async.scope-collect : (List (() ->{Async | e} a)) ->{| e} List (TaskResult a)
```

`async.scope` uses fail-fast by default. It discharges only `Async`; all child
world effects remain in `e`. Its body may spawn, await, cancel, and yield
directly. A successfully returned body value is `Done`; the first child
non-success selected by scheduler decision order is its exact `Failed` or
`Cancelled` result.

`async.scope-fail-fast` is the homogeneous aggregate: `Done(values)` preserves
input/creation order. The first scheduler-ordered `Failed` or `Cancelled`
cancels unfinished siblings and returns no partial value list.
`async.scope-collect` never cancels siblings merely because one failed and
returns one `TaskResult` per input, in input/creation order. These separate
shapes avoid pretending that
heterogeneously typed child values can inhabit one list. Within a general scope,
programs obtain heterogeneous typed results explicitly with `async.await`.

SC.8 implements these two policies in `Scope_policy`. A controller registers an
ordered same-scope child list and consumes terminal observations carrying a
strictly increasing lexicographic `(D46 decision, sub-observation ordinal)`
pair. The ordinal is zero for the first terminal observed in a step and rises
in stable scope-child order when one step terminalizes more children through
fail-fast cancellation. Fail-fast is the default. Its
first observed `Failed(message)` or `Cancelled` freezes that exact non-success,
requests cancellation of each unfinished sibling in input order, and
immediately delivers already-suspended siblings through the SC.7 destruction
callback. A runnable sibling retains the request until its next cancellation
boundary; neither a later failure nor a later cancellation can replace the
earlier decision.

The terminal decision and result are committed before sibling cancellation is
attempted. Cancellation diagnostics or an exception from the destruction
callback do not roll back that observation. Cleanup still attempts every
sibling in input order, and the first destruction-callback exception is
re-raised with its original backtrace only after all sibling cleanup attempts
finish. The policy layer catches each user callback failure around the SC.7
delivery call, allowing that call to return its awakened waiters without
changing the public SC.7 primitive. Finish is legal only after every registered
child is terminal, preserving the structured drain invariant.

An immediate sibling cancellation can wake tasks already awaiting that sibling.
The policy controller retains those handles even when the same delivery's user
destruction callback raises, in sibling-input order and each target's
waiter-registration order. A scheduler drains them exactly once through
`Scope_policy.take_awakened` before its next choice; the policy layer never
silently discards or independently schedules them.

Collect never requests sibling cancellation. It waits for every registered
child and returns the immutable terminal results in input order, independently
of terminal observation order. Zero children produce `Done([])` under
fail-fast and `[]` under collect. These controllers consume scheduler decisions
but do not create a runnable queue, choose a task, resume a continuation,
consult host timing, or install a root handler.

## 4. Cancellation and resources

Cancellation is cooperative and becomes observable only at these suspension
points, in this exact contract order:

1. `async.await`;
2. `async.yield`; and
3. any effect operation routed through the scheduler, including Async
   operations and scheduler-mediated world operations.

There is no preemption between those boundaries. A child that spins forever
without reaching await, yield, or a routed effect cannot observe a pending
cancellation request and can therefore prevent fail-fast scope drain. C1 makes
no progress guarantee for such a child.

At every boundary the scheduler checks an already requested cancellation
before executing the routed operation. Thus cancellation delivered at spawn
creates no child, and cancellation delivered at await registers no waiter.
Otherwise `async.cancel(target)` atomically requests target cancellation and
returns unit. Delivery changes the target to `cancelled` once and drops its
affine continuation. Cancel of an already terminal or already requested task is
an idempotent no-op. A task cancelling itself observes cancellation at that
`async.cancel` routing point. No user expression after delivered cancellation
runs.

The compiled seam makes continuation ownership explicit. A successful boundary
returns the resume token to its caller; a delivered boundary destroys it and
returns only awakened handles. A cancel routed by task A first checks A's own
pending request. If A may continue, it requests cancellation of the target.
A suspended target is delivered immediately and its scheduler-owned resume is
destroyed; a runnable target retains an idempotent request until its next
boundary. A completed, failed, cancelled, or already-requested target is a
deterministic no-op. The second caller-boundary check after requesting the
target exists specifically for self-cancel: it requests and delivers at the
same routed boundary, so the caller receives no continuation with which to
execute a later user expression. Re-entering a boundary with an already
cancelled task also destroys the supplied stale continuation and wakes nobody.

Cancellation state and ownership change before the destruction callback runs.
The callback is a runtime destruction primitive and must normally not raise. If
it does raise, that exception propagates, but the task remains terminal and the
scheduler does not re-own the transferred continuation. In particular, a
second delivery of the same suspended-task cancellation neither transfers nor
destroys that continuation again.

Dropping a continuation releases language/runtime memory; it does not release
an external resource automatically. Acquire/release handlers (the bracket or
`with-file` pattern) are the required C1 idiom for resources crossing a
suspension point. `Structured_scope.protect` is the implementation bracket for
continuation ownership: it closes on normal, result-abort, and host-exception
paths before returning or re-raising, and cleanup attempts every still-owned
resume even when a destruction callback raises. A cleanup exception propagates
after an otherwise successful body. Original result-level diagnostics or a host
exception and its raw backtrace take precedence over cleanup exceptions. It is
not an external-resource finalizer, and language finalizers remain explicitly
deferred.

## 5. Deterministic schedule order

D46 fixes the default scheduler to FIFO round-robin over the runnable queue:

1. A decision records a zero-based sequence number, the exact pre-decision
   runnable queue, and its chosen head.
2. A still-runnable task that suspends is appended after tasks already runnable.
3. `spawn` atomically assigns the next task ID, appends the child, then appends
   the suspended parent. With no sibling already queued, the child runs next.
4. `await` on a live task blocks the waiter; terminal completion wakes waiters
   in waiter-registration order and appends them to the tail.
5. Results and collect aggregates are rendered in creation/input order, never
   completion order. Multiple terminals discovered by one step use the stable
   sub-observation ordinal after that step's D46 decision number.

The host scheduler is never consulted by this default. Seeded-random,
Choose-driven exhaustive, and host scheduling are separate handlers over the
same decision boundary. SC.10 record/replay validates the full runnable queue
and chosen ID before divergent user or world work executes. SC.12 uses that
strict fork seam to implement bounded exhaustive choice.

SC.9 implements this boundary in `Round_robin`. Each scheduler step renders the
exact pre-decision queue and chosen head before advancing one real `Eval.state`
to an Async operation, routed world operation, return, or failure. One global
FIFO, decision sequence, trace, task/live counter, and pair of configured bounds
cover the root and every nested scope. Opening `async.scope` suspends its parent
and appends the nested body behind tasks already runnable; nested completion
requeues that parent. There is no recursive sub-scheduler. The queue contains
only handles whose deterministic IDs appear in the decision; task discovery and
wakeup order come from spawn-ordered lifecycle state and registration-ordered
waiter lists, never hash-table iteration. Spawn appends child then parent, a
blocked await removes its waiter, completion appends awakened waiters, and yield
appends its current task. Cancellation remains cooperative at the three SC.7
boundaries.

Each selected task advances inside an affine checkout bracket. If a scheduler
step returns a diagnostic or a host exception before settling the token, the
bracket restores scheduler ownership first; a host exception is then re-raised
as the same physical value with its original raw backtrace.

Policy traces include `policy-observe decision=N ordinal=M task=ID`, directly
linking every child terminal observation to the D46 step that caused it.
`Task` values are real opaque evaluator values with a fresh scheduler-run owner
and exact scope path. The recursive value guard rejects E0907 if one escapes
its creating scope or is reused by a later scheduler invocation on the same
evaluator. Routed root dispatch snapshots and rechecks the suspended affine
resume together with the operation, arguments, and result, so a hostile root
callback cannot mutate the continuation graph to smuggle a foreign Task.
Positive task and decision bounds close and drain
the scheduler on refusal. Fail-fast and collect reuse the D50 result shapes,
and all results remain in task-creation order. Cache identity is the canonical
program hash plus scheduler version, failure policy, and both bounds. Entries
contain trace/decision proof only; they never retain evaluator closures,
continuations, results, or Task handles, and a hit is checked against a fresh
execution. SC.10 adds the trace format version to that cache identity. This is
the default C1 policy implementation and the decision seam used by the first C2
handler; it is not a host scheduler.

### 5.1 Versioned schedule record and strict replay

SC.10 defines canonical text format version 1. A trace is UTF-8 text ending in
one LF. Its first line is exactly:

```text
jacquard-schedule format=1 scheduler=S program=HASH policy=P max-tasks=N max-decisions=N fork=F
```

`S` is `fifo-round-robin-v0`; `HASH` is the 64-lowercase-hex `HASH_V0` identity
of the single scheduled expression; `P` is `fail-fast` or `collect`; both
bounds are positive decimal integers; and `F` is `-` or `K:TASK`. Remaining
lines use one of two closed records:

```text
create scope=PATH task=TASK parent=-|TASK
decision sequence=K runnable=TASK[,TASK]* chosen=TASK operation=OP
```

Task syntax is the deterministic `PATH#SPAWN_INDEX` carrier from §2. The
runnable list is ordered and nonempty. `OP` is one of `return`, `failure`,
`async.spawn`, `async.await`, `async.cancel`, `async.yield`, `async.scope`, or
`routed:HASH`. Unknown fields, tokens, operation names, versions, extra spaces,
missing final LF, duplicate task IDs, noncontiguous decisions, and impossible
queues are malformed E0908 traces. Serialization has exactly the field order
and spelling above; parse followed by serialize must reproduce every input byte.
Load-time validation is one linear pass over events and runnable entries. It
refuses more than `N` creations or decisions, a runnable queue wider than
`max-tasks`, and any task that reappears after its recorded `return` or
`failure`. Hash tables provide membership checks but are never iterated to
derive ordering or choices.

The CLI reads replay input incrementally before constructing its complete byte
string. The v1 transport ceiling is 4 KiB for the header, 1 MiB per line, 64
MiB total, and 200,001 lines total. The header further lowers the permitted
line count to `1 + max-tasks + max-decisions` and lowers the byte ceiling using
that event count. Oversized inputs fail with E0908 before program execution;
a tiny declared bound therefore cannot carry an arbitrarily large trace.

Strict replay checks the header against the requested program, scheduler,
policy, and bounds before creating the root scope. It consumes every `create`
before mutating allocation state, then at each decision checks the sequence and
exact ordered runnable list before selecting the recorded runnable task. It
checks the observed operation before applying a spawn/scope allocation or
calling a routed world callback. Missing, extra, reordered, malformed, or
impossible events and any EOF/leftover event are E0908 drift; replay never
falls back to FIFO. Consequently the first divergent world operation is not
executed.

Unversioned logs and every version other than 1 are refused. There is no
best-effort legacy parser or implicit migration: record a fresh v1 trace with
the matching program and configuration.

An explicit fork `K=TASK` strictly consumes the source trace before decision
`K`, validates that decision's exact runnable queue, and requires `TASK` to be
in it. The branch records its actual decision and then resumes FIFO. Its header
retains `fork=K:TASK`; that provenance is descriptive and does not weaken
strict replay of the resulting trace. The CLI exposes these contracts as
`jacquard run FILE --schedule-record TRACE`, `--schedule-replay TRACE`, and
`--schedule-fork K=TASK` (the fork requires replay). Traced CLI runs accept
exactly one top-level expression so the header has one unambiguous program
identity. `Round_robin.run_expr_scheduled` exposes the same record/replay/fork
contract to OCaml callers. Missing or unreadable replay paths use the same E0908
file diagnostic as other trace I/O. A record path is opened only after
successful program completion; a write failure reports E0908 without claiming
that the program itself failed to run.

The CLI treats the exact frozen `Async` declaration as scheduler infrastructure,
so a program does not need `--allow async` to use these operations. This is a
narrow automatic grant: effects performed by a child are still charged to the
parent row, and world effects such as Console, Fs, or Net still require their
own explicit `--allow` grants.

The corresponding compiled OCaml contract is
[`Concurrency_contract`](../src/concurrency_contract.mli). It contains only
types, pinned identities, task-path validation, and pure lifecycle,
waiter-wakeup, completion/failure-ordering, deadlock-cycle, and queue-order
relations. Task 127 / SC.3 installs the exact declarations and adds an inert
run/scope-local Task carrier in both runtime representations. SC.5 adds the
policy-independent lifecycle engine, SC.6 adds same-run nested scope ownership,
recursive cleanup, and complete runtime-value escape scans, and SC.7 adds
cooperative delivery at await, yield, and routed-effect boundaries. SC.8 adds
deterministic fail-fast and collect aggregation over explicit terminal decision
events. SC.9 adds the default deterministic queue and real evaluator-state Async
driver used by interpreted CLI and Warp Case execution. SC.10 adds canonical
record, fail-closed replay, and provenance-preserving explicit fork over that
same driver. Raw `Eval.run_expr` remains the low-level unscheduled evaluator
seam; native root scheduling remains separate work.

### 5.2 Budgeted exhaustive schedules

SC.12 treats the exact ordered runnable TaskId list at each decision as the
support of one multi-shot `Choose`. The default exhaustive handler explores
every ID in that order. Its implementation follows a branch by strictly
replaying the already chosen prefix and forking at the next decision. Every
branch starts a fresh evaluator run. This is important: the search duplicates
the scheduler choice, but never copies or resumes one affine Async
continuation in two worlds. There is no state hashing, partial-order reduction,
or other pruning in v0.

The three positive budgets are independent. `max-tasks` and `max-decisions`
apply to each schedule, while `max-worlds` bounds fresh schedule executions.
The report states the exact number of complete worlds, the number of executions
started, and either `Complete` or a structured list of task, decision, world,
or hermeticity reasons. Reaching a budget never returns a successful complete
claim. A prefix that stops at a task or decision bound is not counted as an
explored world. Its canonical decisions remain search input: the handler still
forks every earlier runnable choice, so a long FIFO seed cannot hide shorter
worlds that finish within the same decision or task budget.

Exhaustive runs are hermetic. An unhandled routed operation is recorded, then
refused before its root callback can run; the report is incomplete and names
the decision and operation hash. Language-handled effects remain ordinary
deterministic state inside the world. Every complete world retains its
canonical SC.10 trace, including exact queues and choices, and strict replay
must reproduce those bytes. Program failure is a complete world result rather
than an enumeration failure, which lets model checking find a
schedule-sensitive failure policy or property.

The public language has no `async.current-task` operation, so a checked
Jacquard program cannot name its own handle and self-cancel. The scheduler
lifecycle integration test therefore exercises self-cancel at the real
`Structured_scope.cancel` route; the real-evaluator suite covers failing-child
fail-fast/collect and same-step cancellation ordinals. Warp Case coverage is
limited to checker-representable programs (nested spawn/await/yield/cancel).
Ill-typed child faults and direct self-handle injection remain hostile OCaml
integration cases, not purported checked Warp programs. Warp Props still vary
data, not schedules.

### 5.3 Seeded randomized Warp schedules

SC.11 adds `jacquard test --schedules N --seed S` for hermetic Warp Cases. `N`
must be positive and `--seed` is required whenever this lane is selected. The
CLI does not fall back to OS entropy in this lane. Each discovered member gets
a SplitMix64 stream mixed from `S`, its canonical member hash, the length-framed
relative group/Case label path (never the renameable top-level name), and the
zero-based structural child-index path to the leaf. Length framing keeps labels
containing NUL bytes unambiguous, while the structural indices distinguish
duplicate labels. Each of the `N` executions then gets a child decision seed.
This makes one test's schedules independent of discovery order, top-level
renames, cache hits, and host `Random` state.

At each D46 decision, the handler draws one index from the exact ordered
runnable queue with 62-bit rejection sampling. Non-power-of-two queue lengths
therefore have no float-rounding or modulo bias, and every positive queue length
is range-safe. Task creation, wakeup, cancellation, scope aggregation, and all
other lifecycle rules remain unchanged. The scheduler identity is
`seeded-random-v0`. Every execution records the ordinary canonical v1 schedule
trace, including the full queue and chosen task. Strict replay consumes that
recorded scheduler identity and validates the trace before divergent work; it
does not draw again.

The first failing execution stops the test. Its output includes the root seed,
the failing child decision seed, and an exact rerun command. If the scheduler
completed a trace, it also prints that canonical log. A task/decision-bound or
other scheduler refusal before completion is explicitly labeled as lacking a
complete trace and prints no misleading partial log. Repeating the command is
byte-for-byte reproducible. A passing Case reports the number of explored
schedules and the root seed.

Hermetic cache identity is the existing Merkle test/member key plus the
scheduler version, schedule-leaf identity version, `N`, and `S`. The same
framed member/label/index identity is the trace program identity checked before
strict replay. Cache entries retain only ordinary rendered test evidence; no
Task, evaluator closure, continuation, PRNG state, or host random value enters
the cache. Scheduled failures are not cached because their rerun command
contains current source/prelude paths. Cached passing evidence rebuilds its
top-level display name from the current name index, so a semantic rename remains
a hit without stale presentation. WorldTests stay uncached, and Props retain
their separate data-generation sampling/exhaustive modes.

## 6. Interactions and exclusions

All Async operations are `once`. Scheduler handlers own at most one live
`Resume` per task. Deterministically scheduled scopes do not add schedules to a
Dist sample space; a Choose-driven scheduler does so explicitly. A State region
shared by tasks is serialized at suspension points, giving atomicity between
yields rather than shared mutable memory or locks.

The following are excluded from the shipped SC.14/C3 contract:

- detached or daemon tasks and any fire-and-forget root handler;
- shared mutable memory, locks, atomics, and data-race semantics;
- automatic external-resource finalizers;
- actors, mailboxes, and supervision before C4+;
- host threads, host scheduling, and real asynchronous I/O before C4.

Pure `parallel.map` and `parallel.both` are separate empty-row hints. Their
interpreter semantics are sequential and they introduce no Async effect.

SC.2 audited the optional native-thread path and declined it for the current
runtime: emitted C does not retain the callback-row proof, the allocator and
reference counts are single-threaded, and fatal runtime errors cannot be joined
and selected in source order. Native binaries therefore keep the sequential
fallback. The prerequisite audit, parity/sanitizer lane, and benchmark are in
[`native-parallel-decision.md`](native-parallel-decision.md).

## 7. Phases and indexed decisions

C0 is pure parallel hints. C1 is Task lifecycle, Async, structured scopes,
cooperative cancellation, fail-fast/collect, and the deterministic scheduler.
C2 adds schedule tooling. SC.10 implements versioned record/strict replay,
SC.11 adds seeded randomized Warp schedules, and SC.12 implements budgeted
exhaustive schedules. C3 adds typed channels: SC.13 freezes their interface and
semantics without a runtime, and SC.14 implements them. C4 adds host asynchronous
I/O; actor supervision opens only after channels and lifecycle evidence exist.

SC.16 closes the C0-C2 publication gate after the interpreted C3 Channel
runtime shipped in SC.14. Its one-program four-handler demo, exact inventories,
decision summary, claim-to-test map, integrated C3 evidence, and explicit C4
caveats are published in
[`release/structured-concurrency/EVIDENCE.md`](release/structured-concurrency/EVIDENCE.md)
and
[`release/structured-concurrency/LIMITS.md`](release/structured-concurrency/LIMITS.md).
Those documents do not widen the runtime contract defined here.

| ID | decision | frozen result |
|---|---|---|
| D46 | default scheduler | deterministic FIFO round-robin; host scheduling is opt-in |
| D47 | cancellation | cooperative at the three suspension classes above; bracket for cleanup; finalizers deferred |
| D48 | task escape | E0907 dynamic defect in v0; rank-2 static scoping is future work |
| D49 | channels and actors | SC.13 freezes scoped typed channels for C3; SC.14 implements them; actors/supervision remain C4+ |
| D50 | scope failure policy | fail-fast default; collect explicit, with the exact result shapes in §3 |

## 8. Typed channels (SC.13-SC.14 / C3 contract)

SC.13 froze the interface and behavior. SC.14 implements that exact contract in
the default interpreted structured scheduler: declarations, hashes,
transitions, rows, ownership checks, schedule modes, cache identity, and policy
interactions below are executable. `ChannelHandle` constructors remain private,
there is no user-installed root grant or `--allow channel`, and
actors/supervision remain out of scope.

### 8.1 Exact declarations, modes, identities, and rows

The frozen source fixture is executable checker input. `ChannelOpaque` is the
private runtime carrier; its source-level constructor exists in the declaration
so the complete public interface is hashable, while direct construction remains
E0907.

```jacquard doctest=concurrency-channel-contract mode=check fixture=concurrency-channel-contract.jac stdout=concurrency-channel-contract.stdout stderr=empty exit=0
type ChannelHandle a = | ChannelOpaque
type ChannelError = | ChannelClosed | InvalidCapacity(requested: Int)
type Task a = | TaskOpaque
type TaskResult a = | Done(value: a) | Failed(message: Text) | Cancelled

once effect Channel a where {
  channel.open : (Int) -> Result ChannelError (ChannelHandle a)
  channel.send : (ChannelHandle a, a) -> Result ChannelError ()
  channel.recv : (ChannelHandle a) -> Result ChannelError a
  channel.close : (ChannelHandle a) -> ()
}

once effect Async a where {
  async.spawn : (() ->{Async | e} a) -> Task a
  async.await : (Task a) -> TaskResult a
  async.cancel : (Task a) -> ()
  async.yield : () -> ()
}

open-channel(capacity) = channel.open(capacity)
send-one(channel, value) = channel.send(channel, value)
recv-one(channel) = channel.recv(channel)
close-channel(channel) = channel.close(channel)
spawn-send(channel, value) = async.spawn(fn () -> channel.send(channel, value))
```

Every Channel operation is `once`; mode is included in its member and whole
interface hash. The exact `HASH_V0` identities are:

| declaration/member | HASH_V0 identity |
|---|---|
| `ChannelHandle a` | `f4f5601a435906a47faedae9006e44b874146f3ad4b586bf9d04535be14dccb4` |
| private `ChannelOpaque` | `dc7a12f5fc0476b674d52535e9895220edf41f2a017b1dd97fc078950a3dbb36` |
| `ChannelError` | `25dc8f513c91c80fd6d33e843fc3f6cab183800805f46e269f716155149b4da7` |
| `ChannelClosed` | `de3da3e601fbba2c66864b87c6848d8224411df99f1967e132aaa166c1a3f3a9` |
| `InvalidCapacity` | `01b719cb597275f097c2c36b5e86b3d71604eb531fe00ef66d9c93ec3f55acfb` |
| `Channel a` | `bf9a334188ac13495eeb070fdc215d51763d9761b4775c98c61f44ebb1b03756` |
| `channel.open` | `23f13bd2fd87d17716873bf34c708d6c9a2ddd5f2b4e4f634db6e5d1827b1f07` |
| `channel.send` | `348fc5c967097b939360ecb2b066ba22ea8b924834e507c87a0e0f05f26fbfb0` |
| `channel.recv` | `db28d70a061da1f1108e01dfaa7e248c4268b9460971c518a9c37f1b51b52860` |
| `channel.close` | `ffa22eb01ff7aa206fec56f540b6fd1758b8590e8e797e83f3cbfd295ebce29b` |

The checker output above pins these rows:

```text
open-channel : forall a. (Int) ->{Channel} Result ChannelError (ChannelHandle a)
send-one : forall a. (ChannelHandle a, a) ->{Channel} Result ChannelError ()
recv-one : forall a. (ChannelHandle a) ->{Channel} Result ChannelError a
close-channel : forall a. (ChannelHandle a) ->{Channel} ()
spawn-send : forall a. (ChannelHandle a, a) ->{Async, Channel} Task (Result ChannelError ())
```

The block is signature output rather than source, so it is intentionally a
`text` fence. Channel does not receive a special dependent-row rule: Async's
existing child-row law carries the child's Channel effect to the spawning
caller. An Async scope may discharge only Async and therefore retains Channel.

SC.14 routes only the exact frozen Channel declaration and member identities
through the default interpreted scheduler, just as SC.9 routes only the exact
frozen Async identity. The CLI manifest admits that exact Channel hash as a
scheduler-managed effect; it is not a world grant, `--allow channel` remains
invalid, and a same-named or structurally different effect receives no special
treatment. The currently scheduled task supplies the owner scope: a root task
uses scope path `[0]`, and a task inside `async.scope` uses that exact nested
path. A language handler may intercept Channel in the ordinary algebraic-effect
way; this contract governs only an operation that reaches the scheduler. Raw
`Eval.run_expr` intentionally remains the low-level unscheduled seam, and the
native backend has no root Channel scheduler. The shipped default interpreted
route is the supported SC.14 execution path. Keeping Channel in the outward row
makes this routing visible instead of silently pretending that `async.scope`
discharged a second effect.

The element type is invariantly shared by handle, send argument, and receive
result. This negative checker fixture must fail before runtime execution:

```jacquard doctest=concurrency-channel-type-mismatch mode=check fixture=concurrency-channel-type-mismatch.jac stdout=empty stderr=concurrency-channel-type-mismatch.stderr exit=1
type ChannelHandle a = | ChannelOpaque
type ChannelError = | ChannelClosed | InvalidCapacity(requested: Int)

once effect Channel a where {
  channel.open : (Int) -> Result ChannelError (ChannelHandle a)
  channel.send : (ChannelHandle a, a) -> Result ChannelError ()
  channel.recv : (ChannelHandle a) -> Result ChannelError a
  channel.close : (ChannelHandle a) -> ()
}

send-text-to-int : (ChannelHandle Int) ->{Channel} Result ChannelError ()
send-text-to-int(channel) = channel.send(channel, "wrong")
```

### 8.2 Capacity, acceptance, and atomic transition order

`channel.open(n)` returns `Err(InvalidCapacity(n))` for `n < 0`, before carrier
allocation or consumption of a channel creation ordinal. This is an ordinary
typed result, never E0908, and there is no second capacity wrapper type. A
successful open returns `Ok(handle)` and establishes:

- `n = 0`: rendezvous; no value can be buffered;
- `n > 0`: a bounded FIFO buffer with capacity exactly `n`; allocation may be
  lazy and must not reserve `n` host slots eagerly.

Once the exact operation identity reaches the scheduler, common checks occur in
this order before the transition table below:

1. deliver a pending cancellation for the chosen task before inspecting
   capacity or handle state; the task becomes `Cancelled`, no Channel result is
   produced, and no Channel continuation or state is mutated;
2. for `open`, reject negative capacity with the typed result above, then check
   the native ChannelId bounds before allocation (E0908 on exhaustion);
3. for `send`, `recv`, and `close`, validate the opaque carrier's evaluator run,
   exact current open scope, and live channel ownership recursively; failure is
   E0907 before consuming the Once continuation or inspecting closed/buffered
   state;
4. only a valid, non-cancelled operation applies the first matching transition
   below and consumes or transfers its continuation exactly once.

A send succeeds only when its value is accepted into the buffer or delivered
directly to a receiver. Merely entering the blocked-sender queue is not success;
the suspended continuation retains the value. Every operation is one atomic
scheduler step with this priority:

| operation | frozen transition |
|---|---|
| send on closed | `Err(ChannelClosed)`; value is not accepted |
| send with waiting receiver | deliver to oldest receiver; sender and receiver return `Ok` |
| send with buffer space | append value; return `Ok(())` |
| send otherwise | append sender/value/Once continuation to sender FIFO; suspend |
| recv with buffered value | remove oldest value; if a sender waits, append its value into the new slot and complete that oldest sender; return removed value |
| recv with no buffer and waiting sender | rendezvous with oldest sender; both return `Ok` |
| recv on closed and drained | `Err(ChannelClosed)` |
| recv otherwise | append receiver/Once continuation to receiver FIFO; suspend |
| close on open | atomically mark closed and apply §8.3 |
| close on closed | return `()` with no additional wakeup; close is idempotent |

The invariant is one FIFO buffer plus FIFO sender and receiver queues. A
well-formed state never retains both sender and receiver waiters: the operation
that would create the second kind pairs with the oldest opposite waiter instead.
Values are communicated exactly once by ordinary Jacquard value semantics;
channels add no shared mutable cells, reference identity, equality, or
broadcast. Accepted buffer order is never completion, TaskId, or hash-table
order.

### 8.3 Close and blocked operations

Explicit close is drain-on-close:

1. mark the channel closed;
2. preserve values already accepted in the FIFO buffer;
3. remove every blocked sender in registration order, discard its unaccepted
   value, and complete its send with `Err(ChannelClosed)`;
4. when the buffer is empty, remove every blocked receiver in registration
   order and complete it with `Err(ChannelClosed)`;
5. append awakened counterparts before the closing task resumes.

After close, receives drain accepted values in FIFO order and then return
`Err(ChannelClosed)` forever. Sends return `Err(ChannelClosed)` forever. Close
returns `()` on both its first and subsequent calls. A close cannot race inside
one transition: the scheduler decision containing the earlier atomic operation
wins.

### 8.4 Deterministic fan-in and wake order

Scheduler decision order determines when a runnable producer reaches send.
When producers block, sender registration order is that decision order and the
oldest surviving sender is paired/promoted first. Receiver ordering is the same.
Cancellation removes one waiter without reordering survivors.

Every transition appends wakeups behind tasks already runnable. A matched or
promoted counterpart is appended first, followed by the currently chosen task
when its operation continuation remains runnable. Close appends its waiter FIFO
first and the closer last. An immediate open/send/recv/close result therefore
records the chosen task as its sole wake entry; `wake=-` is reserved for a
chosen task that actually suspends. Thus fan-in is deterministic without
sorting by TaskId or iterating a hash table.

The normative design traces are
[`rendezvous-v1.trace`](../corpus/channel/rendezvous-v1.trace) and
[`buffered-v1.trace`](../corpus/channel/buffered-v1.trace). They pin exact
pre/post abstract state, results, and wake order. The rendezvous trace also pins
negative-capacity rejection, blocked-receiver cancellation and close; the
buffered trace pins blocked-sender cancellation, survivor order, close
rejection order, and drain order. SC.13 froze these acceptance fixtures; SC.14
executes the same transitions through seeded, replay, exhaustive, and cached
scheduler paths.

### 8.5 Cancellation, ownership, and escape

Channel routing is an SC.7 cancellation boundary, including nonblocking `open`
and `close`. A cancellation already requested when a task reaches
open/send/recv/close wins before capacity or handle validation as frozen in
§8.2. Cancelling a blocked sender removes its waiter and drops its
unaccepted value; cancelling a blocked receiver removes its waiter without
consuming a value. Both resume the task only along the existing Task
cancellation path, not with a Channel result. If an earlier scheduler decision
already completed a match, that result is committed and a later cancellation
does not roll it back.

Every successful open creates a private ChannelId `(scope-path,
zero-based-successful-open-index)`. Invalid capacity consumes no index. IDs are
trace/diagnostic data only and have no Jacquard `Show`; SC.14 uses the same
native-domain validation as TaskId and reports internal exhaustion as E0908
before allocation.

A handle carries an unforgeable evaluator-run owner and its exact creating
scope. Any task in that exact scope may send, receive, or close it. A nested,
parent, foreign, closed scope or later scheduler run cannot use it. Recursive
state/result scans reject a handle returned from its creating scope, retained in
a tuple/constructor/closure, or smuggled through a hostile root callback with
E0907 before continuation consumption or channel mutation. Nested scopes create
their own channels; parent/descendant channel sharing is deliberately absent in
v1.

### 8.6 Scope policy, teardown, and deadlock

Fail-fast and collect do not change FIFO, close results, or deadlock detection:

- fail-fast selects the existing first decision-ordered non-success, requests
  sibling cancellation in creation order, removes channel-blocked siblings via
  §8.5, then closes owned channels in ChannelId order during scope teardown;
  cancelled operations yield Task `Cancelled`, not `Err(ChannelClosed)`;
- collect does not cancel siblings or implicitly close a channel when one child
  fails. Other children may continue to communicate and their results remain in
  creation order;
- under either policy, if every remaining live task is channel-blocked and no
  channel transition is possible, the scheduler reports deadlock E0908. In
  particular, fail-fast has no failure to prefer in this state; collect cannot
  return a partial aggregate. Deadlock never implies an implicit close. Cleanup
  removes waiters and destroys continuations;
- explicit close while the scope is active uses §8.3 regardless of policy;
- final scope destruction closes owned channels in creation order, removes any
  waiter before destroying its Once continuation, and drops undrained buffered
  values. No Channel result is observable after scope destruction.

Normal structured scope completion still requires all children terminal. A
body cannot return its channel to evade that rule because the recursive escape
scan rejects it first.

### 8.7 SC.14 implementation checklist and exclusions

SC.14 is conforming only if all of the following remain true:

- [x] exact declarations, four `once` modes, whole/member/type hashes, and rows
  above;
- [x] exact-identity scheduler admission, no `--allow channel`, current-task
  root/nested scope routing, shipped default interpreted execution, and the
  explicit low-level raw-evaluator/native exclusions;
- [x] typed negative-capacity result before allocation, rendezvous at zero, and
  bounded FIFO backpressure above zero;
- [x] sender/receiver registration, fan-in, promotion, and wake append order;
- [x] idempotent drain-on-close and exact blocked sender/receiver results;
- [x] cancellation-before-mutation, waiter removal, value ownership, and no
  double continuation consumption;
- [x] exact run/scope ownership, recursive escape scans, hostile callback
  revalidation, and deterministic ChannelId creation;
- [x] fail-fast cancellation, collect non-interference, policy-independent
  all-channel-blocked E0908 refusal, and exception-safe teardown;
- [x] rendezvous and buffered contract traces plus positive/negative checker
  fixtures.

The checked boxes now describe the shipped SC.14 interpreted runtime and its
acceptance evidence. Out of scope remain unbounded channels, select/try-send/try-recv,
timeouts, channel iteration, cloning or splitting endpoints, cross-scope
handles, broadcast/pub-sub, shared memory, locks/atomics, host I/O readiness,
actors, mailboxes, links, monitors, supervision, distributed channels, and
native runtime implementation. Any such addition requires a new interface and
compatibility decision; SC.14 does not infer one from this freeze.
