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

Forks never receive a copied or fresh allowance. The counter lives on the
evaluator, not on a continuation, so the only way to spend fuel is to run a
transition, and every transition debits the one shared budget. fuel-v1 has no
per-branch limits. A driver that adds per-branch caps later must still draw on
the aggregate, so a cap only lowers what one branch may spend.

An invocation without `fuel` is unbounded and behaves as before. The CLI keeps
that default: `jacquard run`, `jacquard infer enumerate` and
`jacquard infer lw` are bounded only when `--fuel UNITS` is given. A budget is
a non-negative integer, and zero refuses the first transition.

## 2. The fuel-v1 cost model

Every debit is made before the work it pays for:

| work | units |
|---|---|
| one evaluator machine state visited, the final (terminal) state included | 1 |
| performing an operation | 1 per continuation frame walked to its handler, or to the root |
| resuming a continuation (Multi or Once) | 1 per captured frame reinstalled, including resumptions a driver (inference, the scheduler, a host worker) makes outside the machine |
| a native builtin or granted root handler | `text bytes / 64` over its direct arguments, then again over its result |
| a deep native (`debug.inspect`, `code.render`, `code.hash`, `code.eq?`, `code.diff`, `pmf`) | first, `expanded nodes and bytes / 64` over its arguments |
| an inference driver reaching a branch's or sample's final value | `expanded nodes and bytes / 64` of that value, before the driver keys it by its rendering |
| reaching a memoized top-level term | the cost of the sub-run that computed it, once per invocation (§3) |

The ordinary native measure counts only the text a native directly receives or
returns; it does not look inside tuples, constructors or code, so measuring is
constant work per value. A native that walks a whole value or code form is
different: sharing can make the expanded structure exponentially larger than
what building it cost, and the walk does work in proportion to the expanded
size. Such a native is marked deep and pays for the expanded size before it
runs. The measurement stops as soon as it passes the remaining allowance, so a
huge shared value exhausts the budget quickly instead of being walked. Integer
division rounds down, and each charge is computed separately.

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

- The sub-run's cost is recorded as its own transitions plus the memoized terms
  it reached, whether or not they were charged at the time.
- A hit charges the term's own cost plus every recorded dependency not yet
  charged in this invocation, then marks them all charged.

The fuel an invocation spends is the same on a fresh evaluator as after any
earlier invocation warmed the memo, in any order.

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
  so exhaustion arrives through a run's result. The one exception is a deep
  native, which never walks past the allowance: it fails with E0919 in place
  of running, as any native failure would. A native that caught exhaustion from a nested run cannot
  replace it with its own result or error.
- Root effects that ran before exhaustion are not retried or undone.
  Invocation teardown runs exactly once as usual.

Because the model is deterministic, the same program, inputs, seed, schedule
and budget always stop at the same transition. An exhausted run reports its
whole budget as used.

## 5. Evidence

With `--fuel`, the CLI prints one line to stderr when the invocation ends,
whether it finished or ran out:

```text
fuel: 112 of 112 unit(s) used (fuel-v1)
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
- The ordinary native measure is shallow by design (§2). A new prelude native
  that walks whole values must be marked deep, and a driver that renders or
  keys whole values must call `Eval.charge_walk` first. A host-registered
  native (`Eval.register_builtin`) cannot be marked deep; the host owns its
  cost.
- A native's result is paid for after it is built. The result is bounded by
  the native's inputs, so the overshoot is bounded, but a single native call
  can build a result larger than the remaining allowance before exhaustion.
- A few natives do superlinear work in their charged size: `code.diff`
  compares subforms at every level (quadratic in form size), and `support` on a
  `UniformInt` materializes up to its 10,000-entry cap for a small charge.
- Measuring deep natives and driver walks runs in unbounded mode too, since
  memoized costs must not depend on whether a budget is present. The walk
  roughly doubles the work of those natives; ordinary transitions cost a
  counter update.
- Rendering outside the evaluator is not fuel: the CLI printing a final value,
  and a diagnostic that shows a value (a match failure, or a native's type
  error on an ill-typed call), happen outside the budget.
