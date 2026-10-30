Logical allocation limits (RT.2): `jacquard run --alloc CELLS` bounds a run's
alloc-v1 allocation; running out is the incomplete outcome E0921, exit 2
(docs/designs/allocation-limits.md).

  $ export JACQUARD_PRELUDE=$PWD/../../prelude
  $ cat > chain.jac <<'JAC'
  > type Chain = End | Link Int Chain
  > build(n) = if eq(n, 0) then End else Link(n, build(sub(n, 1)))
  > size(xs) = match xs { | End -> 0 | Link(_, rest) -> add(1, size(rest)) }
  > size(build(100))
  > JAC

A bounded run reports the cells it used; the count is the same on every run.

  $ jacquard run chain.jac --alloc 100000
  100
  alloc: 605 of 100000 cell(s) used (alloc-v1)
  $ jacquard run chain.jac --alloc 100000 2> again.err > /dev/null; cat again.err
  alloc: 605 of 100000 cell(s) used (alloc-v1)

It completes at exactly its cost, and one cell less is incomplete.

  $ jacquard run chain.jac --alloc 605
  100
  alloc: 605 of 605 cell(s) used (alloc-v1)
  $ jacquard run chain.jac --alloc 604
  error[E0921]: The allocation budget was exhausted
    Cause: allocation budget exhausted: the alloc-v1 budget of 604 cell(s) ran out before evaluation finished; the result is incomplete
    Next step: Raise the --alloc budget, or omit it to run unbounded. An exhausted run is incomplete; it neither passes nor fails.
  alloc: 604 of 604 cell(s) used (alloc-v1)
  [2]

Without `--alloc` nothing changes; with both budgets, the one that runs out
first is reported.

  $ jacquard run chain.jac
  100
  $ jacquard run chain.jac --alloc 100000 --fuel 10
  error[E0919]: Computation fuel was exhausted
    Cause: computation fuel exhausted: the fuel-v1 budget of 10 unit(s) ran out before evaluation finished; the result is incomplete
    Next step: Raise the --fuel budget, or omit it to run unbounded. An exhausted run is incomplete; it neither passes nor fails.
  alloc: 1 of 100000 cell(s) used (alloc-v1)
  fuel: 10 of 10 unit(s) used (fuel-v1)
  [2]
  $ jacquard run chain.jac --alloc=-1
  Usage: jacquard run [--help] [OPTION]… FILE
  jacquard: option '--alloc': expected a non-negative number of cells
  [124]

A memoized term's first evaluation is bounded as it runs: an initializer that
allocates forever stops at the budget.

  $ cat > forever.jac <<'JAC'
  > type Chain = End | Link Int Chain
  > big = { let rec g(xs) = g(Link(1, xs)); g(End) }
  > big
  > JAC
  $ timeout 20 jacquard run forever.jac --alloc 10
  error[E0921]: The allocation budget was exhausted
    Cause: allocation budget exhausted: the alloc-v1 budget of 10 cell(s) ran out before evaluation finished; the result is incomplete
    Next step: Raise the --alloc budget, or omit it to run unbounded. An exhausted run is incomplete; it neither passes nor fails.
  alloc: 10 of 10 cell(s) used (alloc-v1)
  [2]

Every driver honours the budget the same way. Every scheduled task shares the
invocation's allocation, and a growing child stops the whole run:

  $ cat > tasks.jac <<'JAC'
  > grow(n) = { let _ = (n, n); grow(add(n, 1)) }
  > 
  > async.scope(fn () -> {
  >   let _ = async.spawn(fn () -> grow(0))
  >   let quick = async.spawn(fn () -> 7)
  >   async.await(quick)
  > })
  > JAC
  $ timeout 20 jacquard run --alloc 5000 tasks.jac > tasks.out 2>&1 || echo "exit=$?"; head -1 < tasks.out
  exit=2
  error[E0921]: The allocation budget was exhausted

Exact enumeration and likelihood weighting draw on one budget across every
branch or run; running out is E0921, not a model failure (E0902):

  $ jacquard infer enumerate --alloc 1000 ../../demos/inference/m3-two-coins.jac
  0.666667  true
  0.333333  false
  alloc: 47 of 1000 cell(s) used (alloc-v1)
  $ jacquard infer enumerate --alloc 10 ../../demos/inference/m3-two-coins.jac
  error[E0921]: The allocation budget was exhausted
    Cause: allocation budget exhausted: the alloc-v1 budget of 10 cell(s) ran out before evaluation finished; the result is incomplete
    Next step: Raise the --alloc budget, or omit it to run unbounded. An exhausted run is incomplete; it neither passes nor fails.
  alloc: 10 of 10 cell(s) used (alloc-v1)
  [2]
  $ jacquard infer lw --seed 1 --samples 50 --alloc 50 ../../demos/inference/m3-two-coins.jac > lw.out 2>&1 || echo "exit=$?"; head -1 < lw.out
  exit=2
  error[E0921]: The allocation budget was exhausted
