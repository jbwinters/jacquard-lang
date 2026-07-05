# PF.2: native compilation for Jacquard — a design document

Status: design only; no compiler code exists or is scheduled. This document
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
dictionary record never exists at runtime.

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
changes the language.

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
