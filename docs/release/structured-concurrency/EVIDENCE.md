# Structured Concurrency SC.13 Evidence

Status: the typed Channel interface, identity, static checker contract, and
deterministic behavior are frozen over the complete SC.12 scheduler stack.
SC.13 supplies executable type fixtures and normative SC.14 acceptance traces,
but no Channel runtime handler, root grant, native route, or host scheduling.

- Reconstruction base: `2fc2d306c1236b8faeaee37a2e1c9d2848d16f52`
- Evidence overlay: [MANIFEST.sha256](MANIFEST.sha256)
- Authoritative contract: [concurrency.md](../../concurrency.md)

## Published declarations

`prelude/03-concurrency.jqd` publishes exactly `Task a`, `TaskResult a`, and the
four-operation `Async a` effect frozen by SC.0. The declaration identities are:

| declaration/member | HASH_V0 identity |
|---|---|
| `Task a` | `07791255b44e18c3830038c51396bd3f80cf44a8e89222ff73dc90dd06ec3fb3` |
| private `TaskOpaque` carrier | `9b4eaa5e872fa3f768c71fc4cba4d3262a9ebf8a719f0cfb78f22fa9eade4310` |
| `TaskResult a` | `915f69bd6fd8b34c2794b4b0e7ca88f5aafd0187e5c7c36a59091f6d031405ae` |
| `Done` | `8bb29144a0570c1b4e6da9f9bb899b7938bb5eda078f5800a7acb24bb295a095` |
| `Failed` | `ce8613a28d881583c0239bd1f4d65156e0f28d48f12d61f246f386a8b3fb0934` |
| `Cancelled` | `b2bbe23f39ea5e437f838e3bf9cfd030f6916f1d236b48716097a502328de697` |
| `Async a` | `4ff8ce05ab09968163492b3be40fc91381b47dee5fb4b2980f9416d50f38e66f` |
| `async.spawn` | `dae95472328cdc4e38d64b3dd71f49f8b99d1cabbc5a1be603d7d44cc3b0c4a5` |
| `async.await` | `7326d67de02f676afc476e7f16a3b4ee9617293865ffc8dd77ca7f0e9e8e675a` |
| `async.cancel` | `5371011ae9b806265e1f12224cbb5a44bb6aabe7e5396e68eca7babf4c3a93d0` |
| `async.yield` | `3f67a20859f53ca48578469efd2c4bc2956bfa6b37d241fcbf2fe19d1ddf3e6a` |

The prelude golden pins all whole/member hashes. Focused tests load every
declaration from the content-addressed store, print it, read it, rebuild the
kernel declaration, and re-hash the corresponding member. SC.4 and SC.5 change
no declaration identity and add no kernel form.

## Generalized child-effect law

The checker recognizes only the fully revalidated frozen `async.spawn`
identity. Its instantiated operation scheme uses one shared open row for the
child thunk and the operation call:

```text
(() ->{Async | e} a) ->{Async | e} Task a
```

Because the dependency is carried in the type, it survives an operation alias,
a higher-order forwarding function, a returned closure, tuple storage and
destructuring, independent Net/Fs row-polymorphic uses, and nested scopes. The
executable concurrency doctest pins every route and the documented aggregate:

```text
fetch-all : (List Text) ->{Net} TaskResult (List (TaskResult Text))
```

The manifest cram executes the same law through a wrapper. A console-only
manifest fails with E0814 naming `net.get`; a Net manifest succeeds, proving
that `async.scope` removed Async but did not remove Net. A misleading closed
annotation reports the propagated Net row. An adversarial row-polymorphic shape
fails with the same-tail occurs check at the `async.spawn` source, and the Types
regression rejects different effect sets sharing the same tail. Both negative
crams declare the complete frozen four-operation Async identity rather than a
near-match. A generated property checks that every subset of two independent
child effects remains visible in the shared caller row. The converted-shape
defense fails closed with E0805 if a future checker refactor makes the validated
frozen declaration and its internal arrow disagree; a source regression keeps
that path diagnostic-only and forbids the former internal assertion.

## Opaque Task boundary

The store retains the Task declaration and hash index but omits `TaskOpaque`
from the public constructor index. The checker, interpreter, and native lowerer
also reject the exact derived constructor hash with E0907, so a raw hash cannot
bypass name privacy. A single private-hash predicate also rejects `bind_name`
and persisted `names.jqd` entries, while declaration insertion evicts stale
private bindings. No Task equality, Show instance, or codec is published.
Internal diagnostic rendering is the redacted token `<task>` and never exposes
the owner token or deterministic ID.

