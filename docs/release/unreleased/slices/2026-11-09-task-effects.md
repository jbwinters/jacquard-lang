Task effects must be handled inside the task (E0837). Every task (an
`async.spawn` child or an `async.scope` body) runs on a fresh continuation
under the scheduler; an operation it does not handle goes to the scheduler
(Async, Channel), then to the root grants, and otherwise the task fails with an
unhandled effect. The checker nevertheless let a handler outside the task
discharge the task's effects, because the frozen spawn operation's row is the
child's row and `async.scope` shares its body's tail with its result, so such a
program checked as pure and failed at run time. A task row variable now carries
a task-row flag beside the scoped-instance flag, set on the spawn child row and
the `async.scope` body tail (not on `dist.sample-lw`, which is not a task). The
flag propagates, is OR-ed, instantiated and cloned like the instance flag, and
binding a flagged variable to a row with any fixed effect other than Async,
Channel or a root-grantable effect, decided by identity, is refused with E0837
naming the effect. The root-grantable names now live in
`Effect_registry.root_grantable_names`, which `Prelude.grantable_names`
re-exports. There is no runtime change. `test/cli/task-effects.t` pins the
refusals (outer handler, handler around the spawn inside the body, a body that
performs the effect, a nested scope with the handler between, an outer
`state.run`, a polymorphic helper) and the accepted programs (handling inside a
child and a grandchild, console and dist under their grants, a channel);
`test/test_types.ml` pins the flag's unification behaviour; the diagnostic
battery gains an E0837 case. Left for later: like scoped-instance Limit L2, a
body's ambient row shares the task's tail, so a callback the body runs in the
parent (`h(g) = { let x = g(); async.scope(fn () -> x) }`) is restricted too;
separating them needs a directional row constraint. A user handler that
interprets Async in the language (the native parity seam) runs children inline,
where an outer handler would reach them, but is refused the same way.
