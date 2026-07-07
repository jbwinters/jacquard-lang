# Benchmarks: the native tier, measured

This is the living benchmark record for `jacquard build`. The design
doc (docs/native-compilation.md) states the claim boundary and keeps
the historical progression; this report holds the current numbers, the
cross-language and cross-toolchain columns, what each scenario
exercises, and how to reproduce all of it. Numbers below are one
measurement session (2026-07-06 EDT, AMD Ryzen 9 7950X3D, Ubuntu,
clang 18.1.3, gcc 13.3, Python 3.11.6).

## Method

- Median of 5 wall-clock runs per cell, per-engine startup subtracted
  (a `(lit 0)` program's median for the interpreter and each native
  toolchain; `python3 -c pass` for Python). The hand-C column is raw —
  its ~1 ms process launch is not subtracted, so native-vs-C ratios
  read conservatively.
- The box is shared and carries real jitter: across sessions the C
  canaries range fib 2-3 ms and sort 24-31 ms, and every ratio moves
  with them. Treat single-digit cells as ±1-2 ms and treat ratios as
  bands. When a run looks off, check the canaries first.
- Reference programs practice the same heap discipline as the programs
  they shadow: the sort and sum references build and walk malloc'd
  nodes rather than using flat arrays; the text reference copies the
  whole accumulated string per append, as an immutable concat must.
  The Python twins do the same (heap-node merge sort, a genuinely
  quadratic concat loop, a materialized list under the fold). Where a
  reference is cheaper than an exact twin could be, the lean is always
  in the reference's favor — sum.c never frees its nodes, text.c
  renders pieces on the stack and counts commas instead of allocating
  the split, and both sort references relink nodes where the prelude's
  merge conses fresh cells — so the published native-vs-C ratios read
  conservatively against Jacquard.
- Native builds use the default flags (`-O2 -flto`, task 84). The
  interpreter is `jacquard run` on the same store.

## Scenarios

| program | shape | what it measures |
| --- | --- | --- |
| fib | naive fib(30), two-way recursion | call overhead: the recursion cannot loopify, so every node pays the calling convention and the RC prologue |
| sort | merge sort, 200k heap nodes at int.ord | allocation and RC traffic on field reads, plus the monomorphized comparator (tasks 69/80/85) |
| sum | fold over a 1M-element built list | the higher-order path: list.range materialization plus a lambda-literal fold (task 86 devirtualizes it) |
| text | 10k ints comma-joined by folded concat, split back | the TEXT path: quadratic immutable concat, from-int rendering, split |
| pure | mixed arithmetic/list battery | the empty-row core in aggregate |
| avl | 10k map.set | in-place reuse on the rebuilt spine (Perceus reuse tokens) |
| state-loop | 1M get/put pairs through a handler | the tail-resumptive effect tier — the OCaml/Koka band the design doc targets |
| enum | 2^14 multi-shot branches | continuation cloning, priced per branch by design |
| mutate | 300 rounds of single-edit mutant generation over a quoted AST | code values (task 73): form construction, un-form/form traffic, structural equality over quote statics |

Two kinds of twin live in bench/ref/. fib, sort, sum, and text have
DISCIPLINE-MATCHED twins: C and Python doing the same work the same
way (heap nodes, quadratic copies), so their columns compare
implementations of one program. state-loop and mutate have no such
twin — C and Python have neither effect handlers nor quoted code
values — so their twins are TASK-EQUIVALENT: the same job done with
each language's native mechanism (get/put as noinline accessor calls
in C and method calls in Python; the mutant algorithm over tagged
structs and native tuples), which prices the abstraction rather than
the implementation. pure is an aggregate battery, avl would need a
persistent AVL written out in each language to compare anything real,
and enum's mechanism is the thing being priced (a C loop over 2^14
bitstrings measures a different semantics entirely); those three stay
engines-only.

## The table

