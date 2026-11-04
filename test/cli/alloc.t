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
  alloc: 706 of 100000 cell(s) used (alloc-v1)
  $ jacquard run chain.jac --alloc 100000 2> again.err > /dev/null; cat again.err
  alloc: 706 of 100000 cell(s) used (alloc-v1)

It completes at exactly its cost, and one cell less is incomplete.

  $ jacquard run chain.jac --alloc 706
  100
  alloc: 706 of 706 cell(s) used (alloc-v1)
  $ jacquard run chain.jac --alloc 705
  error[E0921]: The allocation budget was exhausted
    Cause: allocation budget exhausted: the alloc-v1 budget of 705 cell(s) ran out before evaluation finished; the result is incomplete
    Next step: Raise the --alloc budget, or omit it to run unbounded. An exhausted run is incomplete; it neither passes nor fails.
  alloc: 705 of 705 cell(s) used (alloc-v1)
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
  alloc: 85 of 1000 cell(s) used (alloc-v1)
  $ jacquard infer enumerate --alloc 10 ../../demos/inference/m3-two-coins.jac
  error[E0921]: The allocation budget was exhausted
    Cause: allocation budget exhausted: the alloc-v1 budget of 10 cell(s) ran out before evaluation finished; the result is incomplete
    Next step: Raise the --alloc budget, or omit it to run unbounded. An exhausted run is incomplete; it neither passes nor fails.
  alloc: 10 of 10 cell(s) used (alloc-v1)
  [2]
  $ jacquard infer lw --seed 1 --samples 50 --alloc 50 ../../demos/inference/m3-two-coins.jac > lw.out 2>&1 || echo "exit=$?"; head -1 < lw.out
  exit=2
  error[E0921]: The allocation budget was exhausted

`--max-frontier N` bounds an exact enumeration's pending entries: the support
entries not yet explored at every level of the search. Two nested coins leave
at most 3 pending (1 at the first level, 2 at the second):

  $ jacquard infer enumerate --max-frontier 3 ../../demos/inference/m3-two-coins.jac
  0.666667  true
  0.333333  false
  $ jacquard infer enumerate --max-frontier 2 ../../demos/inference/m3-two-coins.jac
  error[E0921]: A registry ceiling was reached
    Cause: registry ceiling reached: the --max-frontier ceiling of 2 pending enumeration entry(s) was reached before evaluation finished; the result is incomplete
    Next step: Raise the --max-frontier ceiling, or omit it to run unbounded. An incomplete run neither passes nor fails.
  [2]

`jacquard test --alloc CELLS` gives each discovered test its own allocation
budget, drawn from one run, as `--fuel` does: a test that runs out is
INCOMPLETE, is never cached, and makes the run exit 2; bounded results are
cached under the budget and never answer for an unbounded run or another
budget:

  $ cat > suite.jac <<'JAC'
  > grow(n) = { let _ = (n, n); grow(add(n, 1)) }
  > twice(n) = mul(n, 2)
  > quick-case =
  >   Case("quick", fn () -> check.eq(twice(3), 6, int.eq, int.show, "twice"))
  > grow-case =
  >   Case("grows", fn () -> check.eq(grow(0), 0, int.eq, int.show, "never"))
  > JAC
  $ timeout 60 jacquard test suite.jac --alloc 5000 --cache-dir bounded
  INCOMPLETE grow-case: allocation budget exhausted (alloc-v1, 5000 cell(s))
  PASS quick-case/quick (1 check)
  1 passed, 0 failed, 0 skipped, 0 refused, 1 incomplete
  cache: 0 hit, 1 ran
  [2]
  $ ls bounded | wc -l
  1
  $ timeout 60 jacquard test suite.jac --alloc 5000 --cache-dir bounded > pipe.out || echo "exit=$?"; tail -2 < pipe.out
  exit=2
  1 passed, 0 failed, 0 skipped, 0 refused, 1 incomplete
  cache: 1 hit, 0 ran
  $ timeout 60 jacquard test suite.jac --alloc 6000 --cache-dir bounded > pipe.out || echo "exit=$?"; tail -1 < pipe.out
  exit=2
  cache: 0 hit, 1 ran
  $ grep -v grow suite.jac > quick.jac
  $ jacquard test quick.jac --cache-dir bounded > pipe.out || echo "exit=$?"; tail -1 < pipe.out
  cache: 0 hit, 1 ran

A group keeps the verdicts its children finished before one ran out, and an
exhaustive property cannot turn running out into a failing verdict:

  $ cat > group.jac <<'JAC'
  > grow(n) = { let _ = (n, n); grow(add(n, 1)) }
  > suite-case = Group("suite", [
  >   Case("fails", fn () -> check.true(False, "no")),
  >   prop("grows", fn () -> check.eq(grow(sample(uniform-int(0, 1))), 0, int.eq, int.show, "never"))
  > ])
  > zz-after-case = Case("after", fn () -> check.true(True, "yes"))
  > JAC
  $ timeout 60 jacquard test group.jac --exhaustive --alloc 3000 --no-cache
  FAIL suite-case/suite/fails
    - no
  INCOMPLETE suite-case: allocation budget exhausted (alloc-v1, 3000 cell(s))
  PASS zz-after-case/after (1 check)
  1 passed, 1 failed, 0 skipped, 0 refused, 1 incomplete
  [1]

With both budgets, the one that runs out first is reported:

  $ timeout 60 jacquard test suite.jac --alloc 5000 --fuel 1000 --no-cache > both.out || echo "exit=$?"; head -1 < both.out
  exit=2
  INCOMPLETE grow-case: computation fuel exhausted (fuel-v1, 1000 unit(s))
  $ timeout 60 jacquard test suite.jac --alloc 5000 --fuel 100000 --no-cache > both.out || echo "exit=$?"; head -1 < both.out
  exit=2
  INCOMPLETE grow-case: allocation budget exhausted (alloc-v1, 5000 cell(s))

