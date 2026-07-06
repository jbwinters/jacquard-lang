# PF.2: native compilation for Jacquard — a design document

Status: ACTIVE — owner decision 2026-07-05: build it. The execution plan,
specified to task level with definitions of done, is docs/native-plan.md
(task-master 65-76); this document remains the design record. This document
records the four-pillar route from the current CPS tree-walker to native
performance while its reasoning is fresh, states which programs stay slow, and
bounds the claim. The plan's culture: big directions start as decision docs.

## Why this is plausible at all

Jacquard's semantics were chosen for analyzability: strict evaluation, immutable
data, a 27-form kernel, effects visible in rows, and content-addressed
definitions. Each pillar below converts one of those choices into performance.

## Pillar 1: rows as tiers

The effect row is a static cost model. Compile each arrow by its row:

- **Empty row `{}`** — plain host-stack calls. No CPS, no evidence, nothing.
  The ring-0 stdlib (the grid, map/set internals, dictionaries) lives here.
- **Tail-resumptive handlers** — the empirically dominant case (state.run,
  emit.pipe, every root grant): the handler resumes exactly once, in tail
  position. Compile to a single indirect call through an evidence vector
  (Xie & Leijen, ICFP 2020/2021, as shipped in Koka). No continuation is ever
  materialized.
- **Genuinely capturing code** — `abort`-style early exits and one-shot
  captures pay selective CPS on the affected paths only.
- **Multi-shot** — the priced tier: continuation cloning per extra resume.
  Enumeration, `fault.all`, and the exhaustive prop driver live here, and
  their cost is the branch count anyway — the clone is a constant factor on
  work that is exponential by design.

Jacquard-specific detail: the checker's row model (set-semantics heads, closed/var
tails, open coercion at App) already computes the tier at every call site. The
tier assignment is exactly `repr_row`'s answer at generalization time; no new
analysis is needed, only a place to persist it (the store object's meta is the
natural slot, and the metadata law keeps it out of the hash).

## Pillar 2: Perceus reference counting

Precise RC with in-place reuse (Reinking, Xie, de Moura, Leijen, PLDI 2021).
The Jacquard-specific gift: strict + immutable means pure data CANNOT form cycles —
a value only references values that existed before it. So RC is sound without a
cycle collector, EXCEPT for one documented seam: `let rec` closures (and the
mutual recursion inside defterm groups) form the only back-edges in the heap.
Treatment: closures created by `let rec` get a one-bit "cyclic" tag and are
collected by scope exit rather than pure RC — the same carve-out Koka makes.
In-place reuse pays off precisely where the stdlib works: `map.set` rebalancing
a freshly-uniquely-owned spine reuses every node it rebuilt, turning the AVL
update into imperative-speed pointer surgery without changing one line of Jacquard.

## Pillar 3: monomorphization by content hash

