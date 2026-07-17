# Structured Concurrency C0-C2 Limits

Status: explicit SC.16 claim boundary at base
`b82809959c085a51eb3e9f8ae7623692983acd65`.

This document says what the C0-C2 evidence does not prove. A later milestone
may add one of these features, but that later evidence must stand on its own;
it cannot silently widen this gate.

## C0 is a sequential hint

`parallel.map` and `parallel.both` require pure callbacks and preserve source
order, but they do not create workers. The interpreter and native backend both
run them sequentially. The native audit found three blockers: callback row
proofs are not retained into emitted C, runtime allocation/reference counting
is single-threaded, and worker failures cannot yet be joined and selected in
source order. C0 makes no speedup claim.

## Task scoping is checked dynamically

Task handles are opaque and owned by one scheduler run and one exact structured
scope. Recursive runtime guards reject direct, nested, retained, stale, and
cross-run escape with E0907. This is a dynamic boundary, not a rank-2 type
proof. A bad program can reach the diagnostic at runtime; the type system does
not make Task escape unrepresentable.

## Cancellation is cooperative

A requested cancellation is delivered only at `async.await`, `async.yield`, or
an effect routed through the scheduler. Pure code that never reaches one of
those boundaries can run forever and prevent fail-fast drain. There is no
preemption, timeout, fairness theorem, or progress guarantee.

## Cleanup is an explicit bracket contract

Scope teardown removes scheduler-owned continuations and invokes each
destruction callback exactly once on normal, diagnostic, and host-exception
paths. That releases runtime continuation memory. It does not automatically
close files, sockets, or other external resources. Programs must use an
acquire/release handler around resources that cross a suspension point. There
are no language finalizers.

## C2 is bounded interpreter model checking

Record, replay, seeded schedules, and exhaustive enumeration operate on the
interpreted scheduler decision seam. Exhaustive enumeration is complete only
within its positive task, decision, and world budgets. It performs no state
hashing, partial-order reduction, or schedule deduplication. An exhausted
budget is an explicit incomplete result, never a proof.

Exhaustive worlds are hermetic: an unhandled routed world effect is refused
before its callback. Language-handled effects remain usable. Seeded randomized
Warp schedules require an explicit seed and are reproducible, but a finite
sample is not exhaustive evidence.

## Unsupported runtime seams

- Raw `Eval.run_expr` is the unscheduled low-level evaluator seam.
- The native backend has no root Async scheduler. Native parity is claimed only
  when an in-language handler discharges Async before the root.
- There are no detached/daemon tasks or fire-and-forget root handlers.
- There is no shared mutable memory, lock, atomic, or data-race model.
- There are no host threads, host scheduling, or real asynchronous host I/O.

## C3 and C4 are not part of this gate

At this exact base there are no typed channels, select, timeouts, mailboxes,
actors, links, monitors, supervision trees, or host asynchronous I/O. Those are
C3/C4+ work. Their absence does not block the C0-C2 release gate, and the C0-C2
evidence must not be quoted as proof for them.
