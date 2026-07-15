# Structured Concurrency — Design, Draft 0.1

Companion to the effect linearity design (a hard dependency: Async operations
are `once`) and the effects runtime. Origin: convergent external review
matching our own long-held stance, plus three specifics adopted from it: the
row-charging law for spawn, deterministic scheduling as the default handler,
and pure parallelism as phase zero.

## 1. Why this is Jacquard-shaped

Every other language bolts concurrency onto its runtime and then spends a
decade retrofitting visibility (data-race detectors, structured-concurrency
libraries, async coloring). Jacquard's substrate inverts the order:
concurrency is an effect interpreted by a scheduler handler, which means it
inherits, on day one, everything effects already have. Schedules become
worlds: the same program runs under a deterministic scheduler, a seeded
random one, an exhaustive one, or a recorded one, because a scheduler is a
handler and handlers swap. Authority stays visible: a background task cannot
carry powers its parent's signature doesn't show. And replay works, because
scheduler decisions are effect operations and effect operations are what the
trace records.

## 2. The one law

**Child effects are charged to the parent row.**

```
effect Async where
  once spawn  : (() ->{Async | e} a) -> Task a     -- caller row gains {Async | e}
  once await  : (Task a) -> TaskResult a
  once cancel : (Task a) -> ()
  once yield  : () -> ()

type TaskResult a = | Done(a) | Failed(Text) | Cancelled
```

`spawn`'s argument row flows into the caller's row, so a function that spawns
a Net-touching task has Net in its own signature. There is no fire-and-forget
authority laundering, by typing rather than by policy. This is the single
most important line in the design and everything else defends it.

`Task` is an abstract runtime type owned by the scheduler handler. Tasks are
scope-local (§4); a task value escaping its scope is a defect in v0, with the
static version (rank-2 scoping in the manner of runST) recorded as future
work rather than promised.

## 3. Phase zero: pure parallelism, free of semantics

The empty row is a parallelism license. A function `(a) ->{} b` cannot
observe evaluation order, touch the world, or race anything, so:

```
parallel.map  : (List a, (a) ->{} b) ->{} List b
parallel.both : (() ->{} a, () ->{} b) ->{} (a, b)
```

are **semantically identical to their sequential versions**. They are hints.
The interpreter runs them sequentially; the native backend may run them on
threads; no program can tell the difference, which is why C0 ships with zero
semantic risk and no Async effect at all. This is also the sentence that
connects the effect system to the compilation story: the row is
simultaneously the security manifest and the parallelism license, one fact
serving two masters. Warp obligation: differential tests that sequential and
parallel execution produce identical results and identical hashes of output.

SC.2 audited the optional native-thread path and declined it for the current
runtime: emitted C does not retain the callback-row proof, the allocator and
reference counts are single-threaded, and fatal runtime errors cannot be joined
and selected in source order. Native binaries therefore keep the sequential
fallback. The prerequisite audit, parity/sanitizer lane, and benchmark are in
`native-parallel-decision.md`.

## 4. Structured scopes

Detached tasks are the mistake every ecosystem regrets, so they do not exist.
All spawning happens inside a scope, and the scope rule is the second law:
**every task spawned in a scope is completed, awaited, or cancelled before
the scope exits.**

```
fetch-all(urls) =
  async.scope(fn () -> {
    let tasks = urls |> list.map(fn (u) -> spawn(fn () -> net.fetch(u)))
    tasks |> list.map(fn (t) -> await(t))
  })

fetch-all : (List Url) ->{Net} List (TaskResult Response)
```

Note the public signature: `Async` is discharged by the scope's scheduler
handler, Net remains. Concurrency internal, authority external, exactly the
subtraction-you-can-see story handlers already tell.