The OCaml carrier owns an unforgeable evaluator-run token and the SC.0
`(scope-path, spawn-index)` identifier. Task construction is absent from the
public Eval interface; its implementation-only scheduler seam always uses the
active scope. The native runtime has a distinct `JQ_TASK` tag with the same
inert fields. Both domains admit at most 65,532 unsigned-32-bit path components
and an unsigned-32-bit spawn index. Both implementations validate shape, run,
and exact scope without selecting or running work.

Tests pin `0/2#3`, same-scope acceptance, E0907 for cross-scope/cross-run use,
and non-crashing malformed-handle diagnostics. Hostile callback tests cover a
foreign Task nested in tuple and constructor results through internal apply,
`run_expr`, capturing, and terminal states. Native allocation/reference-count/
show tests pin equivalent valid, malformed, foreign-run, foreign-scope,
uint32/uint16 boundary, exact stored-spawn overflow rejection, and redaction
behavior.

Reusable validated states and both validated and ordinary captured
continuations carry the exact originating evaluator context. Cross-context
execution, capture, and resume fail with E0907 before execution or Once-budget
consumption. A hostile regression validates a Task-bearing state under context
A, attempts execution and capture under B, exposes the captured Task argument,
and attempts both continuation APIs under B. Same-context runs continue through
the trusted scan-free sampling path.

The lower-level `run_state_capturing_once` carrier is context-bound as well:
its opaque `VOnceResume` state retains the originating evaluator-run token.
The direct `async.yield` regression captures under A, rejects invocation under
B with E0907 before consumption, then successfully resumes the same token under
A. Ordinary in-language Once resumptions share this private owner check.

## Async boundary and parity

All four Async operations are reviewed as `once`, and the taxonomy still marks
Async as reserved. The default interpreted CLI, prelude-evaluation, and Warp
paths automatically admit only the exact frozen Async effect and execute it
through `Round_robin`; users do not install a root handler or pass
`--allow async`. This scheduler infrastructure grant does not admit Console,
Fs, Net, or any other world effect. Raw `Eval.run_expr` remains an unscheduled
low-level seam whose unhandled Async operations produce `Unhandled`, and the
native backend has no root Async scheduler. Native execution therefore requires
an in-language handler to discharge Async before the root.

`TaskResult` constructors execute in both tiers. The `task-values.t` cram test
byte-compares interpreter and native output for Done/Failed/Cancelled, tests
the private carrier diagnostic, and pins successful scheduled CLI execution of
`async.yield`. The C/OCaml show parity corpus includes a redacted inert Task
value.

## Scheduler lifecycle core

`Scheduler_core` owns deterministic body/child IDs, opaque scope-local handles,
task lifecycle, await edges, immutable terminal results, cooperative
cancellation requests, and opaque resume tokens. Resume ownership is
destructive: checkout removes the sole token, suspension returns one token, and
terminal transitions or cancellation delivery drop it. Explicit scope close
removes all wait edges and transfers remaining owned tokens to the caller for
destruction. Invalid lifecycle or ownership operations return E0908; foreign
handles continue to return E0907.

Await registration permits multiple same-scope waiters and preserves their
registration order on wakeup. Terminal awaits are immediate. Self-await and
closed cycles produce the frozen task-failure messages and terminalize cycle
members atomically with respect to wakeup reporting: every member drops its
resume and reaches `failed` before registration-ordered external waiters become
runnable. Multi-member evidence pins cycle-discovery grouping and per-member
registration order, including a cancelled external waiter that is omitted. No
terminal cycle member can appear in the returned wakeup list. The core returns
the handles made runnable by a transition but has no runnable queue and makes no
policy decision.

Focused Alcotest and QCheck coverage pins the transition table, resume-token
ownership, deterministic IDs, yield suspension/wakeup, multiple waiters,
immediate terminal awaits, completion/failure/cancellation, self-await, closed
two- and three-node cycles, external/cancelled waiter controls, the complete
public rejection table, identical back-to-back scenarios, a property that every
observed lifecycle transition satisfies the frozen contract, a property that
every returned wakeup is runnable with one resume, close cleanup, and
foreign-handle diagnostics. The existing handler
gauntlet and interpreter/native runtime suites continue to cover affine Once
capture enforcement and the inert Task boundary around this core.

## Structured scope ownership and escape boundary

