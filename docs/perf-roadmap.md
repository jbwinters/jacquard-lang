# Native performance: the levers still on the table

Status: BACKLOG (2026-07-07). This doc names the optimization work worth
pursuing after the first native perf arc (tasks 84, 86, 80, 85, 82,
plus the declined 79 and 81), with the measured evidence each lever
stands on. Nothing here is scheduled. The discipline that governed the
arc governs anything picked up from this list: start from a profile,
land through the full gate (differential harness under both toolchains,
leak battery, fuzz lane), and finish as either a measured table delta
in docs/benchmarks.md or a decline record with the data — both outcomes
count as done.

## Where the time goes today

From the benchmark report (docs/benchmarks.md, same session):

- **sort, 92-96 ms vs 24-27 ms hand C (3.4-4.0x across sessions)** —
  the one scenario
  outside the withdrawn near-C claim's 3x gate. The residue is RC
  traffic on field reads: every `jq_con_fields` access in the merge
  dups a value the callee immediately consumes.
- **state-loop, 159 ms vs 76 ms of Python method calls (2x)** — the
  suite's only row where Python wins. The cost is handler dispatch: a
  tail-resumptive perform walks the handler stack and calls the clause
  closure through the uniform ABI on every operation.
- **fib, 4-5 ms vs 3 ms hand C** — the residue (per the task-79
  decline's disassembly) is the boolean living as a static CON matched
  through pointer, tag, and con-info compares where C uses a CPU flag,
  plus tagged-int arithmetic. Small in absolute terms.
- **avl, 13-14 ms** — reuse tokens are off inside framed bodies (task
  82's one traded discipline), so any framed map traffic re-allocates
  spines it could recycle.

## The levers, in rough expected-value order

### 1. Borrow inference (sort's residue)

A real Perceus-style borrowing pass: prove a read never outlives its
parent and emit no RC for it, instead of dup-then-consume. This is NOT
the declined task-81 flip — that experiment moved drops from callee to
caller uniformly and lost, because the owned convention is type-aware
and moves already make last-uses free. Borrow inference is the version
the literature actually ships — the borrowing discipline Koka layers
over Perceus (the Perceus paper's §2 machinery, dup/drop/reuse, is what
tasks 68/80/85 already built; borrowing is the layer above it): a
static analysis that marks parameters and field reads observation-only.
The target is the merge loop's per-field dup/drop pairs. The bar comes
from the task-81 decline record in task-master, adopted here as policy
for every lever on this list: a suite-wide Pareto win or it does not
land.

### 2. A C FFI (a different axis, probably the biggest practical win)

The benchmark report's calibration note (docs/benchmarks.md, end of
the readings) is the argument: idiomatic Python escapes to C (numpy,
dict, sorted) and effectively becomes C.
Jacquard has no escape hatch, so every hot kernel must out-compile
CPython's C internals instead of joining them. A foreign-function story
changes the economics of every future "make X fast" request from
compiler work to binding work. Design constraint that makes this a real
project rather than a weekend: foreign calls must thread the capability
model — an FFI call is an effect with a grant (`--allow ffi:...` or
per-library manifests), not a hole in the row system. The eval-authority
asymmetry note (SL.8) is the precedent for how to reason about it.

### 3. Evidence-passing handlers (state-loop's residue)

The design doc's pillar 1 already names the destination: compile
tail-resumptive handlers to an indirect call through an evidence vector
(Xie & Leijen, ICFP 2020/2021, as shipped in Koka), so a perform in the
common case is one load and one call instead of a handler-stack search.
The measured gap this attacks is the 2x against Python method calls —
the one headline currently pointing the wrong way. This is the deepest
compiler change on the list (it touches the perform protocol, the frame
machinery, and the LW driver's root hooks), so it wants its own design
round before code.

### 4. Reuse tokens inside framed bodies (avl's traded discipline)

Task 82 ran the precise walk over frame machines but kept reuse OFF
there: a detached shell held across a suspension has no owner in the
frame. The refinement is scoped reuse — allow a token when no
suspendable site sits between the take and its refill (a syntactic
check over the NIR interval). Framed map/fold traffic gets its in-place
spine rebuilds back. Small, well-bounded, and the leak battery plus the
multi-shot gauntlet make the safety argument checkable.

### 5. Unboxed booleans and match decision trees (fib's residue)

Two small emitter projects with one theme — stop paying CON machinery
for control flow: render intrinsic comparison results as branches
instead of materializing the static true/false CON and re-matching it
(the emit layer knows both producer and consumer), and compile
multi-clause matches to decision trees instead of if-chains. Expected
value is small on the current suite (fib is already 1.3-2.5x C) but
these compound with everything else, and the boolean one is likely a
half-day experiment.

## Not worth redoing (measured declines, with records)

- **Arity-exact signatures** (task 79, cancelled): LTO's interprocedural
  dead-argument elimination already rewrites hot fns to tight
  conventions — verified by disassembly. Reopen only with a stable win
  over the LTO default on an unregressed suite.
- **The intrinsic borrowing flip** (task 81, cancelled): uniformly
  borrowed intrinsics regress int-heavy code because the owned
  convention is type-aware. Superseded by lever 1, which is inference,
  not a convention flip.
- **Interpreter speed rungs**: docs/perf-vm-decision.md declined them;
  the native tier is the answer to interpreter speed, at 18x (text,
  where every engine lives in memcpy) to ~760x (enum) across the suite.

## Adjacent, not perf

An embedded interpreter tier inside native binaries (an "eval island")
would let programs like demos/repair.jqd ship as one binary instead of
a native/interpreter hybrid. That is a capability-model project, not an
optimization — filed here only so nobody mistakes the E1102 boundary
for a performance gap: the mutate bench shows the native side of the
repair pipeline is the fast half already.
