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

  $ jacquard run --fuel 112 ../../demos/basics/surface-fact.jac
  120
  fuel: 112 of 112 unit(s) used (fuel-v1)
  $ jacquard run --fuel 111 ../../demos/basics/surface-fact.jac 2>&1 | head -1
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

Every branch of an exact enumeration draws on the same budget, and running
out is E0919, not a model runtime failure (E0902) or the terminal-path budget
(E0918):

  $ jacquard infer enumerate --fuel 1000 ../../demos/inference/m3-two-coins.jac
  0.666667  true
  0.333333  false
  fuel: 142 of 1000 unit(s) used (fuel-v1)
  $ jacquard infer enumerate --fuel 141 ../../demos/inference/m3-two-coins.jac
  error[E0919]: Computation fuel was exhausted
    Cause: computation fuel exhausted: the fuel-v1 budget of 141 unit(s) ran out before evaluation finished; the result is incomplete
    Next step: Raise the --fuel budget, or omit it to run unbounded. An exhausted run is incomplete; it neither passes nor fails.
  fuel: 141 of 141 unit(s) used (fuel-v1)
  [1]

A budget must be a non-negative number of units:

  $ jacquard run --fuel=-1 spin.jac 2>&1 | head -2
  Usage: jacquard run [--help] [OPTION]… FILE
  jacquard: option '--fuel': expected a non-negative number of fuel units
