# PF.1 decision document: bytecode VM — declined (for now)

Per the plan's guardrail — no performance work without a decision doc — this page
records the measurement, the decision, and the standing trigger. The task stays
open in the tracker as a monitored condition, not a commitment.

## The trigger, restated

Build the VM when interpretation speed changes developer behavior. Empirically:

- `dune runtest`'s Weft-eval-bound tests exceed ~2 minutes, or
- the stdlib property batteries become the suite's bottleneck, or
- a demo the README leans on is visibly sluggish.

## Measurements (2026-07-04, commit range 33c6a96..HEAD)

- Full suite: **308 tests in ~51 seconds**, of which the eval-bound share
  (stdlib/map/props/replay batteries, ~120 tests driving the CPS machine over
  the full prelude) is roughly half; the rest is checker, cram process spawns,
  and store IO.
- The heaviest single tests: the 500-sequence map model battery and the 10k-insert
  stack-safety pin, each ~2-3 seconds — n-log-n Weft over a tree-walker, entirely
  acceptable.
- The word-count demo over piped input is interactive-instant. The M3 posterior
  demos enumerate in milliseconds (branch counts in the tens).
- `fault.all` and exhaustive props are exponential BY DESIGN and budget-capped;
  a VM moves the budget's constant, not its shape.

Verdict against the trigger: **not close**. The suite is a factor of ~2.5 under
the threshold with the entire stdlib, Warp, and the property lanes landed —
i.e., the language's own development no longer adds eval-bound weight at the
rate the early milestones did.

## Decision

Declined at this time. Revisit when a trigger condition is observed in the
normal course of development; re-measure, update this doc, and only then scope
the build.

## Scope if triggered (pre-agreed, so the future discussion is short)

Flat bytecode over the EXISTING Value/frame model. The frames-as-data invariant
(multi-shot continuation slicing) is non-negotiable and rules out host-stack
tricks; the win is dispatch and allocation overhead — the Python/Elixir band,
an estimated ~2 weeks. Compilation is per-declaration at store-load (the content
hash is the natural code-cache key, same discipline as every other cache in the
tree). Acceptance bar if built: the full suite green under the VM with outputs
bit-identical to the tree-walker — including cram transcripts, LW seeds, and
posterior tables — plus a benchmark table in this doc.

## Update (2026-07-05): the ladder changed — VM rung skipped

Owner decision: when performance work starts, it takes the PF.2 phased route
(tier tagging, then the evidence-passing fast path inside the existing
tree-walker, then Perceus, then a native backend) rather than passing through
this document's bytecode VM. The reasoning: the evidence-passing phase costs
about the same as the VM, lands in a similar band for the code that dominates,
and validates the pillar the native route rests on, whereas the VM's dispatch
constant derisks nothing downstream and would leave a second engine to
maintain or discard. The "scope if triggered" section above is retained as
history, not as a plan. The trigger conditions still govern WHEN any of this
starts; the PF.2 phases are tracked as tasks 60-63.

## What we deliberately did NOT do meanwhile

No micro-optimization of the tree-walker (memo tables and the builtin
short-circuits already exist from M1/M2); no partial JIT experiments; no
"just this one hot path" special cases. The ladder is tree-walker → VM →
native (see docs/native-compilation.md), and skipping rungs quietly is how
interpreters grow unmaintainable middles.