`Structured_scope` opens root path `[0]` and uses the scheduler core's new
same-run construction seam for nested paths. Every nested scope appends a
one-based creation ordinal and is registered with its parent. The layer exposes
the lifecycle operations only while that exact scope remains open; stale or
cross-scope use is E0907. It introduces no queue, scheduling policy, host
thread, effect route, or root handler.

Normal return, result-level abort, and host exceptions share one explicit
bracket cleanup. Descendants close recursively, unfinished tasks become
cancelled, wait edges are cleared, and every scheduler-owned resume token is
passed exactly once to the destruction callback. Cleanup completes before an
escape diagnostic is returned. Recursive counters for open scopes, live tasks,
runnable tasks, and owned resumes all return to zero, so no registered child
continuation remains runnable after its scope returns. Repeated close is
idempotent. This is continuation-memory cleanup, not an automatic external
resource finalizer; acquire/release handlers remain required around suspended
resources.

The exit guard rejects returned or stored handles whose creation path is the
closing scope or any descendant. A nested close may still observe a valid
enclosing-scope handle. `Eval.reject_task_escape` walks the full reachable
runtime-value graph, including tuples, constructors, closure cells, cyclic
closure environments, and multi-shot resumptions, validating the opaque run
before the path-prefix check.

Focused lifecycle tests cover joins, forgotten children, three-level nested
lineage, recursive normal/abort cleanup, returned and stored escapes, foreign
and enclosing handles, stale post-close operations, result aborts, and host
exceptions. A 200-case QCheck property constructs nested chains and proves that
every ownership counter returns to baseline. Dynamic graph tests hide Tasks in
all supported carrier shapes. The native ASAN/LSAN runtime lane additionally
tears down 4,096 Task and resume-shaped carriers at a simulated scope boundary,
pinning explicit carrier release without claiming a native scheduler.

## Cooperative cancellation delivery

`Scheduler_core.cancellation_boundary` atomically checks a checked-out runnable
task before a suspension-class operation. With no pending request it returns
the affine continuation unchanged. With a pending request it terminalizes the
task as `Cancelled`, clears its await edge, wakes existing waiters in
registration order, and transfers the boundary continuation for exactly-once
destruction. `Scheduler_core.deliver_cancel` transfers scheduler-owned
suspended continuations to its caller, and `Structured_scope.deliver_cancel`
passes every transferred token exactly once to its explicit destruction
callback. Duplicate and terminal delivery transfer nothing, so cancellation
never relies on garbage collection to discharge affine ownership.
The registered-waiter regression additionally pins that cancellation returns
waiters in registration order, transitions each waiter to `Runnable` with its
resume owned again, and leaves the immutable `Cancelled` target result
available to every subsequent await.

`Structured_scope` applies that primitive before await registration, yield
suspension, and a routed-effect action. A delivered await registers no waiter;
a delivered yield stores no continuation; and a delivered routed effect never
invokes its action, including a lazily supplied spawn action. Routed action
failures remain result values paired with the still-owned continuation, so the
fault path neither cancels implicitly nor loses ownership.

Cancel first checks the caller at its routed-effect boundary. A caller already
selected for cancellation therefore cannot mutate its target. Otherwise a
runnable target receives one idempotent request, while an await- or
yield-suspended target is delivered immediately and its stored continuation is
destroyed. Completed, failed, already-cancelled, and duplicate requests are
deterministic no-ops. Self-cancel requests and delivers at the same routing
point; the second caller-boundary check exists for that case, and no
continuation is returned for a post-cancel user step. An already-cancelled
caller reaching another boundary destroys the newly supplied stale
continuation and wakes nobody.

Focused Alcotest coverage pins all three boundary classes, no-waiter/no-child
preemption, routed-effect fault injection, duplicate/completed/self behavior,
the exact public handoff that destroys suspended resume token 21 once, and the
stale already-cancelled boundary handoff. It also pins the rule that a
pre-cancelled caller does not request another target, plus registered-waiter
wake order, runnable/resume ownership, and repeated observation of the
immutable `Cancelled` result.
The bracket fixture records acquire, continuation destruction, and release in
order and proves that no later user step executes. A 200-case QCheck property
proves duplicate requests yield exactly one terminal delivery and one
continuation destruction. The native ASAN/LSAN lane only stress-destroys 4,096
nested continuation-shaped heap carriers; it does not exercise a native
scheduler, cancellation route, or callback handoff. External resources still
require explicit acquire/release handlers rather than language finalizers.

## Deterministic scope policies

