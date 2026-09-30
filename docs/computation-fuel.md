# Computation fuel (RT.1)

- Status: implemented contract for the `fuel-v1` cost model.
- Scope: the interpreter (`Eval`) and every driver that evaluates through it.
  Native compilation has no fuel accounting; see §7.

A Jacquard program with no effects can still run forever, and multi-shot
handlers, inference and the scheduler can multiply finite work without limit.
Computation fuel bounds all of it with one deterministic, reproducible budget
per invocation. Running out is an explicit *incomplete* outcome. It is never
a pass, a failure of the program, or a completed search.

## 1. Budget and owner

A budget belongs to one invocation (`Eval.with_invocation ~fuel:n`, RF.2).
Everything evaluated on that evaluator while the invocation is active draws
on the same allowance:

- nested runs, including the isolated sub-run that computes a top-level term;
- evaluator re-entry from native builtins and root handlers;
- every resumption of a multi-shot continuation, and every branch or sample
  of an inference driver;
- every task of a scheduled run.

Forks never receive a copied or fresh allowance. The counter is one
process-wide meter, not state on a continuation, so every transition and every
metered walk (§2) debits the one shared budget. The drivers
impose no per-branch limits of their own. A nested invocation's own budget acts
as a per-branch cap (§4); like any future driver cap, it still draws on the
aggregate, so a cap only lowers what one branch may spend.

An invocation without `fuel` is unbounded and behaves as before. The CLI keeps
that default: `jacquard run`, `jacquard infer enumerate` and
`jacquard infer lw` are bounded only when `--fuel UNITS` is given. A budget is
a non-negative integer, and zero refuses the first transition.

## 2. The fuel-v1 cost model

Fuel is counted by one process-wide meter (`Fuel_meter`) in fine units, 64 to
a fuel unit, so byte-sized work is charged exactly. Every debit is made before
the work it pays for, except that a walk is charged as it proceeds:

| work | units |
|---|---|
| one evaluator machine state visited, the final (terminal) state included | 1 |
| performing an operation | 1 per continuation frame between the operation and its handler (the handler's own frame is not counted), or every frame when it reaches the root |
| resuming a continuation (Multi or Once) | 1 per captured frame reinstalled, including resumptions a driver (inference, the scheduler, a host worker) makes outside the machine |
| a native builtin or granted root handler | 1/64 per text byte of its direct arguments, then of its result |
| rendering, printing or comparing a value or code form, anywhere in the invocation | 1/64 per node, scalar, and text, symbol, head or constructor-name byte walked |
| reaching a memoized top-level term | the cost of the sub-run that computed it, once per invocation (§3) |

Pattern matching is paid by the transitions that perform it (a pattern's size
is fixed by the program text); matching a text literal also pays for its bytes.
The native measure counts only the text a native directly receives or returns;
it does not look inside tuples, constructors or code, so measuring is constant
work per value. Walking a whole value is different: sharing can make the
expanded structure exponentially larger than what building it cost. So value
rendering (`Value.show`), code printing and form comparison tick the meter per
node and text byte wherever they run: in a native such as `debug.inspect`,
`code.render`, `code.eq?` or `pmf`; in the evaluator splicing a quote,
stamping its scope marks, converting code to kernel syntax, or building a
diagnostic; in the type checker unifying, instantiating, joining, cloning, rendering (for a
diagnostic), or walking types (the
run's own top-level expressions, and code passed to `eval`, whose types
let-polymorphism can make doubly exponential in size); or in a driver keying inference results, comparing
observed values, or rendering task results. A walk stops the
moment it passes the budget, so a huge shared value exhausts the budget
instead of being walked, and a comparison that stops at the first node stays
cheap. The units an invocation reports are its fine units rounded up, so a run
completes under exactly the budget reported as its cost.

Scheduling decisions, schedule traces, support sizes, wall-clock time, memory
and grants are not fuel. They keep their own bounds: `--max-decisions`,
`--max-branches`, deadlines, memory ceilings (RT.2), and the grant set. The
budget never replaces one of them, and none of them spends fuel.

`Eval.fuel_model` names the model. Any change to what a unit pays for is a new
name (`fuel-v2`, ...), never a silent reinterpretation of an old budget.

## 3. Memoized terms

A top-level term is computed once per evaluator and memoized; later
invocations reuse the value. If the cost of an invocation depended on that
warmth, the same program and budget could complete in one process and exhaust
in another. fuel-v1 therefore charges a memoized term the first time each
invocation reaches it, whether the value was computed now or earlier:

- The sub-run's charges are recorded in order: its own work between memoized
  terms, each memoized term it reached (whether or not it was charged at the
  time), and its trailing work.
- A hit replays that sequence, replaying each memoized term not yet charged in
  this invocation, and marks each term charged when its replay completes. A
  refusal part-way (for example under a nested cap) therefore leaves exactly the
  terms charged that a cold run would have finished.
- A sub-run or replay that fails part-way hands the terms it did complete to
  the enclosing term's record, so a term that survives a failed attempt inside
  it still names what that attempt paid for.

The fuel an invocation spends is the same on a fresh evaluator as after any
earlier invocation warmed the memo, in any order, with one exception: a
memoized term whose computation opens a nested invocation with its own budget
(§4). How far such a capped attempt gets depends on what the invocation had
already paid for, and a record cannot replay that cap, so its replayed cost can
differ from a fresh computation. Only host code can open a nested invocation;
the language and the prelude cannot. Charging follows the active invocation, not
the evaluator: each outermost invocation runs in a fresh epoch, and a native
that re-enters another evaluator, with or without starting a nested invocation
there, charges that evaluator's memoized terms within the same epoch, recording
them as dependencies of any memo sub-run in progress.

## 4. Exhaustion

A debit that would pass the budget is refused. Because the terminal state also
costs a unit, a run that has exhausted its budget cannot deliver a value. The invocation becomes
exhausted and evaluation stops with `Runtime_err.Fuel_exhausted`, rendered as
E0919, and the refused debit spends the remaining allowance. Exhaustion is
sticky: every later transition, and every attempt to return a value, in the
same invocation fails with the same error. A native that caught the error, a
scheduler policy that collects task failures, or an inference driver that
skips a failed branch therefore cannot turn exhaustion into a value.

- The scheduler stops the whole run on exhaustion. It never records exhaustion
  as one task's failure that a sibling or a Collect policy could absorb.
- Drivers recognise exhaustion by the invocation's sticky state, or by the E0919
  code when a native or nested driver wrapped the error, never by one error
  constructor alone.
- Inference reports E0919 instead of a model runtime failure (E0902, E0915) or
  an invalid distribution (E0911). It is distinct from the terminal-path budget
  (E0918): no partial posterior is returned.
- A driver working outside any run (resuming a captured continuation, applying
  a value) does not raise exhaustion from a refused debit. The invocation
  becomes exhausted at once, and the refusal is raised as the next run starts,
  so exhaustion arrives through a run's result. A native or an
  operation a driver applies (`Eval.apply_state`, `Eval.call`) is never applied
  outside a run: the driver gets a state whose first step applies it. The
  scheduler's routed root dispatch checks exhaustion and charges its arguments
  before the handler runs. A native that caught exhaustion from a nested run cannot
  replace it with its own result or error. A native that returns E0919 (for
  example from a nested invocation with its own smaller budget) leaves its work
  incomplete, so the enclosing invocation becomes exhausted too.
- A nested invocation with its own smaller budget is a per-branch cap: running
  out of it is that invocation's outcome, and the enclosing invocation keeps
  its remaining allowance. A caller that receives that E0919 and returns it
  makes the enclosing invocation exhausted (above). A host-registered native
  that instead discards it and returns a value owns that choice (§7); no
  prelude native opens a nested invocation.
- A walk that runs out raises `Fuel_meter.Exceeded`. A run turns it into E0919;
  the scheduler and the inference drivers return E0919 for a walk of their
  own; and the CLI reports an escaped one as E0919 rather than as an internal
  error.
- Root effects that ran before exhaustion are not retried or undone.
  Invocation teardown runs exactly once as usual.

Because the model is deterministic, the same program, inputs, seed, schedule
and budget always stop at the same transition. An exhausted run reports its
whole budget as used.

## 5. Evidence

With `--fuel`, the CLI prints one line to stderr when the invocation ends,
whether it finished or ran out:

```text
fuel: 113 of 113 unit(s) used (fuel-v1)
```

The line always names the model, so budgets are never compared across models.
A cache or replay artifact whose validity depends on a budget must key on
`(fuel_model, budget)`. It must also refuse to record an exhausted outcome as a
verdict (RT.1's exploration slice applies this to the test cache and the
exploration commands). A schedule trace does not record the budget. Fuel is
not a scheduling input: a bounded run that completes makes exactly the
decisions of an unbounded one, and an exhausted run records no trace.

## 6. Bounded surfaces

Existing commands stay unbounded unless `--fuel` is given. A newly advertised
surface that promises bounded execution to a host or an application must
require a budget rather than defaulting to unbounded. This includes exploration
commands, hosted process lifecycle limits (Host 10) and future embedding
entry points. A host consumer bounds an invocation with
`Eval.with_invocation ~fuel`.

## 7. Limits

- Native compilation (`jacquard native`) does not count fuel. A bounded
  execution must use the interpreter.
- fuel-v1 bounds computation, not allocation: a bounded run can still allocate
  a large value within its budget. Allocation limits are RT.2.
- The native measure is shallow by design (§2). A native that walks values
  itself, without the shared walkers, must tick `Fuel_meter` as it goes. A
  host-registered native (`Eval.register_builtin`) owns its own cost beyond the
  measure.
- A native's result is paid for after it is built. A native whose result can
  be much larger than its measured arguments pays as it builds (`text.join-list`
  pays for the joined bytes first), so one call overshoots the budget by at most
  about its own measured size.
- A few natives do superlinear work in their charged size, bounded by a
  polynomial in the budget: `code.diff` compares subforms at every level (each
  comparison is charged), `text.contains?` and `text.split` search naively
  (quadratic in the text), and `support` on a `UniformInt` materializes up to
  its 10,000-entry cap for a small charge.
- Accounting also runs in unbounded mode, since memoized costs must not depend
  on whether a budget is present; it adds a counter update per transition and
  per walked node, and nothing asymptotic.
- Store and identity work (writing declarations and the names index, loading
  stored declarations, canonical hashing, and writing `--infer-cache` entries)
  is not program computation and is never metered, so a cold and
  a warm lookup cost the same.
- The evaluator's guard scans (recovery-marker and mutable-graph validation at
  run entries and native or operation boundaries) are not metered: they are
  backed by evaluator-lifetime caches, so metering them would make a reused
  evaluator's cost differ from a fresh one's. Each scan visits every shared
  value or subform once, so it is linear in data the program already paid to
  build, and total work stays polynomial in the budget. For code values the scan
  repeats at every native or operation boundary, so a program that passes a
  large code value across many boundaries can spend far more time per fuel
  unit than ordinary evaluation. A granted operation or
  host-registered native snapshots the data its continuation reaches on every
  call, uncharged.
- Rendering a finished result is outside the budget: the CLI prints final
  values and posteriors unmetered. The scheduler, however, renders every task's
  result (the root task's included) into its trace while the run is in progress,
  and that rendering is metered, so a run whose final value is an exponentially
  shared structure ends with E0919. Walks during the invocation, including a
  diagnostic that shows a value, are metered: a huge ill-typed argument can
  exhaust the budget before its type error is rendered.
- Memo-warmth independence (§3) does not extend to a memoized term whose
  computation opens a nested invocation with its own budget; a host that does
  this owns the resulting variation, as it owns a native that discards the
  nested E0919.
- The meter is process-wide. Walks that happen while a bounded invocation is
  active draw on its budget whichever evaluator they belong to. An invocation
  nested on another evaluator stays within the outer ceiling, and if it uses
  the outer allowance up, the outer invocation stays exhausted after the inner
  one ends.