Dictionary passing (SL.2's explicit design) erases at compile time by
specializing each polymorphic definition per (definition hash, argument
dictionary hashes) tuple. The specialization cache key format:

    spec:<member-hash>:<dict-hash-1>,<dict-hash-2>,...

Content addressing makes this cache correct across builds and machines for
free — the same Merkle argument as Warp's test cache. `list.sort` specialized
at `int.ord` compiles the comparator to an inlined machine-int compare; the
comparator dispatch never exists at runtime (the dictionary record itself is
built once at startup and threads through as an ignored argument). Since
task 86 the key also covers capture-free lambda LITERALS, identified by
their lifted code (the host member's hash covers the body; top-level hosts
key by expression index, which bounds cross-build cache sharing, not
correctness): `list.fold` at
a known lambda calls its code directly, which removes the generic apply and
— because the clone no longer has an unknown callee — moves it off the
frame tier and back under precise Perceus. Measured on the fold-sum bench:
28 ms to 25 ms, and the mixed pure battery 29 ms to 22 ms; the remaining
cost is allocation (task 80). Capturing lambdas stay generic in v1.

## Pillar 4: the store as a whole-program compiler's dream

Compilation units are declarations; the dependency DAG is explicit and acyclic
(spec §6); rebuilds are exact (a definition's object code is keyed by its hash,
so editing one function recompiles its transitive dependents and NOTHING else —
the same invalidation Warp's cache already demonstrates for tests). Inlining
across definitions is licensed by hashes: an inlined copy records the hash it
inlined, and staleness is impossible by construction.

## The slow set, stated honestly

- Multi-shot exploration (enumeration, fault.all, exhaustive props): priced by
  branch count; native lowers the constant only.
- `eval`: dynamically loaded code enters at the tree-walker tier (or triggers
  runtime compilation, a later decision); the eval-authority asymmetry note
  from SL.8 applies unchanged.
- `debug.inspect` and reflective code paths: unspecializable by design.
- Programs whose rows never close (pervasively effect-polymorphic library code
  called from one site only) gain little from tiering until specialized.

## The claim boundary

"Near-C" is claimed ONLY for: ring-0/ring-2 code with closed empty rows, after
monomorphization, under Perceus with reuse — i.e., the arithmetic/collections
core of a typical program. It is NOT claimed for handler-dense control flow,
which targets the OCaml/Koka band, nor for multi-shot exploration, which is
priced by semantics, not implementation.

## Measured (task 75, 2026-07-06)

AMD Ryzen 9 7950X3D, Ubuntu clang 18.1.3, everything -O2 -flto (the
default since task 84 — cross-unit inlining of the RC and intrinsic fast
paths cuts 12-58% per program against the same table pre-LTO and is
byte-identical; cold builds are time-neutral, while warm no-op relinks
roughly double, ~225 ms to ~410 ms on the AVL battery, because LTO
codegen reruns at every link), median of 5,
per-engine startup subtracted (the C column is raw: its ~1 ms process
launch is not subtracted, so the ratios read conservatively). Reproduce
with `sh scripts/native-bench.sh`. The C references live in bench/ref/
and practice the same heap discipline as the programs they shadow — a
list merge sort over malloc'd nodes, not a flat-array qsort; review
verified neither reference constant-folds under -O2.

| program | interpreter | native | hand C | native vs C |
| --- | --- | --- | --- | --- |
| fib (fib 30) | 689 ms | 5 ms | 3 ms | 2.5x |
| sort (200k, int.ord) | 64864 ms | 92 ms | 27 ms | 3.8x |
| pure (mixed battery) | 3199 ms | 11 ms | — | — |
| avl (10k map.set) | 6224 ms | 13 ms | — | — |
| state-loop (1M get/put) | 23904 ms | 147 ms | — | — |
| enum (2^14 branches) | 10530 ms | 15 ms | — | — |

The progression, for the record — task 75 as first measured, then with
-flto default (task 84), the small-block pool (task 80), the
header-inlined RC fast paths (task 85), and Perceus over frame machines
(task 82): fib 19 / 8 / 8 / 5 / 5 ms, sort 279 / 189 / 118 / 97 / 92 ms,
pure 37 / 29-22 / 13 / 11 / 11 ms (the 22 includes task 86's lambda
spec), avl 33 / 24 / 22 / 14 / 13 ms, state-loop 250 / 203 / 190 / 172 /
147 ms, enum 40 / 35 / 25 / 15 / 15 ms.

**The near-C claim stays withdrawn at task 75's gate (BOTH fib and sort
within 3x of hand C): fib passes at 2.5x, sort does not at 3.8x.**
What the measurements support: the native tier is 138-705x the
interpreter (the table's own endpoints: fib and sort), the handler-tier state loop runs a
million get/put pairs in 147 ms (the OCaml/Koka band the boundary
paragraph promises), and multi-shot enumeration prices per branch as
designed. The remaining gap to hand C in the empty-row core:

- **fib, 2.5x** — arity-exact signatures for known calls (task 79) were
  implemented, measured as a no-op, and declined: LTO's interprocedural
  dead-argument elimination had already rewritten fib to a two-register
  (rt, n) convention (verified by disassembly). What that disassembly
  showed still standing — one out-of-line jq_drop(clo) call per node
  that LTO left unfolded — became task 85's target: with the dup/drop
  fast paths static inline in the header, that call becomes an inlined
  load-compare-skip (the compiler cannot prove the global's rc is
  invariant, so the no-op executes but the call overhead and ABI spills
  are gone) and fib went 8 to 5 ms. The remaining 2.5x
  is the boolean living as a static CON matched through pointer, tag,
  and con-info compares where hand C uses a CPU flag, plus tagged-int
  arithmetic.
- **sort, 4.0x** (was 11x pre-LTO, 7.9x pre-pool, 4.7x pre-task-85) —
  allocation is size-classed freelists (task 80), and the header-inlined
  RC fast paths took the field-read dup/drop traffic from out-of-line
  calls to inlined branches (task 85: 118 to 97 ms). Intrinsic borrowing (task 81) was
  implemented, measured as a regression, and declined: the owned
  convention is type-aware (each intrinsic drops only its boxed args,
  so Perceus moves make last-uses free), and the flip cost fib/sort/pure
  while winning only on naive-framed code — which task 82 de-frames
  instead — and did, in task 82: framed bodies now run the precise walk
  (reuse tokens stay off there; a detached shell held across a
  suspension has no owner in the frame), the frame save-set is the
  Perceus-accurate owned-live set (moves and drops leave it), and the
  handler-tier state loop dropped 172 to 147 ms with sort at 92 and avl
  at 13.
- The task-71 regression (frame-style classification cost dictionary-
  driven members their precise RC: the AVL battery ran ~10 ms before
  task 71, 33 ms after) is closed: spec de-framed the common sites
  (tasks 69/86) and the frame tier itself runs the precise walk since
  task 82. avl sits at 13 ms in the current table — reuse tokens remain
  off inside framed bodies, the one discipline the frame tier still
  trades away.

## Phased sketch (sizes are order-of-magnitude)

1. **Tier tagging** (~1 week): persist row tiers in store meta; assert the
   dominant-case statistics the design assumes (count tail-resumptive vs
   capturing sites across the prelude and demos; publish the table here).
2. **Evidence-passing interpreter** (~2-3 weeks): the tier-1/2 fast path inside
   the existing tree-walker — validates the tiering without a backend.
3. **Perceus over Value** (~3-4 weeks): RC headers, reuse analysis on the
   kernel, the let-rec carve-out, leak tests over the suite.
4. **Native backend** (~2-3 months): per-declaration codegen (LLVM or Cranelift),
   spec cache, store-keyed object files, the suite bit-identical gate — the
   same acceptance bar as PF.1's VM.

Each phase is independently shippable and independently abandonable; none
changes the language. The sketch is retained as history; the dated sections
below supersede items 2-4 (phase 2 measured and declined, phase 3 folded
into phase 4, backend decided as C emission).

## Phase 1 results (2026-07-05)

Phase 1 landed as the `jacquard tiers` command plus tier sidecars in the store
(derived data beside each object, keyed by member hash, excluded from identity
like all metadata; objects stay write-once). The checker records every
application's callee row and every handler clause's syntactic resume
discipline; `test/cli/tiers.t` pins the prelude table so drift is visible.

Sweep over the prelude, all demos (escrow included), and the valid/sigs corpus:

```
== declarations: 295 named terms ==
pure                 161  54%
row-poly              41  13%
effectful             58  19%
data                  35  11%

== call sites: 1107 applications ==
constructor          216  19%
op-perform           103   9%
fn pure              544  49%
fn row-poly           69   6%
fn effectful         175  15%

== handler op clauses: 37 ==
tail-resumptive        8  21%
aborting               8  21%
one-shot               3   8%
multi-shot            18  48%
```

Reproduce with:

```sh
jacquard tiers demos/*.jqd demos/escrow/workflow.jqd \
  demos/escrow/workflow-escalated.jqd demos/escrow/tests.jqd \
  demos/escrow/main.jqd corpus/valid/*.jqd corpus/sigs/*.jqd
```

What the numbers say about the design's assumptions:

- **Call-site pure dominance holds.** 68% of applications (constructors plus
  calls through arrows with closed empty rows) are host-stack eligible before
  monomorphization even starts, and most of the 6% row-polymorphic sites
  close to empty once specialized. Pillar 1's tier-0 case is the common case.
- **The effectful remainder is exception-shaped.** The per-effect breakdown of
  the 175 effectful calls is dominated by `check` (69) and `throw`/`abort`
  (67 combined). The `throw` and `abort` handlers classify as aborting —
  continuation dropped, no capture — and `check` is Warp's test-reporting
  effect, discharged in the test harness rather than on program hot paths.
  Genuinely capturing effects are a small tail.
- **Syntactic tail-resumptive dominance does NOT hold for the in-language
  handler library, and the reasons are instructive.** First, handlers such as
  `state.run` are written in state-passing style — `resume` escapes into a
  state-threading lambda, so the classifier (correctly) reports the
  continuation as escaping even though each state thread resumes once. Koka
  recovers exactly this case with parameterized handlers; phase 2 should
  include them if the state family is to ride the evidence-passing fast path.
  Second, much of the prelude's handler surface IS the simulation library
  (`fault.all`, scripted world handlers, enumeration), which is multi-shot by
  design and priced by branch count — those clauses sit in the priced tier no
  matter how they are written. Root grants, the handlers real programs
  discharge most effects with, are native and tail-resumptive by construction;
  they do not appear in the clause table at all.

The dominant-case assumption survives phase 1 in the form that matters (call
sites), with one design consequence recorded for phase 2: add parameterized
handlers to the evidence-passing plan, or accept that the state family stays
on the slow path.

## Phase 2 result (2026-07-05): measured and declined

The tier-0 direct path was built as an experiment and measured; the
measurement said decline, so the code was removed. docs/perf-vm-decision.md
has the numbers and the full record. The headline: the CPS machine already
visits AST nodes at ~16ns on pure recursion, so
eliminating frames and dispatch bought nothing — the interpreter's floor is
its representations (persistent-map environments, boxed values), which only
the later phases change. Consequences for this document: the interpreter-level
rungs are exhausted, remaining performance work is representation change
(pillars 2-4 together, on a native runtime), and two mechanics from the
experiment bind that design — fast-path fallback requires demotion of the
bailing closure, and direct host-stack execution requires a depth budget
because deep non-tail recursion plus allocation is quadratic under a
stack-scanning minor GC.

## Phase 3 decision (2026-07-05): Perceus folded into the native phase

Perceus over the interpreter's OCaml `Value` heap is declined without an
experiment; the case follows from the runtime's structure. RC on top of a
tracing host GC double-pays: OCaml reclaims every value regardless, so
headers and dup/drop insertion are purely additive overhead. The pillar's
actual win is in-place reuse, and reuse requires trusting a count of one —
but frames-as-data means a captured resumption shares its environments
across resumes, so every value reachable from a captured continuation must
be dup'd conservatively at capture time. That forfeits reuse in exactly the
handler-dense code this tree exists to run, and phase 2's measurement
already established that engine-level constant work inside the interpreter
does not ship wins of this cost. Perceus needs a runtime that owns its heap
and its continuation representation, so Pillar 2 executes as part of the
native backend, and two rules recorded here are design inputs to that
runtime — the let-rec cyclic carve-out (Pillar 2 above) and dup-on-capture
for anything a resumption can reach.

## Phase 4 status (2026-07-05, superseded same day): backend decided — C emission

The backend choice the phased sketch left open ("LLVM or Cranelift") is
taken: emit C, one compilation unit per declaration, keyed by content hash.
Koka ships this design's exact pillar stack — evidence passing plus Perceus —
through C emission, so the reference implementations translate directly;
emitting C gets the system compiler's optimizer without a libLLVM build
dependency, and nothing here needs the JIT-oriented codegen that is
Cranelift's niche; and one C unit per declaration keeps the store-keyed
object cache toolchain-plain. The known C risk is guaranteed tail calls — mitigation
order: clang/GCC `musttail` where available, self-tail-call loopification,
trampoline fallback. This section originally left the phase gated on the
standing trigger conditions in docs/perf-vm-decision.md; the owner overrode
the gate the same day — those triggers measure whether interpretation speed
hurts development, and the goal is a fast language, which is a different
question. The build is scheduled: docs/native-plan.md, tasks 65-76
(task 63 is superseded).