`Scope_policy.create` registers an ordered same-scope child list and defaults to
the frozen `Fail_fast` policy. Duplicate or foreign children fail before any
observation. `record_terminal` requires a non-negative, strictly increasing
lexicographic `(D46 decision, sub-observation ordinal)` pair. Decision violations, unregistered same-scope
children, repeated terminal observations, and nonterminal observations produce
exact E0908 diagnostics; foreign-run, foreign-scope, and stale handles retain
the public E0907 ownership diagnostic. The controller consumes decisions; it
does not choose or run a task.

On the first decision that observes `Failed(message)` or `Cancelled`, fail-fast
freezes that exact non-success and visits unfinished siblings in input order. It
requests cancellation for each and immediately delivers already-suspended
siblings through `Structured_scope.deliver_cancel`, so owned resume tokens reach
the explicit destruction callback once. Runnable or checked-out siblings retain
an idempotent request. A later failure cannot replace an earlier cancellation,
and a later cancellation cannot replace an earlier failure.

The terminal decision and result are committed before those cancellation
attempts. A cancellation diagnostic or destruction-callback exception therefore
does not roll the observation back. Every sibling cleanup is still attempted in
input order. The policy catches each user callback failure around the unchanged
SC.7 delivery primitive, buffers waiters returned by that same delivery, and
then continues cleanup. If callbacks raise, the first physical exception is
re-raised with its captured backtrace only after all sibling attempts finish.
`Scope_policy.take_awakened` drains retained waiters exactly once in sibling
input order and each target's waiter-registration order. Finish remains
unavailable until every child is observed terminal, so the scope cannot expose
an undrained aggregate.

Collect never requests sibling cancellation. It waits for every child and
returns `Done`, `Failed`, and `Cancelled` entries in the registered input order,
not terminal decision order. Fail-fast likewise returns successful values in
input order and returns no partial list on failure or cancellation. Empty
inputs are immediately `Done([])` or `[]` respectively, and nested controllers
retain independent policy and decision sequences.

Focused Alcotest cases cover zero/one/many inputs, default selection, ordered
sibling cancellation, mixed collect results, nested policies,
failure-before-cancellation and cancellation-before-failure commitment, cleanup
after a destruction-callback exception, and exact E0907/E0908 diagnostics. A
200-case QCheck law permutes terminal observation order while proving collect
output stays in input order. A second 200-case law generates mixed terminal
results and decision permutations, then proves incremental fail-fast selection
agrees exactly with the frozen `Concurrency_contract.first_failure` relation.
The `scope-policy.t` transcript runs the same decision trace twice,
byte-compares it, and pins both aggregate renderings. These tests use no host
clock, thread, scheduler queue, or root handler.

## Deterministic round-robin interpreter

`Round_robin.run_state` owns an explicit FIFO handle queue and converts it to the
exact TaskId list consumed by `Concurrency_contract.decide_round_robin` at every
decision. It advances one real `Eval.state` to the next captured operation,
return, or failure. Spawn assigns the next ID and queues child then parent;
yield queues its task at the tail; live await removes the waiter until
registration-ordered wakeup; cancellation requests are delivered only at SC.7
boundaries. Root and nested scopes share one FIFO, decision sequence, trace,
task/live high-water accounting, and configured task/decision bounds. Opening
`async.scope` suspends the parent and appends the nested body behind every
already-runnable task; nested completion requeues the parent. No recursive
sub-scheduler resets ordering, counters, traces, or bounds. Spawn, await, yield,
cancel, and every captured granted world operation route through
`Structured_scope` before their action. Neither runnable discovery nor
selection uses hash-table iteration, a host clock, a thread, or host randomness.
The interpreted CLI automatically includes only the exact frozen `Async` effect
in the scheduler grant set; users do not pass `--allow async`. Child world
effects remain in the parent manifest and still need their ordinary explicit
grants.

Every scheduler invocation creates a fresh opaque Task owner, even on a reused
evaluator context, and a private capability binds evaluator validation to the
active run/scope. Recursive result validation rejects E0907 when a Task is
reachable through a returned value or retained into a later run. Root dispatch
snapshots the suspended affine resume alongside operation arguments and
rechecks both plus the result after the callback.
The external-client boundary cram compiles ordinary `Eval` and `Round_robin`
uses against `public_cmi`, then proves `Concurrency_owner.create`,
`Task_capability.runtime`, and `Task_handle.create_run` each fail because their
installed-private module CMI is absent.
Positive task and decision limits bound every run and close the lifecycle core
on refusal. Fail-fast freezes the first decision-ordered `Failed` or
`Cancelled`; collect never propagates sibling cancellation. Both aggregate in
creation order. The cache key is the canonical program hash, scheduler version,
policy, and both bounds. It stores only trace/decision/task-count proof; every
lookup executes fresh, so no closure, continuation, value, or Task can alias
across runs.