| program | interpreter | native (clang) | native (gcc 13) | Python 3.11 | hand C | native vs C |
| --- | --- | --- | --- | --- | --- | --- |
| fib | 726 ms | 4 ms | 8 ms | 71 ms | 3 ms | 1.3x |
| sort | 67728 ms | 96 ms | 151 ms | 262 ms | 25 ms | 3.8x |
| sum | 13922 ms | 54 ms | 71 ms | 62 ms | 23 ms | 2.3x |
| text | 182 ms | 10 ms | 10 ms | 10 ms | 5 ms | 2.0x |
| pure | 3303 ms | 12 ms | — | — | — | — |
| avl | 6442 ms | 14 ms | — | — | — | — |
| state-loop | 24181 ms | 159 ms | 211 ms | 76 ms | 3 ms | 53x† |
| enum | 10698 ms | 14 ms | 22 ms | — | — | — |
| mutate | 2558 ms | 4 ms | 5 ms | 9 ms | 2 ms | 2.0x† |

† task-equivalent ratio: the C twin uses its native mechanism (accessor
calls, arena-allocated structs), not the same discipline — it prices
the abstraction, not the implementation.

Readings, program by program:

- **fib** at 1.3x hand C this session; cross-session readings span
  1.3-2.5x (the design doc's current cells read 1.7x) because both
  sides are single-digit milliseconds and this cell moves the most
  with box noise. Native is ~18x Python. What remains is the CON-based
  boolean match and tagged-int arithmetic; the calling convention is
  already collapsed by LTO (task 79's record).
- **sort** at 3.8x hand C is the outlier that keeps the near-C claim
  withdrawn (the gate is BOTH fib and sort within 3x). The residue is
  RC traffic on field reads. Native beats Python by ~2.7x on the same
  node discipline.
- **sum** at 2.3x hand C and ahead of Python. The task-86
  lambda-literal specialization is what makes this row: the fold is a
  direct call in a Perceus-precise clone rather than 1M generic
  applies. The Python twin materializes its list too; a `reduce` over
  a bare `range` runs ~1.4x faster and the `sum()` builtin ~6x — both
  measure different programs than the one Jacquard pays for.
- **text** at 2.0x hand C and even with Python: all three engines
  spend this benchmark in memcpy, as quadratic immutable concat
  should. The interpreter is only 18x slower here for the same reason.
- **state-loop**'s task-equivalent columns price the effect
  abstraction: the same million get/put pairs cost 3 ms as noinline C
  accessor calls, 76 ms as Python method calls, and 159 ms through the
  native handler tier. A handled operation costs about twice a Python
  method call today — consistent with the design doc's claim that this
  tier targets the OCaml/Koka band, not C — and the interpreter's
  24 s shows what the native tier already removed.
- **mutate** runs at ~640x the interpreter, in the suite's top band
  alongside enum (~760x) and sort (~700x): the native quote statics
  make mutant generation almost free, while the tree-walker pays full
  price per form node. The task-equivalent twins run the same
  algorithm over tagged C structs (2 ms, arena-allocated spines) and
  native Python tuples (9 ms) — native code values sit between them
  at 4 ms, ahead of the Python data structures they would replace.
- **The gcc column** runs the same emitted C through gcc 13's LTO with
  the task-83 trampoline in place of musttail: fib 2x clang, sort
  ~1.6x, text identical. Correctness is toolchain-independent (the
  differential harness runs both); performance is a clang-first story.

## Progression (the perf arc, for the record)

Milestones by bench, in ms (task 75 first measurement → LTO default
(84) → small-block pool (80) → header-inlined RC (85) → Perceus over
frames (82)): fib 19 → 8 → 8 → 5 → 5; sort 279 → 189 → 118 → 97 → 92;
pure 37 → 29-22 → 13 → 11 → 11; avl 33 → 24 → 22 → 14 → 13;
state-loop 250 → 203 → 190 → 172 → 147; enum 40 → 35 → 25 → 15 → 15.
Two levers were implemented, measured as non-wins, and declined with
records: intrinsic borrowing (task 81) and arity-exact signatures
(task 79). The task-master records carry the full reasoning.

## Reproducing

```bash
export JACQUARD_PRELUDE=$PWD/prelude JACQUARD_RUNTIME=$PWD/runtime
sh scripts/native-bench.sh            # interpreter / native / hand C
CC=gcc sh scripts/native-bench.sh     # the gcc column (native cells only)
python3 bench/ref/fib.py              # Python twins: fib, sort, sum,
                                      #   text, state-loop, mutate
```

Each Python cell is median-of-5 minus the `python3 -c pass` baseline.
Every bench/*.jqd file also runs inside the differential harness
(scripts/native-diff.sh), so the two engines' outputs are byte-checked
on every CI push — the numbers here are only ever about speed, never
about which answer is right.
