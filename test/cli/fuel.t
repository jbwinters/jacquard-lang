Computation fuel (RT.1). `--fuel UNITS` bounds a whole run to a fuel-v1
budget; running out is E0919, an incomplete run rather than a pass or a
failure. Without `--fuel` a run is unbounded, exactly as before. See
docs/computation-fuel.md.

  $ export JACQUARD_PRELUDE=../../prelude

A pure loop performs no effect, yet it stops at a reproducible boundary:

  $ cat > spin.jac <<'J'
  > spin(n) = spin(add(n, 1))
  > 
  > print("before\n")
  > spin(0)
  > J
  $ jacquard run --allow console --fuel 2000 spin.jac
  before
  ()
  error[E0919]: Computation fuel was exhausted
    Cause: computation fuel exhausted: the fuel-v1 budget of 2000 unit(s) ran out before evaluation finished; the result is incomplete
    Next step: Raise the --fuel budget, or omit it to run unbounded. An exhausted run is incomplete; it neither passes nor fails.
  fuel: 2000 of 2000 unit(s) used (fuel-v1)
  [2]

A finite program completes at exactly its cost and not one unit below it:

  $ jacquard run --fuel 113 ../../demos/basics/surface-fact.jac
  120
  fuel: 113 of 113 unit(s) used (fuel-v1)
  $ jacquard run --fuel 112 ../../demos/basics/surface-fact.jac 2>&1 | head -1
  error[E0919]: Computation fuel was exhausted
  $ jacquard run ../../demos/basics/surface-fact.jac
  120

Every scheduled task shares the invocation's budget. A spinning child does not
become one failed task that the scope could absorb; the whole run stops:

  $ cat > tasks.jac <<'J'
  > spin(n) = spin(add(n, 1))
  > 
  > async.scope(fn () -> {
  >   let _ = async.spawn(fn () -> spin(0))
  >   let quick = async.spawn(fn () -> 7)
  >   async.await(quick)
  > })
  > J
  $ jacquard run --fuel 5000 tasks.jac 2>&1 | head -1
  error[E0919]: Computation fuel was exhausted

Exhaustion can land anywhere in a scheduled run, including while the scheduler
resumes a task that yielded. Every budget below the program's cost (214) is E0919
with exit 2; none crashes or reports a task failure:

  $ cat > yield.jac <<'J'
  > work(n) = if eq(n, 0) then 0 else { async.yield(); work(sub(n, 1)) }
  > 
  > async.scope(fn () -> {
  >   let a = async.spawn(fn () -> work(3))
  >   let b = async.spawn(fn () -> work(2))
  >   (async.await(a), async.await(b))
  > })
  > J
  $ jacquard run yield.jac
  done((done(0), done(0)))
  $ n=0; while [ $n -lt 214 ]; do
  >   jacquard run --fuel $n yield.jac > out.txt 2>&1; code=$?
  >   if [ $code -ne 2 ] || ! grep -q 'error\[E0919\]' out.txt; then echo "budget $n: exit $code"; fi
  >   n=$((n + 1))
  > done
  $ jacquard run --fuel 214 yield.jac
  done((done(0), done(0)))
  fuel: 214 of 214 unit(s) used (fuel-v1)

Every branch of an exact enumeration draws on the same budget, and running
out is E0919, not a model runtime failure (E0902) or the terminal-path budget
(E0918):

  $ jacquard infer enumerate --fuel 1000 ../../demos/inference/m3-two-coins.jac
  0.666667  true
  0.333333  false
  fuel: 155 of 1000 unit(s) used (fuel-v1)
  $ jacquard infer enumerate --fuel 154 ../../demos/inference/m3-two-coins.jac
  error[E0919]: Computation fuel was exhausted
    Cause: computation fuel exhausted: the fuel-v1 budget of 154 unit(s) ran out before evaluation finished; the result is incomplete
    Next step: Raise the --fuel budget, or omit it to run unbounded. An exhausted run is incomplete; it neither passes nor fails.
  fuel: 154 of 154 unit(s) used (fuel-v1)
  [1]

Type checking draws on the budget too. Let-polymorphism can make the types of
a few lines of code doubly exponential in size; checking code passed to `eval`
stops at the budget instead of running for minutes:

  $ cat > types.jac <<'J'
  > plan = quote {
  >   {
  >     let f0 = fn (x) -> (x, x)
  >     let f1 = fn (y) -> f0(f0(y))
  >     let f2 = fn (y) -> f1(f1(y))
  >     let f3 = fn (y) -> f2(f2(y))
  >     let f4 = fn (y) -> f3(f3(y))
  >     let f5 = fn (y) -> f4(f4(y))
  >     0
  >   }
  > }
  > 
  > `op:eval-code`(plan)
  > J
  $ timeout 60 jacquard run --allow eval --fuel 100000 types.jac 2>&1 | head -1
  error[E0919]: Computation fuel was exhausted

Rendering a type for a diagnostic is metered as well: a type error whose type
is exponentially large stops at the budget instead of rendering it:

  $ python3 -c 'n = 40
  > ps = ", ".join("f%d" % i for i in range(n + 1))
  > body = "\n".join("    let _ = f%d((f%d, f%d))" % (i, i + 1, i + 1) for i in range(n))
  > print("plan = quote {\n  add(fn (%s) -> {\n%s\n    0\n  }, 1)\n}\n\n`op:eval-code`(plan)" % (ps, body))' > typerror.jac
  $ timeout 60 jacquard run --allow eval --fuel 100000 typerror.jac 2>&1 | head -1
  error[E0919]: Computation fuel was exhausted

A budget must be a non-negative number of units:

  $ jacquard run --fuel=-1 spin.jac 2>&1 | head -2
  Usage: jacquard run [--help] [OPTION]… FILE
  jacquard: option '--fuel': expected a non-negative number of fuel units