The focused scheduler suite pins a real evaluator
spawn/blocked-await/yield/cancel trace, multiple registration-ordered waiters,
cancellation before a routed Console action, cross-scope FIFO interleaving,
cumulative nested task/decision bounds and live high-water accounting, E0907
Task escape, exact bound diagnostics, zero post-close recursive metrics, and
cache miss/hit equality, including an independent `max_decisions` miss. It also
pins same-context stale-run rejection, hostile mutation of a suspended Once
resume, real failing-child fail-fast/collect, a fail-fast cancellation that
requeues an awakened waiter, the integrated self-await deadlock refusal, and
stable same-decision terminal ordinals. Checkout-bracket tests separately prove
that normal, diagnostic, and host-exception exits restore an unsettled affine
token before scope cleanup, while preserving the physical host exception and
its raw backtrace prefix. Its 128-case property changes the host random seed and
proves the same decisions and bytes as an unseeded rerun. The `round-robin.t`
transcript repeats a fresh process 128 times, byte-compares every trace, pins the
exact cross-scope trace and cumulative counters, runs real CLI Async programs,
and runs a Warp Case containing a nested Async lifecycle. The dedicated
concurrency lane also runs the prior child-row, cancellation, ownership, and
policy suites.

The hostile-case coverage matrix is intentionally split at the checker/runtime
boundary:

| case | checked Warp Case | real runtime integration |
|---|---:|---:|
| nested spawn/await | yes, `async-case` | yes |
| yield and affine continuation resumption | yes, `async-yield-case` | yes |
| cancel then await `Cancelled` | yes, `async-cancel-case` | yes |
| fail-fast selection of a cancelled child | yes, `async-fail-fast-case` | yes |
| cancellation before routed Console work | yes, granted `async-routed-cancel` with empty output | yes |
| child-row authority | closed Case is rejected with E0801 retaining `net` | SC.4 row tests |
| Task escape | top-level CLI fixture is rejected with E0907; a Case cannot return `Task` as `Check` | yes |
| task/decision bounds | no per-Case bounds API in C1 | yes, exact task and global nested-decision refusals |
| failing child under fail-fast and collect | no: the hostile fixture is deliberately ill-typed | yes |
| self-cancel | no: C1 has no `async.current-task` handle | yes, through `Structured_scope.cancel` |
| hostile root mutation of a suspended Once resume | no: host callback attack | yes |

Warp Props remain data properties over the single C1 FIFO schedule; they do not
claim schedule exploration.

## Versioned scheduler traces and strict replay

`Schedule_trace` defines canonical format v1 as a closed, line-oriented codec.
Its header pins the format, scheduler identity, canonical program hash, failure
policy, positive task/decision bounds, and optional fork decision/task. Create
events pin scope path, TaskId, and parent. Decision events pin the contiguous
sequence, exact ordered runnable queue, selected runnable TaskId, and the
observed operation class. Routed world operations carry their `HASH_V0`
identity. The parser validates semantic coherence and then requires
parse/serialize byte identity, including one final LF.

The compatibility policy is refusal: unversioned logs and every version other
than 1 return E0908 with guidance to record a fresh trace. No legacy bytes are
guessed or migrated. Unknown fields/operations, noncanonical whitespace,
duplicate creations, invalid parents, noncontiguous decisions, duplicate or
unknown runnable IDs, choices outside the queue, creations/decisions beyond
their declared bounds, queues wider than `max-tasks`, and statically terminal
TaskIds reappearing after `return`/`failure` are rejected during load. The
validator uses hash-table membership in one linear pass and never derives
ordering from hash-table iteration.

CLI replay loading is incremental: the header is capped at 4 KiB, each line at
1 MiB, the whole transport at 64 MiB, and the input at 200,001 lines. After the
header, the declared task/decision bounds reduce both line and byte ceilings.
The complete string is allocated only after those checks. Missing/unreadable
paths and delayed record-write failures retain exact E0908 diagnostics;
recording still opens its output only after successful program completion.

