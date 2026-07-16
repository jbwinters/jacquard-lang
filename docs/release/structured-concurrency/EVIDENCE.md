# Structured Concurrency SC.8 Evidence

Status: deterministic fail-fast-default and collect scope policies are
implemented over the validated SC.7 cancellation and ownership layer. Terminal
observations consume explicit scheduler decision numbers, sibling cancellation
uses the SC.7 destruction boundary, and aggregate results preserve input order.
This milestone intentionally contains no runnable-queue policy, host
concurrency/I/O, or detached/root Async handler.

- Reconstruction base: `6321ce5`
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
child effects remains visible in the shared caller row.

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

All four Async operations are reviewed as `once`; no handler is installed.
Direct evaluator calls therefore reach the ordinary `Unhandled` result for
spawn, await, cancel, and yield. The CLI rejects an unhandled Async program at
its effect gate with E0814. Neither path schedules work or grants ambient
authority.

`TaskResult` constructors execute in both tiers. The `task-values.t` cram test
byte-compares interpreter and native output for Done/Failed/Cancelled, tests
the private carrier diagnostic, and pins the clean unhandled CLI failure. The
C/OCaml show parity corpus includes a redacted inert Task value.

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
runnable. No terminal cycle member can appear in the returned wakeup list. The
core returns the handles made runnable by a transition but has no runnable queue
and makes no policy decision.

Focused Alcotest and QCheck coverage pins the transition table, resume-token
ownership, deterministic IDs, yield suspension/wakeup, multiple waiters,
immediate terminal awaits, completion/failure/cancellation, self-await, closed
two- and three-node cycles, external/cancelled waiter controls, a property that
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
point; no continuation is returned for a post-cancel user step.

Focused Alcotest coverage pins all three boundary classes, no-waiter/no-child
preemption, routed-effect fault injection, duplicate/completed/self behavior,
and the exact public handoff that destroys suspended resume token 21 once. It
also pins the rule that a pre-cancelled caller does not request another target.
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
scheduler decision number. Decision violations, unregistered same-scope
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
input order; if callbacks raise, the first exception is re-raised only after all
sibling attempts finish. Finish remains unavailable until every child is
observed terminal, so the scope cannot expose an undrained aggregate.

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

## Reconstruction and verification

The manifest is the complete SC.8 successor overlay on validated SC.7
integration commit `6321ce5`. Reconstruct it under repository-local scratch
space:

```sh
set -eu
base=6321ce5
dest="$PWD/.scratch/sc8-evidence-copy"
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

Runnable-queue policy and the Async root handler remain later C1 tasks. SC.8
supplies policy aggregation over explicit terminal decisions, but it does not
choose a next continuation or install the compile-only `async.scope` fixture as
a root handler. SC.4 continues to supply the static child-effect law, including
the law that a scope discharges only Async and retains child world effects.