Registry ceilings (§4): `--max-tasks N` and `--max-channels N` bound what a
run retains at once, across every scope. A nested scope's body and each
spawned task count until the run's scopes are torn down; reaching a ceiling is
the incomplete outcome E0921, exit 2.

  $ cat > spawns.jac <<'JAC'
  > count(n) = if eq(n, 0) then 0 else {
  >   let t = async.spawn(fn () -> n)
  >   let v = match async.await(t) { | Done(v) -> v | _ -> 100 }
  >   add(v, count(sub(n, 1)))
  > }
  > 
  > async.scope(fn () -> count(3))
  > JAC
  $ jacquard run spawns.jac --max-tasks 4
  done(6)
  $ jacquard run spawns.jac --max-tasks 3
  error[E0921]: A registry ceiling was reached
    Cause: registry ceiling reached: the --max-tasks ceiling of 3 retained task(s) was reached before evaluation finished; the result is incomplete
    Next step: Raise the --max-tasks ceiling, or omit it to run unbounded. An incomplete run neither passes nor fails.
  [2]
  $ cat > opens.jac <<'JAC'
  > opens(n, size) = if eq(n, 0) then 0 else match channel.open(size) {
  >   | Err(_) -> 100
  >   | Ok(_) -> add(1, opens(sub(n, 1), size))
  > }
  > 
  > async.scope(fn () -> opens(2, 1000))
  > JAC
  $ jacquard run opens.jac --max-channels 2
  done(2)
  $ jacquard run opens.jac --max-channels 1
  error[E0921]: A registry ceiling was reached
    Cause: registry ceiling reached: the --max-channels ceiling of 1 open channel(s) was reached before evaluation finished; the result is incomplete
    Next step: Raise the --max-channels ceiling, or omit it to run unbounded. An incomplete run neither passes nor fails.
  [2]

A channel's buffer is paid for when it opens: its declared capacity, in cells.

  $ jacquard run opens.jac --alloc 3000
  done(2)
  alloc: 2017 of 3000 cell(s) used (alloc-v1)
  $ jacquard run opens.jac --alloc 1500
  error[E0921]: The allocation budget was exhausted
    Cause: allocation budget exhausted: the alloc-v1 budget of 1500 cell(s) ran out before evaluation finished; the result is incomplete
    Next step: Raise the --alloc budget, or omit it to run unbounded. An exhausted run is incomplete; it neither passes nor fails.
  alloc: 1500 of 1500 cell(s) used (alloc-v1)
  [2]
  $ jacquard run opens.jac --max-tasks=-1
  Usage: jacquard run [--help] [OPTION]… FILE
  jacquard: option '--max-tasks': expected a non-negative count
  [124]

A capacity near the largest Int is refused against the budget rather than
wrapping the count:

  $ sed 's/opens(2, 1000)/opens(2, 4611686018427387903)/' opens.jac > huge.jac
  $ jacquard run huge.jac --alloc 1500
  error[E0921]: The allocation budget was exhausted
    Cause: allocation budget exhausted: the alloc-v1 budget of 1500 cell(s) ran out before evaluation finished; the result is incomplete
    Next step: Raise the --alloc budget, or omit it to run unbounded. An exhausted run is incomplete; it neither passes nor fails.
  alloc: 1500 of 1500 cell(s) used (alloc-v1)
  [2]

`jacquard test` takes the ceilings per test, through the same scope as its
budgets: each test counts from zero, one that reaches a ceiling is INCOMPLETE
and never cached, and results are cached under each ceiling given:

  $ cat > spawning.jac <<'JAC'
  > count(n) = if eq(n, 0) then 0 else {
  >   let t = async.spawn(fn () -> n)
  >   let v = match async.await(t) { | Done(v) -> v | _ -> 100 }
  >   add(v, count(sub(n, 1)))
  > }
  > summed() = match async.scope(fn () -> count(3)) { | Done(v) -> v | _ -> 100 }
  > again-case = Case("again", fn () -> check.eq(summed(), 6, int.eq, int.show, "sum"))
  > spawn-case = Case("spawns", fn () -> check.eq(summed(), 6, int.eq, int.show, "sum"))
  > JAC
  $ timeout 60 jacquard test spawning.jac --max-tasks 4 --cache-dir ceilings
  PASS again-case/again (1 check)
  PASS spawn-case/spawns (1 check)
  2 passed, 0 failed, 0 skipped, 0 refused, 0 incomplete
  cache: 0 hit, 2 ran
  $ timeout 60 jacquard test spawning.jac --max-tasks 3 --cache-dir ceilings
  INCOMPLETE again-case: registry ceiling reached (--max-tasks, 3 retained task(s))
  INCOMPLETE spawn-case: registry ceiling reached (--max-tasks, 3 retained task(s))
  0 passed, 0 failed, 0 skipped, 0 refused, 2 incomplete
  cache: 0 hit, 0 ran
  [2]
  $ timeout 60 jacquard test spawning.jac --max-tasks 4 --cache-dir ceilings | tail -1
  cache: 2 hit, 0 ran
  $ timeout 60 jacquard test spawning.jac --max-tasks 4 --max-frontier 9 --cache-dir ceilings | tail -1
  cache: 0 hit, 2 ran
  $ timeout 60 jacquard test spawning.jac --cache-dir ceilings | tail -1
  cache: 0 hit, 2 ran