`Schedule_control` validates the complete header before root-scope allocation.
It consumes each expected creation before `Structured_scope` mutates allocation
state, and consumes each exact sequence/queue/choice before advancing the
chosen evaluator state. The resulting operation is compared before spawning or
opening a scope and before dispatching a routed world callback. EOF, leftovers,
missing/extra/reordered/impossible events, queue drift, and operation drift are
fatal E0908 results followed by recursive cleanup; replay has no FIFO fallback.

An explicit fork strictly consumes all earlier decisions, validates the exact
queue at decision K, and accepts only a named runnable TaskId. The new branch
then uses FIFO and its canonical header records `fork=K:TASK`. Strictly replaying
that branch checks all recorded bytes normally; the provenance field grants no
exception. `Round_robin.run_expr_scheduled` provides Record, Replay, and Fork
modes. The CLI maps them to `--schedule-record`, `--schedule-replay`, and
`--schedule-fork K=TASK`, requiring exactly one scheduled top-level expression
and writing output traces only after successful completion.

`test_schedule_trace.ml` pins the exact header, canonical identity and round
trip, explicit fork provenance, old/unknown/noncanonical refusal, declared
task/decision/queue bounds, terminal reappearance, and malformed semantic
records. `test_round_robin.ml` pins byte-identical record/replay,
missing and extra events, strict fork and replay of its branch, creation drift
before allocation, and routed-operation drift before callback invocation. The
`schedule-replay.t` golden transcript exercises the public CLI with the exact
v1 bytes, malformed/legacy/impossible logs, missing/extra/reordered events,
declared-line and per-line transport refusals, missing/unreadable paths, a
post-success write failure, a flush-time write failure, fork-at-decision,
byte-identical original and fork replays, and an empty stdout probe proving a
one-bit world-operation-hash drift was refused before `print`.

Scheduler cache identity now includes `schedule-format-v1` in addition to the
program hash, scheduler identity, policy, and bounds. Cache payloads remain
proof-only and every hit still executes a fresh evaluator run.

## Budgeted exhaustive schedule enumeration

`Exhaustive_schedule` makes each exact runnable TaskId queue one ordered
multi-shot choice support. It explores every choice through SC.10 strict trace
forks. Each fork starts from a fresh evaluator run, so the search never copies
or consumes one affine Async resumption twice. The v0 search deliberately does
no state hashing, schedule deduplication, or partial-order pruning.

Reports contain the complete worlds, exact `explored` and `worlds_started`
counts, and `Complete` or structured incomplete reasons. Task, decision, and
world budgets are separately positive. A task- or decision-bounded prefix is
not counted as a complete world, and any exhausted budget prevents a complete
claim. The stopped prefix remains canonical and forkable, so earlier alternate
choices are explored even when the FIFO seed exceeds a bound. Unhandled routed
operations are recorded and refused before their root callback; the incomplete
reason names the exact decision and operation hash. Program failures remain
complete world results so a schedule-sensitive failure is visible rather than
aborting enumeration.

The hand-counted fixtures prove 2 schedules for one immediate child, 3 for one
yielding child, and 8 for two immediate children. A Warp `test.run` fixture has
exactly 2 schedules, produces the same passing report in both, and strictly
replays every canonical trace byte-for-byte. A fail-fast fixture reaches two
different first failures under its 8 schedules. Structured budget regressions
pin incomplete results at all three axes. Two uneven-tree regressions begin
with an over-budget FIFO seed yet retain exactly three shorter worlds: one at
five decisions and one at three tasks. A hostile Console fixture proves the
installed callback is never invoked. The multi-shot handler gauntlet and the
eight-world two-child fixture prove no world reports E0906, each world creates
exactly three tasks, and recursive affine-ownership metrics drain to zero.

## Seeded randomized Warp schedules

`jacquard test --schedules N --seed S` reruns every hermetic Case under the
`seeded-random-v0` decision policy. The CLI rejects non-positive `N`, rejects a
missing or malformed seed, and never calls `Random.self_init` on this path. A
SplitMix64 stream mixes the root seed with the canonical discovered-member hash
and a length-framed relative group/Case label path, excluding the renameable
top-level name, plus the zero-based structural child-index path to the leaf. The
framing distinguishes NUL-containing labels and the indices distinguish
duplicate labels. The resulting identity supplies an independent decision seed
to each run and is also the program identity checked before strict replay.
Discovery order, top-level renames, cache hits, and host `Random` state therefore
cannot move a test's schedule stream.