Scope exit with live tasks cancels them (fail-safe default). Failure policy
is a scope parameter: `fail-fast` (first Failed cancels siblings, scope
returns the failure) or `collect` (all tasks run to completion, results
gathered). Cancellation is cooperative: it lands at suspension points
(`await`, `yield`, and any effect operation routed through the scheduler),
and a cancelled task's continuation is dropped, which is legal because Async
is affine (`once` permits zero resumes). The honest gap, inherited from the
linearity doc and owned here: dropping a continuation releases memory, not
external resources. The v0 answer is the bracket pattern (acquire/release as
a handler, `with-file`-style) documented as the idiom for resources that
cross suspension points; finalizer machinery is future work, noted not
promised.

Shared mutable memory does not exist. Tasks communicate by value; a `State`
region shared across tasks is serialized by the scheduler at suspension
points, which gives atomicity between yields and is documented plainly so
nobody mistakes it for locks.

## 5. Schedulers are handlers, and one scheduler is many

The scheduler is written once, parameterized over a decision effect. Which
task runs next is `decide : (List TaskId) -> TaskId`, and the interpretation
of `decide` is somebody else's handler:

| plug in | you get |
|---|---|
| deterministic round-robin (default) | reproducible runs, Warp-cacheable, replayable by construction |
| seeded random | interleaving fuzz: `jacquard test --schedules N --seed S`, a new Warp lane |
| **Choose** | every interleaving, exhaustively, via multi-shot enumeration: model checking for small task counts as ordinary library code |
| a recorded log | exact replay of a production schedule; fork at decision k for counterfactual debugging |

The third row is the design's best trick and it costs nothing: `decide`
performed via Choose under `dist.enumerate` is `fault.all` for schedules, the
same machinery pointed at a new nondeterminism source. The many-worlds grid
in the playground design gains a scheduler axis the day this lands. Statement
of default, because it is a values statement: **determinism is the default
and the host's arbitrary scheduling is the opt-in**, reversing every
mainstream runtime.

## 6. Interactions, stated

With linearity: all Async operations are `once`; scheduler handlers are the
canonical consumers of the affine `Resume` type, holding at most one live
resumption per task. With Dist: a deterministically-scheduled scope is a
deterministic computation, so models containing one enumerate cleanly;
schedules join the sample space only when the Choose-driven scheduler
explicitly puts them there. With replay: traces gain task-id and
decision-sequence entries, and strict replay enforces the recorded
interleaving. With the world: `run-host`, the scheduler that suspends fibers
on real async IO, is deliberately last (C4), because everything before it is
pure machinery testable in Warp's hermetic lane.

## 7. Channels, later, and actors, later still

Typed channels (`channel`, `send`, `recv`, `close`, all `once`) arrive only
after task lifecycle is solid, because channels import ordering, blocking,
fan-in, and close semantics all at once. Actors are a library on top of
channels plus supervision, and supervision (restart policies on scopes, the
BEAM inheritance) is designed when there is something real to supervise.
Recording the restraint here so the scope of C1 stays small.

## 8. Phasing

C0 (small): `parallel.map`/`both`, sequential implementation, differential
tests; native thread backend whenever the compiler wants it, invisibly.
C1 (large): Async, Task, scopes, deterministic scheduler, cancellation,
fail-fast/collect; hermetic Warp suite since no world is involved.
C2 (medium): trace extension, replay-with-schedule, seeded-random Warp lane,
Choose-driven exhaustive scheduler with a budget.
C3 (medium): channels. C4 (large): `run-host` with real async IO in the
native runtime; supervision design opens after.

| ID | decision | default |
|----|----------|---------|
| D46 | default scheduler | deterministic round-robin; host scheduling is opt-in |
| D47 | cancellation | cooperative at suspension points; bracket idiom for resource cleanup, finalizers future work |
| D48 | task escape | dynamic defect in v0; static scoping recorded as future work |
| D49 | channels and actors | deferred to C3/C4+, after task lifecycle proves out |
| D50 | scope failure policy | `fail-fast` default, `collect` by parameter |
