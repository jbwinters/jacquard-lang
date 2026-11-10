Task effects must be handled inside the task (E0837). Every task (an
`async.spawn` child or an `async.scope` body) runs on a fresh continuation
under the scheduler; an operation it does not handle goes to the scheduler
(Async, Channel), then to the root grants, and otherwise the task fails with an
unhandled effect. The checker nevertheless let a handler outside the task
discharge the task's effects, because the frozen spawn operation's row is the
child's row and `async.scope` shares its body's tail with its result, so such a
program checked as pure and failed at run time. A task row variable now carries
a task-row flag beside the scoped-instance flag, set on the spawn child row and
the `async.scope` body tail (not on `dist.sample-lw`, which is not a task).
Binding a flagged variable to a row with any fixed effect other than Async,
Channel or a root-grantable effect, decided by identity, is refused with E0837
naming the effect; a user effect whose name collides with a registry effect is
named in its qualified `unpackaged:<hash>/<name>` form. The task row no longer
shares a tail with the spawn operation's row or the scope call's result row:
each of those gets its own unflagged tail, which the task tail records as an
outward row. Binding the task tail to fixed effects pushes them into every
outward row (a closed or rigid outward row lacking one is a row mismatch), the
new tail inherits the flag and the outward rows, unification unions them, level
lowering lowers the outward rows with the tail, and instantiation and cloning
remap them through the same copy. So only the task's own effects reach its
row: a handler, annotation or join around the call constrains only the outward
row, while every effect the task performs, granted ones included, still
reaches the caller's row for `--allow` and manifests. The outward tail keeps
the scoped-instance flag, so E0833 is unchanged (Limit L2 still applies to
instances). The root-grantable names now live in
`Effect_registry.root_grantable_names`, which `Prelude.grantable_names`
re-exports. There is no runtime change. `test/cli/task-effects.t` pins the
refusals (outer handler, handler around the spawn inside the body, a body that
performs the effect, a nested scope with the handler between, an outer
`state.run`, a polymorphic helper, a user effect spelled `Clock`) and the
accepted programs (handling inside a child and a grandchild, console and dist
under their grants, a channel, a callback the parent runs before a scope,
handlers and a wider annotation around code that only opens a scope, `if` and
shared-parameter joins, a Warp Case around a scope, and a child's console
effect reaching `--manifest` and `--allow`); `test/test_types.ml` pins the
flag's unification behaviour and the outward rows' propagation, level
lowering, cycles, instantiation and cloning; the diagnostic battery gains an
E0837 case. Left for later: an in-language handler of a root-grantable effect
around a task (`dist.enumerate`, a user Console handler) does not handle the
task's operations but still checks. A user handler that interprets Async in the
language (the native parity seam) runs children inline, where an outer handler
would reach them, but is refused the same way.