Only the D46 choice changes: each step selects an index from the exact ordered
runnable queue using 62-bit bounded-integer rejection sampling. The fixed
three-way-queue regression and 10,000 bounded draws pin non-power-of-two range
behavior without float or modulo bias. The scheduler still records format-v1
creation and decision events. Strict replay accepts the scheduler identity stored in a validated
trace and checks every queue, chosen task, and operation without drawing again.
The focused scheduler regression pins same-seed byte identity under different
host random states, a changed interleaving for another seed, and byte-identical
strict replay of the seeded trace. Warp identity regressions pin distinct seeds
and trace identities for duplicate labels and for `["a"; "b"]` versus
`["a\000b"]`, plus strict refusal when a trace from one duplicate-label leaf is
presented to the other.

The first failing Warp execution prints the root seed, child decision seed, and
exact rerun command. It prints a canonical schedule log only after a complete
trace; the decision-bound regression pins a seed/rerun/error refusal with no
partial-log claim. The CLI transcript runs the ordinary failing command twice
and byte-compares the failures. It also pins positive-count and explicit-seed
diagnostics, pass reporting, and cache misses when either `N` or `S` changes.
The scheduled cache key is the ordinary Merkle member/Prop key plus
`seeded-random-v0`, the schedule-leaf identity version, `N`, and `S`; the
schedule trace program identity is the framed member/label/structural-index
identity. A top-level rename is a cache hit with current display text, while a
Case-label edit is a miss. Scheduled failures are not cached; a shared-cache
moved-path regression proves their replay command is rebuilt from the current
source/prelude paths. WorldTests remain uncached and Props retain their separate
data-generation modes.

SC.11 seeded scheduling remains part of this successor. Host scheduling remains
outside SC.12.


## SC.13 typed-channel freeze

The machine-readable taxonomy and two executable checker fixtures agree on four
`once` operations:

```text
channel.open : (Int) -> Result ChannelError (ChannelHandle a)
channel.send : (ChannelHandle a, a) -> Result ChannelError ()
channel.recv : (ChannelHandle a) -> Result ChannelError a
channel.close : (ChannelHandle a) -> ()
```

`ChannelError` is exactly `ChannelClosed | InvalidCapacity(requested: Int)`.
The complete HASH_V0 identities are pinned by `effect-taxonomy/2`:

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

The positive fixture pins rows for open/send/recv/close and proves Async's
existing shared child-row law produces `{Async, Channel}` for a spawned sender.
The negative fixture rejects sending `Text` through `ChannelHandle Int` with
E0804 before a runtime exists.

The SC.14 routing boundary is also frozen: only the exact Channel whole/member
identities are admitted by the default interpreted scheduler, never by
`--allow channel`. The chosen task's current root or nested structured scope is
the owner; a near-match, raw evaluator call, or native execution receives no
special Channel route. `async.scope` still subtracts only Async, leaving Channel
visible in the outward row until scheduler admission or an ordinary language
handler intercepts it.

Capacity zero is rendezvous; a positive capacity is bounded FIFO; a negative
capacity returns typed `InvalidCapacity` before allocation. The contract fixes
oldest-waiter pairing, bounded backpressure, buffer-first receive with sender
promotion, counterpart-before-current wake order, deterministic fan-in, and
idempotent drain-on-close. Cancellation is delivered before channel mutation
and removes a blocked waiter without reordering survivors. Handles are exact
run/scope capabilities and escape or parent/descendant use is E0907.
Fail-fast removes channel-blocked siblings through cancellation; collect does
not cancel or auto-close. Under either policy, an all-channel-blocked live set
with no possible transition is E0908; fail-fast has no failure to prefer.

`corpus/channel/rendezvous-v1.trace` and
`corpus/channel/buffered-v1.trace` pin exact abstract states, results, and wake
order. Together they include negative capacity without ChannelId consumption,
chosen-task wake after successful open, rendezvous, buffer promotion, blocked
receiver and sender cancellation, survivor order, close rejection/wakeup,
drain order, and an explicit second close. Their SHA-256 identities are pinned
by the focused test, which parses and checks every semantic field and contiguous
decision number. These are SC.14 acceptance fixtures, not runtime transcripts.
Actors, supervision, select, unbounded/cross-scope channels, host I/O readiness,
and channel runtime remain excluded.

## Compiled test discovery

The lifecycle evidence is registered directly in the compiled Alcotest
inventory rather than hidden inside the effect-taxonomy governance case. The
seven independently selectable groups and their case names are:

| group | compiled case |
|---|---|
| `scheduler-core` | `lifecycle, waits, cycles, and ownership` |
| `structured-scope` | `nested ownership, cleanup, and escape` |
| `cancellation` | `cooperative boundary delivery` |
| `scope-policy` | `fail-fast and collect aggregation` |
| `round-robin` | `real evaluator FIFO lifecycle` |
| `schedule-trace` | `canonical codec and identity`; `legacy, unknown, and noncanonical refusal`; `impossible event refusal` |
| `exhaustive-schedule` | hand counts; Warp/replay; schedule-sensitive failure; budgets and stopped-prefix alternatives; hermeticity; Once ownership |

The exact discovery and focused execution commands are:

```sh
opam exec -- dune build test/test_jacquard.exe
(
  cd _build/default/test
  ./test_jacquard.exe list --color=never 2>/dev/null |
    grep -E '^(scheduler-core|structured-scope|cancellation|scope-policy|round-robin|schedule-trace|exhaustive-schedule) '
  ./test_jacquard.exe test \
    'scheduler-core|structured-scope|cancellation|scope-policy|round-robin|schedule-trace|exhaustive-schedule' \
    --compact --color=never
)
```

The compiled inventory is exactly 687 cases and the source inventory is 39
cram transcripts. `effect-taxonomy/2` is the independently selectable SC.13
interface, trace, and checklist proof; the seven scheduler/lifecycle suites
execute exactly once during the full gate.

Native scheduling remains outside the current backend. Differential coverage is
therefore limited to the supported case: an Async operation discharged by an
in-language handler produces byte-identical interpreter/native output. No Task
carrier, native runnable queue, performance work, or unsupported root Async
grant was added.

## Reconstruction and verification

The manifest is the complete SC.13 successor overlay on validated SC.12 commit
`2fc2d306c1236b8faeaee37a2e1c9d2848d16f52`. Reconstruct it under repository-local
scratch space:

```sh
set -eu
base=2fc2d306c1236b8faeaee37a2e1c9d2848d16f52
dest="$PWD/.scratch/sc13-evidence-copy"
manifest=docs/release/structured-concurrency/MANIFEST.sha256
rm -rf "$dest"
mkdir -p "$dest"
git archive "$base" | tar -x -C "$dest"
mkdir -p "$dest/$(dirname "$manifest")"
cp -p "$manifest" "$dest/$manifest"
awk '!/^#/ && NF == 2 {print $2}' "$manifest" |
while IFS= read -r file_path; do
  mkdir -p "$dest/$(dirname "$file_path")"
  cp -p "$file_path" "$dest/$file_path"
done
```

Snapshot the reconstructed source tree, then run every verification command
against that archive destination. The snapshot excludes only Dune output and
recipe-local scratch state, so the final comparison is a deterministic
non-Git cleanliness check:

```sh
eval "$(opam env)"
mkdir -p "$dest/.scratch/tmp"
export TMPDIR="$dest/.scratch/tmp"
snapshot="$dest/.scratch/source.before.sha256"
snapshot_source() {
  (
    cd "$dest"
    find . -path './_build' -prune -o -path './.scratch' -prune -o \
      -type f -print0 |
      LC_ALL=C sort -z |
      xargs -0 sha256sum
  )
}
snapshot_source >"$snapshot"
"$dest/scripts/release/check-structured-concurrency-manifest.sh"
opam exec -- dune build @all --root "$dest"
opam exec -- dune runtest --force --root "$dest"
opam exec -- dune fmt --root "$dest"
snapshot_source | cmp "$snapshot" -
opam exec -- dune build @doc --root "$dest"
```

Expected results are zero exits, 687 compiled Alcotest/QCheck cases, 39 cram
transcripts, and 27 doctest examples across 8 documents.

The default interpreted CLI, prelude-evaluation, and Warp Case paths use this
scheduler. `async.scope` is a trusted internal term marker, not a fifth Async
operation, and opens a real nested `Structured_scope`; all four frozen operation
hashes remain unchanged. Raw `Eval.run_expr` remains a low-level unscheduled
seam. SC.4 continues to supply the static child-effect law: a scope discharges
only Async and retains child world effects. Native root scheduling remains
future work; native parity evidence is labeled only for Async discharged by an
in-language handler. SC.11 randomizes this explicit interpreter decision seam,
while SC.12 adds hermetic bounded exhaustive exploration. Neither claims host
scheduling.
SC.13 adds only the Channel contract, published identity, checker fixtures, and
acceptance traces. Channel remains visible in outward effect rows and has no
runtime route until SC.14; the SC.10-SC.12 scheduling and replay guarantees
remain unchanged.
