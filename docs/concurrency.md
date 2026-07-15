# Structured Concurrency Contract

Status: SC.5 policy-independent lifecycle core on the SC.3 Task value and Async
declaration boundary, July 2026. This document is authoritative for C1. Task
values, the four once operations, and scheduler state transitions are
represented; scheduler policy, scope execution, and an Async root handler remain
future work.

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
Merely checking the parameter type is insufficient: without the special
application rule, unification could absorb `Net` into `e` and then discard it.

SC.0 implements that special rule only for the direct resolved operation
identity whose complete declaration is the exact four-operation interface
above. The nominal HASH_V0 identities are `Task`
`07791255b44e18c3830038c51396bd3f80cf44a8e89222ff73dc90dd06ec3fb3`,
`TaskResult`
`915f69bd6fd8b34c2794b4b0e7ca88f5aafd0187e5c7c36a59091f6d031405ae`,
and `Async`
`4ff8ce05ab09968163492b3be40fc91381b47dee5fb4b2980f9416d50f38e66f`.
These are structurally derived identities, not name permissions: the checker
also validates the exact effect variable, operation order/names/modes,
parameter/result linkage, Task identities, and open self row. This executable
fixture pins both charging and handler subtraction. `async.scope` here is
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

scoped-net() =
  async.scope(fn () -> {
    let child = async.spawn(fn () -> net.get("https://example.invalid"))
    async.await(child)
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

This SC.0 bridge is deliberately not the SC.4 closure proof. Aliasing the
operation, passing it through a wrapper, returning a closure that later spawns,
and adversarial row-polymorphic wrappers still require SC.4's general inference
rule and negative suite before Async can ship. No such case is accepted here as
evidence of complete non-laundering.

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

SC.3 exposes no public evaluator or library constructor for Task values. The
private scheduler seam always assigns the evaluator's active run and scope.
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

## 3. Scope APIs and failure shapes

The general handler and homogeneous convenience APIs are frozen as:

```text
async.scope : (() ->{Async | e} a) ->{| e} TaskResult a
async.scope-fail-fast : (List (() ->{Async | e} a)) ->{| e} TaskResult (List a)
async.scope-collect : (List (() ->{Async | e} a)) ->{| e} List (TaskResult a)
```

`async.scope` uses fail-fast by default. It discharges only `Async`; all child
world effects remain in `e`. Its body may spawn, await, cancel, and yield
directly. A successfully returned body value is `Done`; the first child failure
selected by scheduler decision order is `Failed`, and cancellation is
`Cancelled`.

`async.scope-fail-fast` is the homogeneous aggregate: `Done(values)` preserves
input/creation order. The first `Failed` cancels unfinished siblings; a failure
or cancellation returns no partial value list. `async.scope-collect` never
cancels siblings merely because one failed and returns one `TaskResult` per
input, in input/creation order. These separate shapes avoid pretending that
heterogeneously typed child values can inhabit one list. Within a general scope,
programs obtain heterogeneous typed results explicitly with `async.await`.

## 4. Cancellation and resources

Cancellation is cooperative and becomes observable only at these suspension
points, in this exact contract order:

1. `async.await`;
2. `async.yield`; and
3. any effect operation routed through the scheduler, including Async
   operations and scheduler-mediated world operations.

At every boundary the scheduler checks an already requested cancellation
before executing the routed operation. Thus cancellation delivered at spawn
creates no child, and cancellation delivered at await registers no waiter.
Otherwise `async.cancel(target)` atomically requests target cancellation and
returns unit. Delivery changes the target to `cancelled` once and drops its
affine continuation. Cancel of an already terminal or already requested task is
an idempotent no-op. A task cancelling itself observes cancellation at that
`async.cancel` routing point. No user expression after delivered cancellation
runs.

Dropping a continuation releases language/runtime memory; it does not release
an external resource automatically. Acquire/release handlers (the bracket or
`with-file` pattern) are the required C1 idiom for resources crossing a
suspension point. Finalizers are explicitly deferred.

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
   completion order. Simultaneous failures are ordered by decision sequence.

The host scheduler is never consulted by this default. Seeded random,
Choose-driven exhaustive, recorded/replay, and host scheduling are later
handlers over the same decision boundary. Strict replay must validate the full
runnable queue and chosen ID before divergent user or world work executes.

The corresponding compiled OCaml contract is
[`Concurrency_contract`](../src/concurrency_contract.mli). It contains only
types, pinned identities, task-path validation, and pure lifecycle,
waiter-wakeup, completion/failure-ordering, deadlock-cycle, and queue-order
relations. Task 127 / SC.3 installs the exact declarations and adds an inert
run/scope-local Task carrier in both runtime representations. SC.5 adds the
policy-independent lifecycle engine; runnable-queue policy, executable scopes,
effect routing, and a root handler remain separate work.

## 6. Interactions and exclusions

All Async operations are `once`. Scheduler handlers own at most one live
`Resume` per task. Deterministically scheduled scopes do not add schedules to a
Dist sample space; a Choose-driven scheduler does so explicitly. A State region
shared by tasks is serialized at suspension points, giving atomicity between
yields rather than shared mutable memory or locks.

The following are excluded from C1 and from this interface freeze:

- detached or daemon tasks and any fire-and-forget root handler;
- shared mutable memory, locks, atomics, and data-race semantics;
- automatic external-resource finalizers;
- channels before C3 and actors/supervision before C4+;
- seeded-random/exhaustive schedule exploration and trace replay before C2;
- host threads, host scheduling, and real asynchronous I/O before C4; and
- a claim that the SC.0 direct-spawn bridge proves higher-order row charging.

Pure `parallel.map` and `parallel.both` are separate empty-row hints. Their
interpreter semantics are sequential and they introduce no Async effect.

## 7. Phases and indexed decisions

C0 is pure parallel hints. C1 is Task lifecycle, Async, structured scopes,
cooperative cancellation, fail-fast/collect, and the deterministic scheduler.
C2 adds schedule traces, replay, seeded random, and bounded exhaustive schedules.
C3 adds typed channels. C4 adds host asynchronous I/O; actor supervision opens
only after channels and lifecycle evidence exist.

| ID | decision | frozen result |
|---|---|---|
| D46 | default scheduler | deterministic FIFO round-robin; host scheduling is opt-in |
| D47 | cancellation | cooperative at the three suspension classes above; bracket for cleanup; finalizers deferred |
| D48 | task escape | E0907 dynamic defect in v0; rank-2 static scoping is future work |
| D49 | channels and actors | channels deferred to C3; actors/supervision to C4+ |
| D50 | scope failure policy | fail-fast default; collect explicit, with the exact result shapes in §3 |
