# DES.6 Invocation Allocation Limits (RT.2)

- Status: accepted. Revision 3 followed two design reviews, and the owner
  adopted the recommended option of every decision in §10 on 2026-10-27.
- Implementation: in slices. Slice 1 adds the `Alloc_meter`, `--alloc` for
  `jacquard run`, E0921, and the evaluator's own charging points: closures,
  tuples and constructors, environment bindings, continuation capture and
  resumption, with memoized terms charged once per invocation as fuel is (§3.1,
  §3.2). Slice 2 classifies and charges every native and makes the other
  drivers (`infer`, `test`, `model eval`, Warp, the host worker) honour the
  budget. Slice 3 adds the registry ceilings (§4), the refusal for native
  builds (§7) and the overhead measurement (§8). Until slice 2, natives
  allocate uncharged. Slice 2a makes every driver report allocation exhaustion
  as incomplete E0921, as it reports fuel's E0919: the scheduler, exact
  enumeration and likelihood weighting, observation transcripts
  (`incomplete code=E0921`) and exit codes; it adds `--alloc` to
  `jacquard infer` and `jacquard host worker`. `jacquard test --alloc` (per
  test, with Warp's cache key) and the natives are slice 2b. A model document
  has no allocation budget, so `model eval` cannot run out of one yet.
- Owner decision (2026-10-29), from slice 1's review: every charge is enforced
  when made, including inside a memoized term's first evaluation. A warm hit
  replays that term's recorded cells per segment, after the segment's fuel. When
  one budget runs out, a warm and a cold run end with the same outcome and the
  same count on that budget; the other budget's count may differ by one
  segment's charges. When both budgets run out inside one memoized term's first
  evaluation, the two runs may report different codes (E0919 or E0921) and
  counts; both are incomplete.
- Task: RT.2. With RT.1 (fuel-v1, done) it gates the host's process lifecycle
  limits.
- Builds on: `docs/computation-fuel.md` (one budget per invocation, a
  process-wide meter, nested caps that draw on the aggregate, typed
  incompleteness, `(model, budget)` cache keys).

## 1. Question

fuel-v1 bounds computation. A bounded run can still build a very large value,
spawn unboundedly many tasks, or hold an exponential number of resumptions in
an inference frontier within its fuel budget (`computation-fuel.md` §7). A host
needs to say "this invocation may not allocate more than N" and get a
deterministic, reproducible refusal, the same way fuel gives one for
computation.

What Core can honestly measure is **logical allocation**: the values, text,
continuation frames and registry entries the evaluator itself creates. It
cannot measure the OCaml heap, GC timing or process RSS deterministically, and
must not claim to.

## 2. Three quantities, kept apart

| quantity | what it is | who bounds it |
|---|---|---|
| cumulative logical allocation | every value node, text byte, frame and registry entry the invocation created, whether or not it is still reachable | Core: `alloc-v1` budget (§3) |
| live retention in named registries | entries currently held: live tasks, channel buffers, an inference frontier's pending branches | Core: count ceilings per registry (§4) |
| physical memory (heap, RSS) | what the process actually uses, including the runtime and GC slack | the host: Host 10's process limits. Core reports no number for it |

Cumulative allocation is deterministic: the same program, inputs and seed
allocate the same units on every machine. Live heap size is not (it depends on
when the GC runs), so v1 does not bound general live retention, only the named
registries whose sizes the evaluator tracks exactly.

## 3. The `alloc-v1` cost model

One process-wide meter, `Alloc_meter`, beside `Fuel_meter`, copying its
semantics exactly (`fuel_meter.ml`): one budget per invocation
(`Eval.with_invocation ~alloc:n`); a sticky trip once exceeded; the same epoch
and depth rules, so a nested invocation on another evaluator draws on (and can
drain) the outer one; natives cannot catch exhaustion. Nested runs, re-entry
from natives and root handlers, every resumption (including those a driver makes
through `Eval.resume_captured_state` and those the scheduler makes), every
inference branch and every task draw on it; forks never get a fresh or copied
allowance. Scopes are combined: `Eval.with_scope ~fuel ~alloc` caps a branch
on both meters and opens the one memo epoch fuel already opens (`eval.ml`
`with_fuel_scope`), so `jacquard test` gets per-test caps of both. Units are
**cells**. When fuel and allocation trip at the same transition, fuel is
reported (it was debited first); either way the outcome is incomplete.

### 3.1 What is charged, and when

Allocation that is O(1) per machine transition (a let or match binding, a
closure, a small constructor) is already bounded by fuel, since each costs a
transition. Allocation bounds matter where one transition can allocate a lot.
Every site is one of three kinds:

| site | cells | when charged |
|---|---|---|
| constructor, tuple, closure, mutable cell (evaluator) | 1 + fields (a closure: 1; its environment is shared by reference) | before |
| environment binding (`Env.add` in let/match/handler binders) | 1 | before |
| capturing a continuation | 1 per captured frame | before |
| resuming a continuation (any resumer) | 1 per reinstalled frame | before |
| natives with a size known from their arguments (`text.concat`, `text.join-list`, `text.slice`, `text.trim`, `text.from-*`, `list.*` of known length, `support` (a `UniformInt` is `hi-lo+1`, capped at 10,000), `code.*` conversion) | 1 + ⌈bytes/8⌉ or 1 per node | before (pre-sized) |
| natives whose result size is found while building (`text.split`, `dist.sample-lw`'s fold, `code.un-form`, `debug.inspect` and printer renderings) | as above | **counted while built**, stopping at the budget; overshoot at most one element |
| root handlers returning external text (`read-line`, `fs.read`, `net` responses) | 1 + ⌈bytes/8⌉ | **before reading**: `fs.read` checks the file's length against the remaining budget and refuses with E0921 before reading; `read-line` and `net` read at most the remaining budget plus one byte, and exceeding it is E0921. No external read is unbounded under a budget |
| `eval` of code: kernel and resolution structures | 1 per kernel node | before (the code value's size is known). Type-inference structures can outgrow the input; they are bounded by fuel (the checker ticks `Fuel_meter`), not by cells |

Charges for the same value never repeat: sharing, reading, matching and
environment lookup cost nothing. A one-shot resumption (`Once_kont`, resumed
through `apply`) is charged per reinstalled frame like a multi-shot one.

The slice classifies **every** native in `prelude.ml` into one of these rows,
and a test fails on any native without a classification.

### 3.2 Not charged to the invocation

These allocations are real but are not owned by one invocation; each is named
here with its bound:

- **Memo values and snapshots** (`memo`, `evaluator_mutable_snapshots`,
  `Physical_cache`s) live for the evaluator's lifetime. A memoized term's
  allocation is recorded beside `memo_charge` and charged once per memo epoch
  (an invocation, or a scope that opens its own epoch), as fuel's memo charge
  is, so a warm and a cold run cost the same, but the retained memory belongs to
  the evaluator's owner: in a long-lived `host worker`, the host (Host 10).
- **Scheduler trace renderings** and **`--infer-cache` entries** are bounded by
  fuel (their rendering walks are metered) and by `--max-decisions`; they are
  not charged again.
- **Decoded host requests** are charged to the invocation they start, after
  decoding; the host's frame limit bounds the request itself.

## 4. Registry ceilings (live retention)

Separate ceilings bound what an invocation retains at once. Each is one
process-wide counter for the whole invocation (not per scheduler, so a nested
`async.scope` cannot reset it):

| registry | ceiling | released |
|---|---|---|
| retained tasks (live or finished but still awaitable) across all scopes | `--max-tasks N` | when their scope is torn down or the invocation ends, not at cancellation (a cancelled task keeps its result for later awaits) |
| open channels | `--max-channels N` | at scope teardown or invocation end |
| retained channel values: buffered slots plus values held by blocked senders | no separate ceiling: opening a channel charges its declared capacity as cells (so buffered slots are paid for in advance), and each blocked sender is a retained task under `--max-tasks` | as above |
| an enumeration's pending entries: the remaining support entries at every level of the depth-first search | `--max-frontier N` bounds **live** entries (the support list is charged as cells when materialized); `--max-branches` and `--max-decisions` keep bounding **total** branches and decisions. When several trip at one step, the first checked is reported: fuel, then allocation, then the frontier, then branches | as the search returns |

Pending scheduler registrations are per task, so `--max-tasks` covers them.
Release runs in the same teardown path on normal exit, exceptions, and fuel or
allocation exhaustion (the scope's `finally`), so a failed invocation leaves
no registry entries counted.

Likelihood-weighting particles run one after another and are never retained
together, so `--samples` is not a retention ceiling and none is added.
Resumptions are charged per reinstalled frame (§3.1); sibling enumeration
entries share one resumption, so nothing is counted twice.

## 5. Exhaustion and evidence

- Running out is **incomplete**, never a pass, a program failure or a completed
  search: diagnostic E0921 (allocation budget or a named registry ceiling
  reached), exit 2, as E0919 is for fuel. `jacquard test` reports `INCOMPLETE`
  and caches nothing; inference reports no partial posterior.
- With `--alloc`, commands print `alloc: N of M cell(s) used (alloc-v1)`.
- Caches key on `(alloc_model, budget)` and on each ceiling given (Warp:
  `alloc=alloc-v1:UNITS`), as for fuel.

## 6. Surfaces and the host boundary

`--alloc UNITS`, `--max-tasks`, `--max-channels` and `--max-frontier` on
`run`, `infer`, `test` (per test, through the combined scope) and `host worker`.
Default unbounded, as for fuel; a new surface that promises bounded execution
must require a budget.

| limit | enforced by |
|---|---|
| computation (fuel-v1), logical allocation (alloc-v1), registry ceilings | Core |
| host frame size and stderr bytes (`Host.hard_limits`, `host_worker.ml`) | Core's host carrier, already |
| RSS, wall-clock, CPU, the evaluator-lifetime memo and caches of a long-lived worker | the host process (Host 10) |

## 7. Native and unsupported enforcement

The native backend has no allocation or registry accounting. `--alloc` and every
registry ceiling are refused for native builds (a diagnostic), never silently
ignored. A host-registered native (`Eval.register_builtin`) must charge its own
allocation through `Alloc_meter`, as it must tick fuel; documented as a limit.

## 8. Overhead and acceptance

Accounting runs in unbounded mode too (memoized costs must not depend on a
budget). The overhead is measured on a fixed workload, the interpreter suite's
`test_jacquard.exe` focused runs plus `demos/inference`, against the parent
commit; the acceptance threshold is **at most 10 % wall-clock** (for scale, the evaluator's
coverage bookkeeping measured 12 %, `eval.ml`). A larger overhead fails the slice.
Acceptance (from the task):

- large values, retained resumptions and an enumeration frontier exhaust their
  budget or ceiling deterministically with E0921;
- registry counts return to their pre-invocation values after scope teardown,
  cancellation followed by teardown, and exceptions;
- a nested call, a nested invocation or a scope cannot reset the aggregate;
- the measured overhead is within the threshold;
- the host-versus-Core boundary table (§6) is in the docs and in Host 10's gate.

## 9. Alternatives considered

- **Fold allocation into fuel** (charge construction as fuel): one budget, but
  a host could not say "plenty of time, little memory", and fuel-v1's meaning
  would change (a new model for every existing budget).
- **Bound the OCaml heap via `Gc` statistics**: closest to physical memory but
  nondeterministic (GC timing, other invocations in the same process), so a
  result could not be reproduced or cached.
- **Bound only registries**: cheap, but a single huge value or text would pass.

## 10. Owner decisions (adopted 2026-10-27)

The owner adopted the recommended option of each decision.

1. **A separate `alloc-v1` budget in logical cells** (recommended), rather than
   folding allocation into fuel or measuring the heap.
2. **Cell weights and charging points** as in §3.1, including the three
   charging kinds (before / counted while built / after for external text).
3. **Registry ceilings v1:** retained tasks, open channels and the pending
   enumeration frontier, released at scope teardown (recommended); general live
   retention and evaluator-lifetime memo growth left to the host.
4. **Refuse `--alloc` and the ceilings for native builds** (recommended) rather than labelling
   the result unbounded.
5. **Diagnostic E0921** shared by the budget and the registry ceilings, naming
   which one was reached (recommended), rather than one code each.
6. **Overhead threshold** of at most 10 % wall-clock on the fixed workload
   (recommended).
